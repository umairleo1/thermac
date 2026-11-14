import Foundation
import ThermacCore

extension Commands {
    /// Phase 4 validation: for every cold-start anchor, compare the anchor reading, the
    /// night-cooling asymptote of the sleep that ended there, and the power-response
    /// estimate for the awake period that followed.
    static func validate(dbPath: String) {
        do {
            let store = try SampleStore(path: dbPath)
            let anchors = try store.events(type: "cold_start")
            guard !anchors.isEmpty else { fail("no cold-start anchors yet") }
            let channels = try store.channelNames()
            let candidates = channels.filter {
                $0.kind == "temperature" &&
                    ["battery", "ssd", "skin", "display", SensorCategory.ambientCandidate.rawValue].contains($0.category)
            }.map(\.name)
            let sessionStarts = anchors.map { $0.time - (detailNumber($0.detail, "session_s") ?? 0) }
            let now = Date().timeIntervalSince1970

            print("thermac validate — every cold-start anchor (°C)\n")
            print("  anchor (local)     slept  at-wake  night (MAD)     τ h   | awake  day est (SD)    day − night")
            for (i, a) in anchors.enumerated() {
                let dayEnd = i + 1 < anchors.count ? sessionStarts[i + 1] : now
                let rows = try store.rows(from: a.time)
                var ticks: [Double: [String: Double]] = [:]
                for r in rows where r.t <= dayEnd { ticks[r.t, default: [:]][r.channel] = r.value }
                let times = ticks.keys.sorted().filter { ticks[$0]!["smc:PSTR"] != nil }
                guard let t0 = times.first else { continue }

                let first = ticks[t0]!
                let atStart = candidates.compactMap { n in first[n].map { (n, $0) } }
                let median = atStart.map(\.1).sorted()[atStart.count / 2]
                let consistent = atStart.filter { abs($0.1 - median) <= 1.0 }.map(\.0)

                var series: [String: [(t: Double, value: Double)]] = [:]
                for n in consistent { series[n] = try store.series(n, from: sessionStarts[i], to: a.time + 1) }
                let night = CoolingFit.night(series, from: sessionStarts[i])

                let input = PowerResponse.Input(
                    t: times,
                    power: times.map { ticks[$0]!["smc:PSTR"]! },
                    charge: times.map { t in
                        let v = ticks[t]!
                        guard (v["sys:charging"] ?? 0) > 0, let dc = v["smc:PDTR"] else { return 0 }
                        return max(0, dc - v["smc:PSTR"]!)
                    },
                    sensors: Dictionary(uniqueKeysWithValues: consistent.map { n in (n, times.map { ticks[$0]![n] }) }))
                let awakeH = (times.last! - t0) / 3600
                let day = awakeH >= 1.5 ? PowerResponse.estimate(input, coldStart: true) : nil

                let local = DateFormatter()
                local.dateFormat = "EEE dd HH:mm"
                let nightStr = night.map { "\(fmt($0.room)) (\(fmt($0.spread)))" } ?? "—"
                let dayStr = day.map { "\(fmt($0.room)) (\(fmt($0.sensorSpread)))" } ?? "—"
                let diff = (day?.room).flatMap { d in night.map { signed(d - $0.room) } } ?? "—"
                print("  \(pad(local.string(from: Date(timeIntervalSince1970: a.time)), 18)) "
                      + "\(pad(fmt((detailNumber(a.detail, "slept_s") ?? 0) / 3600, 1) + " h", 6)) "
                      + "\(pad(fmt(median), 8)) \(pad(nightStr, 15)) \(pad(fmt(night.map { $0.tau / 3600 }, 1), 5)) | "
                      + "\(pad(fmt(awakeH, 1) + " h", 6)) \(pad(dayStr, 15)) \(diff)")
            }
            print("\n  at-wake: median of consistent sensors at the anchor · night: sleep-cooling asymptote")
            print("  day est: power-response fit over the awake period after the anchor (to the next session)")
        } catch {
            fail("\(error)")
        }
    }
}
