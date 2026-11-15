import Foundation

/// What the menu bar shows.
public struct LiveEstimate: Sendable {
    public enum Source: String, Sendable {
        /// Room filter: night anchors + calibrated transfer model.
        case filter
        /// Only night estimates so far (needs ≥ 2 good nights with a day between).
        case night
        /// No good night yet.
        case waiting
        /// The recorder has not written for a while.
        case stale
    }

    public let room: Double?
    public let roomSD: Double?
    public let source: Source
    public let lastNight: (time: Double, room: Double)?
    public let goodNights: Int
    /// Filter estimate over the last 24 h, ~5-min resolution.
    public let history: [(t: Double, room: Double, sd: Double)]
    public let lastSample: Double?
    public let computedAt: Double
    public let message: String

    /// Change of the estimate over the last `seconds` (°C), from the history; nil if
    /// the history does not reach that far back.
    public func trend(over seconds: Double = 3600) -> Double? {
        guard let last = history.last, let first = history.first, last.t - first.t >= seconds * 0.9 else { return nil }
        let target = last.t - seconds
        guard let past = history.min(by: { abs($0.t - target) < abs($1.t - target) }) else { return nil }
        return last.room - past.room
    }
}

/// Runs the Phase 5 pipeline against the recorder's database for live display.
///
/// Recalibration ("RLS" in the plan, done as a batch refit): the transfer model is refit
/// whenever a new good night appears — each night adds a bracketed day of calibration
/// data. Between nights, only the current awake period is reloaded; the filter state at
/// its start is cached, so a refresh costs well under a second.
public actor LiveEstimator {
    public let dbPath: String
    /// Recorder considered stopped after this long without a sample.
    public var staleAfter: Double = 600
    /// Filter tuning. The default is the accuracy-validated one; a larger `roomWalk`
    /// reacts faster to room changes but passes more model error through.
    public private(set) var tuning = RoomFilter.Tuning()

    private var cacheKey: String?
    private var model: TransferCalibration.Model?
    private var filterAtCurrentStart: RoomFilter?
    private var currentStart: Double?
    private var pastHistory: [(t: Double, room: Double, sd: Double)] = []
    private var nights: [AnchorData.Night] = []
    private var sensors: [String] = []

    public init(dbPath: String = SampleStore.defaultPath) {
        self.dbPath = dbPath
    }

    /// Changes the filter tuning; the next `estimate` replays the log with it.
    public func setTuning(_ t: RoomFilter.Tuning) {
        tuning = t
        cacheKey = nil
    }

    public func estimate(now: Double = Date().timeIntervalSince1970) throws -> LiveEstimate {
        let store = try SampleStore(path: dbPath)
        let lastSample = store.lastSampleTime()
        let anchors = try store.events(type: "cold_start")
        let key = anchors.map { String(format: "%.0f", $0.time) }.joined(separator: ",")
        if key != cacheKey {
            try rebuild(store, now: now)
            cacheKey = key
        }

        guard let last = nights.last, var f = filterAtCurrentStart, let start = currentStart else {
            return LiveEstimate(room: nil, roomSD: nil, source: .waiting, lastNight: nil, goodNights: 0,
                                history: [], lastSample: lastSample, computedAt: now,
                                message: "Waiting for the first night — close the lid for ≥ 2 h")
        }

        // Current awake period since the last good night.
        var history = pastHistory
        var t = start
        if let model, let input = try AnchorData.loadInput(store, from: start, to: now, sensors: sensors) {
            var nextMark = input.t[0]
            t = f.run(input, predictions: TransferCalibration.predict(model, input),
                      trust: RoomFilter.modelTrust(input), from: t) { time, state in
                if time >= nextMark { history.append((time, state.room, state.roomSD)); nextMark = time + 300 }
            }
        }
        f.predict(dt: max(0, now - t))
        history.append((now, f.room, f.roomSD))
        history = history.filter { $0.t >= now - 86400 }

        let stale = lastSample.map { now - $0 > staleAfter } ?? true
        let source: LiveEstimate.Source = stale ? .stale : (model == nil ? .night : .filter)
        let message: String
        switch source {
        case .stale: message = "Recorder not running — estimate is getting older"
        case .night: message = "From last night only — the live model needs 2 nights with a day between"
        case .filter: message = "Night anchors + calibrated model (\(nights.count) nights)"
        case .waiting: message = ""
        }
        return LiveEstimate(room: f.room, roomSD: f.roomSD, source: source, lastNight: (last.end, last.room),
                            goodNights: nights.count, history: history, lastSample: lastSample,
                            computedAt: now, message: message)
    }

    /// Refit the model on every awake segment, then replay the filter up to the start
    /// of the current awake period.
    private func rebuild(_ store: SampleStore, now: Double) throws {
        let candidates = try AnchorData.slowSensors(store)
        nights = try AnchorData.goodNights(store, candidates: candidates).nights
        sensors = AnchorData.commonSensors(nights, candidates: candidates)
        model = nil
        filterAtCurrentStart = nil
        currentStart = nil
        pastHistory = []
        guard let first = nights.first else { return }

        let starts = try AnchorData.sessionStarts(store)
        // Completed segments only (the current one is processed on every refresh).
        let segments = try AnchorData.awakeSegments(store, nights: nights, sensors: sensors,
                                                    sessionStarts: starts, now: now)
            .filter { $0.night < nights.count - 1 }
        if segments.count >= 2 { model = TransferCalibration.calibrate(segments.map(\.seg)) }
        if model == nil, let all = try? AnchorData.awakeSegments(store, nights: nights, sensors: sensors,
                                                                  sessionStarts: starts, now: now),
           all.count >= 2 {
            model = TransferCalibration.calibrate(all.map(\.seg))
        }

        var f = RoomFilter(room: first.room, roomSD: max(first.spread, 0.25), tuning: tuning)
        var t = first.end
        for (i, night) in nights.enumerated() {
            if i > 0 {
                f.predict(dt: night.end - t)
                f.observeRoom(night.room, sd: max(night.spread, 0.25))
                t = night.end
            }
            pastHistory.append((t, f.room, f.roomSD))
            guard i < nights.count - 1 else { break }
            if let model, let seg = segments.first(where: { $0.night == i }) {
                let input = seg.seg.input
                var nextMark = input.t[0]
                var marks: [(t: Double, room: Double, sd: Double)] = []
                t = f.run(input, predictions: TransferCalibration.predict(model, input),
                          trust: RoomFilter.modelTrust(input), from: t) { time, state in
                    if time >= nextMark { marks.append((time, state.room, state.roomSD)); nextMark = time + 300 }
                }
                pastHistory += marks
            }
        }
        filterAtCurrentStart = f
        currentStart = t
    }
}
