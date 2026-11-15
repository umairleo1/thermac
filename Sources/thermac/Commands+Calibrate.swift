import Foundation
import ThermacCore

extension Commands {
    static let slowCategories = AnchorData.slowCategories
    typealias Night = AnchorData.Night

    static func loadInput(_ store: SampleStore, from: Double, to: Double, sensors: [String]) throws -> PowerResponse.Input? {
        try AnchorData.loadInput(store, from: from, to: to, sensors: sensors)
    }

    static func goodNights(_ store: SampleStore, candidates: [String]) throws -> (nights: [Night], rejected: [Double]) {
        try AnchorData.goodNights(store, candidates: candidates)
    }

    struct LabeledSegment {
        let label: String
        let night: Int
        let bracketed: Bool
        let seg: TransferCalibration.Segment
    }

    static func awakeSegments(_ store: SampleStore, nights: [Night], sensors: [String], sessionStarts: [Double],
                              now: Double, label: (Double, Double) -> String) throws -> [LabeledSegment] {
        try AnchorData.awakeSegments(store, nights: nights, sensors: sensors, sessionStarts: sessionStarts, now: now)
            .map { LabeledSegment(label: label($0.seg.input.t[0], $0.seg.input.t.last!), night: $0.night,
                                  bracketed: $0.bracketed, seg: $0.seg) }
    }

    static func calibrate(dbPath: String, verbose: Bool = false) {
        do {
            let store = try SampleStore(path: dbPath)
            let candidates = try store.channelNames()
                .filter { $0.kind == "temperature" && slowCategories.contains($0.category) }.map(\.name)
            let (nights, rejected) = try goodNights(store, candidates: candidates)
            guard nights.count >= 2 else { fail("need ≥ 2 good nights (have \(nights.count))") }
            let sensors = nights.map(\.consistent).reduce(Set(candidates)) { $0.intersection($1) }.sorted()
            let sessionStarts = try store.events(type: "cold_start")
                .map { $0.time - (detailNumber($0.detail, "session_s") ?? 0) }
            let now = Date().timeIntervalSince1970

            let local = DateFormatter()
            local.dateFormat = "EEE dd HH:mm"
            func when(_ t: Double) -> String { local.string(from: Date(timeIntervalSince1970: t)) }

            print("thermac calibrate — anchor-calibrated transfer function (Phase 4)\n")
            print("  reference nights   " + nights.map { "\(when($0.end)) \(fmt($0.room))" }.joined(separator: " · "))
            if !rejected.isEmpty { print("  rejected nights    " + rejected.map(when).joined(separator: ", ") + "  (cooling curve ≠ at-wake reading)") }
            print("  sensors            \(sensors.count) (consistent at every good anchor)\n")

            let segments = try awakeSegments(store, nights: nights, sensors: sensors, sessionStarts: sessionStarts,
                                             now: now, label: { "\(when($0)) → \(when($1))" })
            guard segments.count >= 2 else { fail("need ≥ 2 awake segments after good nights") }

            print("  leave-one-day-out (calibrate on the others, predict this one)")
            print("  segment                          ref mean  pred mean  error   rms    last hour")
            var errors: [Double] = []
            var residualSeries: [[Double]] = []
            for (i, s) in segments.enumerated() {
                let others = segments.enumerated().filter { $0.offset != i }.map(\.element.seg)
                guard let model = TransferCalibration.calibrate(others) else { continue }
                let pred = TransferCalibration.predict(model, s.seg.input)
                let pairs = zip(pred, s.seg.reference).compactMap { p, r in r.isFinite ? p.map { ($0, r) } : nil }
                guard !pairs.isEmpty else { continue }
                let pm = pairs.map(\.0).reduce(0, +) / Double(pairs.count)
                let rm = pairs.map(\.1).reduce(0, +) / Double(pairs.count)
                let rms = (pairs.map { ($0.0 - $0.1) * ($0.0 - $0.1) }.reduce(0, +) / Double(pairs.count)).squareRoot()
                let lastT = s.seg.input.t.last! - 3600
                let last = zip(s.seg.input.t, zip(pred, s.seg.reference)).filter { $0.0 >= lastT }
                    .compactMap { _, pr in pr.1.isFinite ? pr.0.map { $0 - pr.1 } : nil }
                let lastErr = last.isEmpty ? nil : last.reduce(0, +) / Double(last.count)
                errors.append(pm - rm)
                // 5-minute means of the residual for the autocorrelation estimate.
                var grid: [Int: (Double, Int)] = [:]
                for j in s.seg.input.t.indices {
                    guard let pj = pred[j], s.seg.reference[j].isFinite else { continue }
                    let b = Int((s.seg.input.t[j] - s.seg.input.t[0]) / 300)
                    let v = grid[b] ?? (0, 0)
                    grid[b] = (v.0 + pj - s.seg.reference[j], v.1 + 1)
                }
                if let maxB = grid.keys.max() {
                    // Continuous runs only: never correlate across an excluded stretch.
                    var run: [Double] = []
                    for b in 0...maxB {
                        if let v = grid[b] { run.append(v.0 / Double(v.1)) } else if !run.isEmpty { residualSeries.append(run); run = [] }
                    }
                    if !run.isEmpty { residualSeries.append(run) }
                }
                if verbose {
                    var buckets: [Int: (e: Double, p: Double, f: Double, c: Double, n: Double)] = [:]
                    for j in s.seg.input.t.indices {
                        guard let pj = pred[j], s.seg.reference[j].isFinite else { continue }
                        let b = Int((s.seg.input.t[j] - s.seg.input.t[0]) / 1800)
                        var v = buckets[b] ?? (0, 0, 0, 0, 0)
                        v.e += pj - s.seg.reference[j]; v.p += s.seg.input.power[j]
                        v.c += s.seg.input.charge[j]; v.n += 1
                        buckets[b] = v
                    }
                    for b in buckets.keys.sorted() {
                        let v = buckets[b]!
                        print("      +\(pad(fmt(Double(b) / 2, 1) + " h", 7)) err \(pad(signed(v.e / v.n), 9)) P \(pad(fmt(v.p / v.n, 1), 5)) W  charge \(fmt(v.c / v.n, 1)) W")
                    }
                }
                print("  \(pad(s.label, 32)) \(pad(fmt(rm), 9)) \(pad(fmt(pm), 10)) \(pad(signed(pm - rm), 7)) \(pad(fmt(rms), 6)) \(lastErr.map(signed) ?? "—")\(s.bracketed ? "" : "  (no night after: ref held flat)")")
            }
            // Model-error statistics for the room filter: SD and autocorrelation of the
            // held-out residuals (prediction − reference), on a 5-min grid.
            if !residualSeries.isEmpty {
                let all = residualSeries.flatMap { $0 }
                let mean = all.reduce(0, +) / Double(all.count)
                let variance = all.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(all.count)
                var line = "  held-out model error: SD \(fmt(variance.squareRoot())) °C, mean \(signed(mean)); autocorrelation"
                for lagMin in [30, 60, 120, 240] {
                    let k = lagMin / 5
                    var num = 0.0, n = 0
                    for r in residualSeries where r.count > k {
                        for j in 0..<(r.count - k) { num += (r[j] - mean) * (r[j + k] - mean); n += 1 }
                    }
                    if n > 0 { line += "  \(lagMin) min \(fmt(num / Double(n) / variance))" }
                }
                print("\n" + line)
            }
            if !errors.isEmpty {
                let mae = errors.map(abs).reduce(0, +) / Double(errors.count)
                print("\n  mean |error| of day means: \(fmt(mae)) °C over \(errors.count) held-out segments (exit criterion ± 0.5 °C)")
            }

            if let model = TransferCalibration.calibrate(segments.map(\.seg)), let last = segments.last {
                let pred = TransferCalibration.predict(model, last.seg.input).compactMap { $0 }
                let recent = pred.suffix(60)
                print("\n  all-segment model: \(model.sensors.count) sensors, median rms \(fmt(model.sensors.map(\.rms).sorted()[model.sensors.count / 2], 3)) °C")
                if !recent.isEmpty {
                    print("  room, last 5 min of latest segment: \(fmt(recent.reduce(0, +) / Double(recent.count))) °C")
                }
            }
        } catch {
            fail("\(error)")
        }
    }
}
