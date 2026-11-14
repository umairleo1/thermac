import Foundation

/// A night (or any long absence) as macOS actually does it: many sleeps separated by
/// brief maintenance wakes (DarkWake — every ~15 min, often in 25 s bursts, a few
/// seconds awake each). Measured 2026-11-12: 102 sleep/wake pairs in 9 h, no single
/// sleep ≥ 2 h.
public struct SleepSession: Equatable, Sendable {
    /// Start of the first sleep.
    public var start: Double
    /// Most recent wake — the anchor time if this session qualifies.
    public var lastWake: Double
    /// Total time asleep.
    public var slept: Double
    /// Total time awake in between (DarkWakes); a measure of how much it warmed itself.
    public var awake: Double = 0
    public var wakes: Int = 1

    /// Fraction of the session spent asleep.
    public var sleepFraction: Double { slept / max(lastWake - start, 1) }

    /// Merges `sleep → wake` into this session if the Mac was awake for at most
    /// `maxAwake` since the previous wake; returns false if it starts a new session.
    mutating func absorb(sleep: Double, wake: Double, maxAwake: Double) -> Bool {
        let awakeGap = sleep - lastWake
        guard awakeGap >= 0, awakeGap <= maxAwake else { return false }
        awake += awakeGap
        slept += wake - sleep
        lastWake = wake
        wakes += 1
        return true
    }

    /// Groups recorded sleep/wake events into sessions (oldest first).
    public static func group(_ events: [RecordedEvent],
                             maxAwake: Double = PowerEventTracker.maxDarkWake) -> [SleepSession] {
        var out: [SleepSession] = []
        var pendingSleep: Double?
        for e in events.sorted(by: { $0.time < $1.time }) {
            switch e.type {
            case "sleep":
                pendingSleep = e.time
            case "wake":
                guard let s = pendingSleep, s < e.time else { continue }
                pendingSleep = nil
                if var last = out.last, last.absorb(sleep: s, wake: e.time, maxAwake: maxAwake) {
                    out[out.count - 1] = last
                } else {
                    out.append(SleepSession(start: s, lastWake: e.time, slept: e.time - s))
                }
            default:
                continue
            }
        }
        return out
    }
}

/// Turns kernel sleep/wake timestamps into recorded events, and flags **cold-start
/// anchors**: the end of a long sleep session, when every part of the Mac has drifted
/// to room temperature. These anchors are the project's main reference.
///
/// Sleep is counted across DarkWake maintenance wakes. A session ends — and its anchor
/// is emitted, timestamped at its last wake — once the Mac has stayed awake longer than
/// `maxDarkWake`, i.e. someone is actually using it.
///
/// Polling `kern.waketime` each tick (instead of power-management callbacks) also
/// catches wakes that happened while thermac was not running.
public struct PowerEventTracker: Sendable {
    /// Minimum total sleep in a session for it to count as a cold-start anchor.
    public static let coldStartThreshold: TimeInterval = 2 * 3600
    /// Longest awake stretch still treated as a maintenance wake inside a session.
    /// Observed DarkWakes last 5–12 s; real use lasts longer than this.
    public static let maxDarkWake: TimeInterval = 180

    public private(set) var lastWake: Double?
    public private(set) var session: SleepSession?

    public init(lastKnownWake: Double?, session: SleepSession? = nil) {
        lastWake = lastKnownWake
        self.session = session
    }

    /// - Parameters:
    ///   - wake / sleep: current `kern.waketime` / `kern.sleeptime` (unix seconds)
    ///   - now: current time, used to report how late the wake was noticed and to
    ///     decide when a session has ended
    ///   - onAC / charging: power state now (charging during sleep warms the battery,
    ///     so the anchor's quality depends on it)
    public mutating func update(wake: Double?, sleep: Double?, now: Double,
                                onAC: Bool?, charging: Bool?) -> [RecordedEvent] {
        var events: [RecordedEvent] = []
        if let wake, lastWake.map({ abs($0 - wake) >= 1 }) ?? true {
            lastWake = wake
            var slept: Double?
            if let sleep, sleep < wake {
                slept = wake - sleep
                events.append(RecordedEvent(time: sleep, type: "sleep"))
                if var s = session, s.absorb(sleep: sleep, wake: wake, maxAwake: Self.maxDarkWake) {
                    session = s
                } else {
                    session = SleepSession(start: sleep, lastWake: wake, slept: wake - sleep)
                }
            }
            events.append(RecordedEvent(time: wake, type: "wake", detail: Self.json([
                "slept_s": slept.map { String(format: "%.0f", $0) },
                "late_s": String(format: "%.0f", max(0, now - wake)),
            ])))
        }

        // A sustained wake closes the session.
        if let s = session, now - s.lastWake > Self.maxDarkWake {
            session = nil
            if s.slept >= Self.coldStartThreshold {
                events.append(Self.anchor(for: s, onAC: onAC, charging: charging))
            }
        }
        return events
    }

    /// The `cold_start` event for a finished session.
    public static func anchor(for s: SleepSession, onAC: Bool?, charging: Bool?,
                              backfilled: Bool = false) -> RecordedEvent {
        RecordedEvent(time: s.lastWake, type: "cold_start", detail: json([
            "slept_s": String(format: "%.0f", s.slept),
            "session_s": String(format: "%.0f", s.lastWake - s.start),
            "wakes": String(s.wakes),
            "awake_s": String(format: "%.0f", s.awake),
            "on_ac": onAC.map { $0 ? "true" : "false" },
            "charging": charging.map { $0 ? "true" : "false" },
            "backfilled": backfilled ? "true" : nil,
        ]))
    }

    /// Tiny JSON object writer for flat numeric/bool values (already formatted).
    static func json(_ fields: KeyValuePairs<String, String?>) -> String {
        "{" + fields.compactMap { k, v in v.map { "\"\(k)\":\($0)" } }.joined(separator: ",") + "}"
    }
}
