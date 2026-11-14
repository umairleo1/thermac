import Foundation

/// Continuously samples the sensor suite into a `SampleStore`.
///
/// Runs on the main queue with a coalescing-friendly timer (10 % leeway) so it stays
/// within the N1 budget. Records start/stop, sleep/wake, cold-start anchors and
/// unexplained gaps (e.g. the process was suspended without the Mac sleeping).
@MainActor
public final class Recorder {
    public let store: SampleStore
    public let suite: SensorSuite
    public let interval: TimeInterval
    /// Samples older than this are compacted to 1-minute averages.
    public var retainFullResolution: TimeInterval = 7 * 86400

    private let ids: [Int64]
    private var tracker: PowerEventTracker
    private var timer: DispatchSourceTimer?
    private var lastTick: Double?
    private var lastCompaction: Double = 0
    private var onAC: Bool?, charging: Bool?
    public private(set) var ticks = 0

    public init(store: SampleStore, suite: SensorSuite, interval: TimeInterval) throws {
        self.store = store
        self.suite = suite
        self.interval = interval
        ids = try store.register(suite.channels)
        tracker = PowerEventTracker(lastKnownWake: store.meta("last_wake").flatMap(Double.init))
    }

    public func start(detail: String? = nil) throws {
        let now = Date().timeIntervalSince1970
        try store.add(RecordedEvent(time: now, type: "start", detail: detail))
        try resumeSleepSessions(now: now)
        if let last = store.lastSampleTime(), now - last > 3 * interval {
            // Recording was off; sleep events (if any) are recovered by the tracker below.
            try store.add(RecordedEvent(time: last, type: "gap",
                                        detail: "{\"until\":\(now),\"reason\":\"not_running\"}"))
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    /// Rebuilds the sleep-session state from recorded events, so a restart neither loses
    /// an ongoing session nor misses an anchor; anchors for finished sessions that lack
    /// one (e.g. recorded before sessions spanned DarkWakes) are backfilled.
    private func resumeSleepSessions(now: Double) throws {
        let recent = try store.events(from: now - 3 * 86400)
        let anchored = Set(recent.filter { $0.type == "cold_start" }.map { $0.time.rounded() })
        var open: SleepSession?
        for s in SleepSession.group(recent) {
            if now - s.lastWake <= PowerEventTracker.maxDarkWake { open = s; continue }
            guard s.slept >= PowerEventTracker.coldStartThreshold,
                  !anchored.contains(s.lastWake.rounded()) else { continue }
            func flag(_ name: String) throws -> Bool? {
                try store.series(name, from: s.lastWake, to: s.lastWake + 60).first.map { $0.value > 0 }
            }
            try store.add(PowerEventTracker.anchor(for: s, onAC: try flag("sys:on_ac"),
                                                   charging: try flag("sys:charging"), backfilled: true))
        }
        tracker = PowerEventTracker(lastKnownWake: tracker.lastWake, session: open)
    }

    public func stop(reason: String) {
        timer?.cancel()
        timer = nil
        try? store.add(RecordedEvent(time: Date().timeIntervalSince1970, type: "stop",
                                     detail: "{\"reason\":\"\(reason)\"}"))
    }

    func tick() {
        let now = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        let values = suite.read()
        if let i = suite.channels.firstIndex(where: { $0.name == "sys:on_ac" }) { onAC = values[i].map { $0 > 0 } }
        if let i = suite.channels.firstIndex(where: { $0.name == "sys:charging" }) { charging = values[i].map { $0 > 0 } }

        do {
            // Sleep/wake first, so the events precede the first post-wake sample.
            let events = tracker.update(
                wake: PowerEvents.lastWake?.timeIntervalSince1970,
                sleep: PowerEvents.lastSleep?.timeIntervalSince1970,
                now: now, onAC: onAC, charging: charging)
            for e in events { try store.add(e) }
            if let wake = tracker.lastWake, !events.isEmpty { try store.setMeta("last_wake", String(wake)) }

            if let lastTick, now - lastTick > 3 * interval, events.isEmpty {
                try store.add(RecordedEvent(time: lastTick, type: "gap",
                                            detail: "{\"until\":\(now),\"reason\":\"stalled\"}"))
            }
            try store.insert(time: now, ids: ids, values: values)

            if now - lastCompaction > 3600 {
                try store.compact(olderThan: now - retainFullResolution)
                lastCompaction = now
            }
        } catch {
            FileHandle.standardError.write(Data("thermac: write failed: \(error)\n".utf8))
        }
        lastTick = now
        ticks += 1
    }
}
