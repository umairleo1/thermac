import Foundation
import ThermacCore

extension Commands {
    /// Phase 5 exit test: replays the log through the room filter and, at the end of each
    /// day, predicts the next good night's room temperature before seeing it.
    /// Each day uses a transfer model calibrated on the *other* days (leave-one-day-out).
    static func replay(dbPath: String, verbose: Bool, weighting: Bool = true, tuning: RoomFilter.Tuning = RoomFilter.Tuning()) {
        do {
            let store = try SampleStore(path: dbPath)
            let candidates = try store.channelNames()
                .filter { $0.kind == "temperature" && slowCategories.contains($0.category) }.map(\.name)
            let (nights, _) = try goodNights(store, candidates: candidates)
            guard nights.count >= 2 else { fail("need ≥ 2 good nights (have \(nights.count))") }
            let sensors = nights.map(\.consistent).reduce(Set(candidates)) { $0.intersection($1) }.sorted()
            let sessionStarts = try store.events(type: "cold_start")
                .map { $0.time - (detailNumber($0.detail, "session_s") ?? 0) }
            let local = DateFormatter()
            local.dateFormat = "EEE dd HH:mm"
            func when(_ t: Double) -> String { local.string(from: Date(timeIntervalSince1970: t)) }
            let segments = try awakeSegments(store, nights: nights, sensors: sensors, sessionStarts: sessionStarts,
                                             now: Date().timeIntervalSince1970, label: { "\(when($0)) → \(when($1))" })
            guard segments.count >= 2 else { fail("need ≥ 2 awake segments") }

            print("thermac replay — room filter over the recorded log (Phase 5)")
            print("  model trust lowered while charging and in the first hour after wake: \(weighting ? "on" : "off (--no-weighting)")\n")
            print("  day                              end of day: filter        model only   next night   filter err  model err")
            var filter: RoomFilter?
            var lastT: Double?
            var filterErrors: [Double] = [], modelErrors: [Double] = []
            var trackSq = 0.0, trackN = 0
            var steps: [Double] = []
            var lastRoom: (t: Double, room: Double)?
            for (i, s) in segments.enumerated() {
                let others = segments.enumerated().filter { $0.offset != i }.map(\.element.seg)
                guard let model = TransferCalibration.calibrate(others) else { continue }
                let pred = TransferCalibration.predict(model, s.seg.input)
                let input = s.seg.input
                let night = nights[s.night]

                // Anchor: the night estimate observes the room directly.
                if var f = filter, let lastT {
                    f.predict(dt: input.t[0] - lastT)
                    f.observeRoom(night.room, sd: max(night.spread, 0.25))
                    filter = f
                } else {
                    filter = RoomFilter(room: night.room, roomSD: max(night.spread, 0.25), tuning: tuning)
                }
                var f = filter!
                let trust = weighting ? RoomFilter.modelTrust(input) : input.t.map { _ in 1 }
                var j = 0
                f.run(input, predictions: pred, trust: trust, from: input.t[0]) { time, state in
                    if verbose, j % 360 == 0 {
                        print("      \(when(time))  model \(fmt(pred[j]))  filter \(fmt(state.room)) ± \(fmt(state.roomSD))  bias \(signed(state.bias))")
                    }
                    // Tracking metric: filter vs. the room reference, where it is defined.
                    let ref = s.seg.reference[j]
                    if ref.isFinite {
                        trackSq += (state.room - ref) * (state.room - ref); trackN += 1
                        if let last = lastRoom, time - last.t >= 300 { steps.append(state.room - last.room); lastRoom = (time, state.room) }
                        if lastRoom == nil { lastRoom = (time, state.room) }
                    } else {
                        lastRoom = nil
                    }
                    j += 1
                }
                filter = f
                lastT = input.t.last!

                let tail = zip(input.t, pred).filter { $0.0 >= input.t.last! - 3600 }.compactMap(\.1)
                let modelEnd = tail.isEmpty ? nil : tail.reduce(0, +) / Double(tail.count)
                // Score only days that stayed in one place: after a long absence (lid closed
                // ≥ 30 min, e.g. a commute) the next night's room is not the right yardstick.
                let moved = RoomFilter.absences(input.t).values.contains { $0 >= tuning.relocationGap }
                let next = s.night + 1 < nights.count && !moved ? nights[s.night + 1].room : nil
                var fErr = moved ? "moved — not scored" : "—", mErr = moved ? "" : "—"
                if let next {
                    filterErrors.append(f.room - next)
                    fErr = signed(f.room - next)
                    if let modelEnd { modelErrors.append(modelEnd - next); mErr = signed(modelEnd - next) }
                }
                print("  \(pad(s.label, 32)) \(pad(fmt(f.room) + " ± " + fmt(f.roomSD), 22)) \(pad(fmt(modelEnd), 12)) \(pad(fmt(next), 12)) \(pad(fErr, 11)) \(mErr)")
            }
            if !filterErrors.isEmpty {
                let worst = filterErrors.map(abs).max()!
                let mWorst = modelErrors.map(abs).max() ?? .nan
                print("\n  next-night prediction: filter worst \(fmt(worst)) °C, model-only worst \(fmt(mWorst)) °C over \(filterErrors.count) day(s)")
                print("  Phase 5 exit criterion (± 1.5 °C): \(worst <= 1.5 ? "MET" : "not met") on the data so far")
            }
            if trackN > 0 {
                let rms = (trackSq / Double(trackN)).squareRoot()
                let jitter = steps.count > 1
                    ? (steps.map { $0 * $0 }.reduce(0, +) / Double(steps.count)).squareRoot() : .nan
                print("  through the day: tracking RMS \(fmt(rms)) °C vs reference · jitter \(fmt(jitter, 3)) °C per 5 min")
            }
            if let f = filter { print("\n  room now (filter): \(fmt(f.room)) °C ± \(fmt(f.roomSD))") }
        } catch {
            fail("\(error)")
        }
    }
}
