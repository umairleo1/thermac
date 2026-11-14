import Foundation

/// Turns the recorded log into what the estimators need: trustworthy nights, the room
/// reference between them, and awake segments as power-response inputs.
/// Shared by the CLI (`calibrate`, `replay`) and the live estimator (menu bar app).
public enum AnchorData {
    public static let slowCategories = ["battery", "ssd", "skin", "display", SensorCategory.ambientCandidate.rawValue]

    /// A night whose sleep-cooling asymptote agrees with the at-wake reading.
    public struct Night: Sendable {
        public let start: Double, end: Double, room: Double, atWake: Double, spread: Double
        /// Sensors within 1 °C of the median at the anchor (equilibrium).
        public let consistent: Set<String>
    }

    public struct AwakeSegment: Sendable {
        public let night: Int
        public let bracketed: Bool
        public let seg: TransferCalibration.Segment
    }

    /// Reads a numeric field from a flat JSON event detail.
    public static func detailNumber(_ detail: String?, _ key: String) -> Double? {
        guard let data = detail?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj[key] as? NSNumber)?.doubleValue
    }

    public static func slowSensors(_ store: SampleStore) throws -> [String] {
        try store.channelNames().filter { $0.kind == "temperature" && slowCategories.contains($0.category) }.map(\.name)
    }

    /// Start of every sleep session that ended in a cold-start anchor.
    public static func sessionStarts(_ store: SampleStore) throws -> [Double] {
        try store.events(type: "cold_start").map { $0.time - (detailNumber($0.detail, "session_s") ?? 0) }
    }

    /// Ticks in [from, to] as a power-response input. Reads only the needed channels.
    public static func loadInput(_ store: SampleStore, from: Double, to: Double, sensors: [String]) throws -> PowerResponse.Input? {
        let power = try store.series("smc:PSTR", from: from, to: to)
        guard power.count > 100 else { return nil }
        let times = power.map(\.t)
        func aligned(_ name: String) throws -> [Double?] {
            var byT: [Double: Double] = [:]
            for p in try store.series(name, from: from, to: to) { byT[p.t] = p.value }
            return times.map { byT[$0] }
        }
        let dcIn = try aligned("smc:PDTR"), charging = try aligned("sys:charging")
        let charge = times.indices.map { j -> Double in
            guard (charging[j] ?? 0) > 0, let dc = dcIn[j] else { return 0 }
            return max(0, dc - power[j].value)
        }
        var series: [String: [Double?]] = [:]
        for n in sensors { series[n] = try aligned(n) }
        return PowerResponse.Input(t: times, power: power.map(\.value), charge: charge, sensors: series)
    }

    /// Good nights plus the anchor times of rejected ones (cooling curve ≠ at-wake reading,
    /// e.g. the Mac was moved during the session).
    public static func goodNights(_ store: SampleStore, candidates: [String]) throws -> (nights: [Night], rejected: [Double]) {
        var nights: [Night] = [], rejected: [Double] = []
        for a in try store.events(type: "cold_start") {
            let start = a.time - (detailNumber(a.detail, "session_s") ?? 0)
            var first: [String: Double] = [:]
            for n in candidates {
                if let v = try store.series(n, from: a.time, to: a.time + 30).first { first[n] = v.value }
            }
            guard !first.isEmpty else { continue }
            let median = first.values.sorted()[first.count / 2]
            let consistent = Set(first.filter { abs($0.value - median) <= 1.0 }.keys)
            var series: [String: [(t: Double, value: Double)]] = [:]
            for n in consistent { series[n] = try store.series(n, from: start, to: a.time + 1) }
            guard let night = CoolingFit.night(series, from: start) else { continue }
            if abs(night.room - median) <= 1.0 {
                nights.append(Night(start: start, end: a.time, room: night.room, atWake: median,
                                    spread: night.spread, consistent: consistent))
            } else {
                rejected.append(a.time)
            }
        }
        return (nights, rejected)
    }

    /// Room reference: constant through each good night, linear between nights,
    /// held flat after the last one.
    public static func reference(_ nights: [Night], at t: Double) -> Double {
        var pts: [(Double, Double)] = []
        for n in nights { pts += [(n.start, n.room), (n.end, n.room)] }
        guard let first = pts.first, let last = pts.last else { return .nan }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        let i = pts.firstIndex { $0.0 >= t }!
        let (t0, v0) = pts[i - 1], (t1, v1) = pts[i]
        return t1 > t0 ? v0 + (v1 - v0) * (t - t0) / (t1 - t0) : v1
    }

    /// Sensors usable everywhere: consistent at every good anchor.
    public static func commonSensors(_ nights: [Night], candidates: [String]) -> [String] {
        nights.map(\.consistent).reduce(Set(candidates)) { $0.intersection($1) }.sorted()
    }

    /// Awake segments that start at good-night anchors and last ≥ `minHours`.
    public static func awakeSegments(_ store: SampleStore, nights: [Night], sensors: [String],
                                     sessionStarts: [Double], now: Double,
                                     minHours: Double = 1.5) throws -> [AwakeSegment] {
        var out: [AwakeSegment] = []
        for (i, n) in nights.enumerated() {
            let end = sessionStarts.first { $0 > n.end + 60 } ?? now
            guard end - n.end >= minHours * 3600,
                  let input = try loadInput(store, from: n.end, to: end, sensors: sensors) else { continue }
            out.append(AwakeSegment(night: i, bracketed: i + 1 < nights.count,
                                    seg: TransferCalibration.Segment(input: input,
                                                                     reference: input.t.map { reference(nights, at: $0) })))
        }
        return out
    }
}
