import Foundation
import ThermacCore

extension Commands {
    // MARK: simulate

    /// Runs the reference simulation and shows what each method recovers vs the truth.
    static func simulate(room: Double, hours: Double, seed: UInt64, csvPath: String?) {
        var rng = SeededRandom(seed: seed)
        let duration = hours * 3600
        let profile = PowerProfile.idleWithBursts(duration: duration, rng: &rng)
        let params = ThermalParameters.m4ProLike
        let trace = ThermalSimulator.run(parameters: params, duration: duration, power: profile,
                                         room: { _ in room }, seed: seed)

        print("Simulated M4-Pro-like laptop — \(fmt(hours, 1)) h, seed \(seed)")
        print("  true room temperature     \(fmt(room)) °C")
        let bursts = profile.segments.filter { $0.watts > 10 }
        print("  load bursts               \(bursts.count) (\(bursts.map { fmt($0.watts, 0) + " W" }.joined(separator: ", ")))")
        print("  max fan speed             \(fmt(trace.fanRPM.max(), 0)) rpm")
        let idle = params.steadyState(power: 5, room: room)
        print("  idle steady state         SoC \(fmt(idle.t1)) °C, battery \(fmt(idle.t2)) °C\n")

        // Naive Newton fit on the longest idle stretch at the end.
        if let lastBurst = bursts.last {
            let end = profile.segments.first { $0.start > lastBurst.start }?.start ?? duration
            let idx = trace.t.indices.filter { trace.t[$0] >= end + 120 }
            if trace.t.last! - end > 1800,
               let fit = CoolingFit.fit(times: idx.map { trace.t[$0] }, values: idx.map { trace.sensors["battery"]![$0] }) {
                print("Naive cooling fit (battery, after last burst)")
                print("  asymptote                 \(fmt(fit.asymptote)) °C   error \(signed(fit.asymptote - room))  ← idle power bias")
                print("  time constants            \(fit.tau.map { fmt($0, 0) + " s" }.joined(separator: ", "))\n")
            }
        }

        print("RC identification (integral form)")
        var estimates: [RCIdentification.Estimate] = []
        for slow in ["battery", "palm"] {
            guard let e = RCIdentification.estimate(ThermalSimulator.samples(trace, fast: "soc", slow: slow)) else {
                print("  \(pad(slow, 10)) not identifiable (too little excitation)")
                continue
            }
            estimates.append(e)
            print("  \(pad(slow, 10)) \(fmt(e.room)) °C ± \(fmt(e.roomSE))   error \(signed(e.room - room))   (\(e.windows) windows)")
        }
        if let c = RCIdentification.combine(estimates) {
            print("  \(pad("combined", 10)) \(fmt(c.room)) °C ± \(fmt(c.se))   error \(signed(c.room - room))")
        }

        if let csvPath {
            do {
                let out = try output(csvPath)
                let names = trace.sensors.keys.sorted()
                out.write(Data((["t", "room", "power_w", "fan_rpm", "node1", "node2"] + names).joined(separator: ",").appending("\n").utf8))
                for i in trace.t.indices {
                    let row = [trace.t[i], trace.room[i], trace.power[i], trace.fanRPM[i], trace.t1[i], trace.t2[i]]
                        + names.map { trace.sensors[$0]![i] }
                    out.write(Data((row.map { fmt($0, 3) }.joined(separator: ",") + "\n").utf8))
                }
                print("\nwrote \(trace.t.count) rows to \(csvPath)")
            } catch {
                fail("\(error)")
            }
        }
    }

    // MARK: fit (real data, experimental)

    /// Applies RC identification to recorded data. Experimental until Phase 4: a real Mac
    /// is not a two-node system, so per-sensor answers may disagree.
    static func fit(dbPath: String, since: Double) {
        do {
            let store = try SampleStore(path: dbPath)
            let channels = try store.channelNames()
            let from = since > 0 ? since : Date().timeIntervalSince1970 - 3 * 3600
            let rows = try store.rows(from: from)
            guard !rows.isEmpty else { fail("no samples in the window — is the recorder running?") }

            var ticks: [Double: [String: Double]] = [:]
            for r in rows { ticks[r.t, default: [:]][r.channel] = r.value }
            let times = ticks.keys.sorted()
            let fastNames = channels.map(\.name).filter { $0.hasPrefix("hid:PMU tdie") }
            let slowNames = channels.filter { ["battery", "ssd", "skin", "display"].contains($0.category) && $0.kind == "temperature" }.map(\.name)
            guard !fastNames.isEmpty else { fail("no SoC (hid:PMU tdie*) channels recorded") }

            func samples(slow: String) -> [RCIdentification.Sample] {
                times.compactMap { t in
                    let v = ticks[t]!
                    let fast = fastNames.compactMap { v[$0] }
                    guard !fast.isEmpty, let s = v[slow] else { return nil }
                    return RCIdentification.Sample(t: t, fast: fast.reduce(0, +) / Double(fast.count),
                                                   slow: s, fanRPM: v["fan:0"] ?? 0)
                }
            }

            let span = (times.last! - times.first!) / 3600
            let power = times.compactMap { ticks[$0]!["smc:PSTR"] }
            print("thermac fit — EXPERIMENTAL (real Mac ≠ two-node model; superseded by `thermac now`)")
            print("  window      \(stamp(times.first!)) → \(stamp(times.last!)) (\(fmt(span, 1)) h, \(times.count) ticks)")
            if let lo = power.min(), let hi = power.max() {
                print("  power       \(fmt(lo, 1))–\(fmt(hi, 1)) W   (excitation: wider is better)")
            }
            print()

            var estimates: [RCIdentification.Estimate] = []
            for name in slowNames {
                guard let e = RCIdentification.estimate(samples(slow: name)) else {
                    print("  \(pad(name, 26)) —  not enough data yet (needs ≥ 16 min incl. load changes)")
                    continue
                }
                let plausible = e.room > 5 && e.room < 40 && (e.roomSE ?? 99) < 5
                if plausible { estimates.append(e) }
                print("  \(pad(name, 26)) \(fmt(e.room)) °C ± \(fmt(e.roomSE))  τ \(fmt(e.slowTau, 0)) s\(plausible ? "" : "  (rejected)")")
            }
            print()
            if let c = RCIdentification.combine(estimates) {
                print("  combined estimate          \(fmt(c.room)) °C ± \(fmt(c.se)) (\(estimates.count) sensors)")
            } else {
                print("  combined estimate          — (record a few hours of normal use, then try again)")
            }
            for cand in ["smc:TVA0", "smc:TAOL"] {
                let v = times.compactMap { ticks[$0]![cand] }
                if !v.isEmpty { print("  \(pad(cand + " (mean)", 26)) \(fmt(v.reduce(0, +) / Double(v.count))) °C   ambient candidate") }
            }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: estimate (Phase 4)

    /// Power-response estimate over the window since the last cold-start anchor.
    static func estimate(dbPath: String, since: Double, verbose: Bool, drift: Bool,
                         kappa: Double = 0, scan: Bool = false) {
        do {
            let store = try SampleStore(path: dbPath)
            let anchors = try store.events(type: "cold_start")
            let anchor = since > 0 ? nil : anchors.last
            guard let from = since > 0 ? since : anchor?.time else {
                fail("no cold-start anchor yet — sleep the Mac ≥ 2 h, or pass --since 12h")
            }
            let rows = try store.rows(from: from)
            var ticks: [Double: [String: Double]] = [:]
            for r in rows { ticks[r.t, default: [:]][r.channel] = r.value }
            let times = ticks.keys.sorted().filter { ticks[$0]!["smc:PSTR"] != nil }
            guard times.count > 100 else { fail("not enough samples since \(stamp(from))") }

            let channels = try store.channelNames()
            let candidates = channels.filter {
                $0.kind == "temperature" && ["battery", "ssd", "skin", "display", SensorCategory.ambientCandidate.rawValue].contains($0.category)
            }.map(\.name)

            // Equilibrium check: at a cold start every sensor should read the same.
            let first = ticks[times[0]]!
            let atStart = candidates.compactMap { n in first[n].map { (n, $0) } }
            let median = atStart.map(\.1).sorted()[atStart.count / 2]
            let consistent = anchor == nil ? Set(candidates)
                : Set(atStart.filter { abs($0.1 - median) <= 1.0 }.map(\.0))

            let input = PowerResponse.Input(
                t: times,
                power: times.map { ticks[$0]!["smc:PSTR"]! },
                charge: times.map { t in
                    let v = ticks[t]!
                    guard (v["sys:charging"] ?? 0) > 0, let dc = v["smc:PDTR"] else { return 0 }
                    return max(0, dc - v["smc:PSTR"]!)
                },
                sensors: Dictionary(uniqueKeysWithValues: candidates.filter(consistent.contains).map { n in
                    (n, times.map { ticks[$0]![n] })
                }))

            let span = (times.last! - times.first!) / 3600
            print("thermac estimate — power-response model (Phase 4, experimental)")
            print("  window      \(stamp(times.first!)) → \(stamp(times.last!)) (\(fmt(span, 1)) h)")
            if let anchor {
                print("  starts at   cold-start anchor (\(anchor.detail ?? ""))")
                print("  at anchor   sensors read \(fmt(median)) °C (median of \(atStart.count))")
                let dropped = candidates.filter { !consistent.contains($0) && first[$0] != nil }
                if !dropped.isEmpty {
                    print("  excluded    \(dropped.joined(separator: ", ")) — off by > 1 °C at equilibrium")
                }
            }
            // Night: the sleep session that ended at the anchor (power ≈ 0 → plain cooling).
            if let anchor, let session = Commands.detailNumber(anchor.detail, "session_s") {
                let start = anchor.time - session
                var series: [String: [(t: Double, value: Double)]] = [:]
                for n in consistent { series[n] = try store.series(n, from: start, to: anchor.time + 1) }
                if let night = CoolingFit.night(series, from: start) {
                    print("  night       cooling asymptote \(fmt(night.room)) °C ± \(fmt(night.spread)) (MAD, \(night.sensors) sensors), τ ≈ \(fmt(night.tau / 3600, 1)) h")
                }
            }
            let charging = input.charge.contains { $0 > 5 }
            print("  power       \(fmt(input.power.min(), 1))–\(fmt(input.power.max(), 1)) W\(charging ? ", charging included" : "")\n")

            if scan {
                print("  κ (1/°C)   room °C   sensor SD   range")
                for k in [0, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12] {
                    guard let e = PowerResponse.estimate(input, coldStart: anchor != nil, kappa: k) else {
                        print("  \(pad(fmt(k, 2), 10)) —"); continue
                    }
                    let r = e.sensors.map(\.room).sorted()
                    print("  \(pad(fmt(k, 2), 10)) \(pad(fmt(e.room), 9)) ± \(pad(fmt(e.sensorSpread), 8)) \(fmt(r.first))–\(fmt(r.last))")
                }
                return
            }
            let fitted = kappa > 0 ? PowerResponse.estimate(input, coldStart: anchor != nil, kappa: kappa)
                                   : PowerResponse.estimate(input, coldStart: anchor != nil, drift: drift)
            guard let e = fitted else {
                fail("model could not be fitted (too little data or no load variation)")
            }
            let rooms = e.sensors.map(\.room).sorted()
            if verbose {
                for s in e.sensors.sorted(by: { $0.rms < $1.rms }) {
                    let taus = s.tau.map { fmt($0, 0) }.joined(separator: "/")
                    print("  \(pad(s.name, 24)) \(fmt(s.room)) °C   rms \(fmt(s.rms, 3))   \(fmt(s.rPerWatt, 3)) °C/W   τ \(taus) s")
                }
                print()
            }
            if drift {
                print("  room at start         \(fmt(e.room)) °C ± \(fmt(e.roomSE, 3)) (statistical)")
                print("  room drift            \(signed(e.drift)) per hour → \(fmt(e.room + e.drift * span)) °C now")
            } else {
                print("  room (joint fit)      \(fmt(e.room)) °C ± \(fmt(e.roomSE, 3)) (statistical)")
            }
            print("  sensor agreement      ± \(fmt(e.sensorSpread)) °C SD over \(e.sensors.count) sensors (range \(fmt(rooms.first))–\(fmt(rooms.last)))")
            print("  note: assumes the room temperature was \(drift ? "changing linearly" : "constant") over the window")
        } catch {
            fail("\(error)")
        }
    }

    static func detailNumber(_ detail: String?, _ key: String) -> Double? {
        AnchorData.detailNumber(detail, key)
    }

    static func signed(_ v: Double) -> String { (v >= 0 ? "+" : "") + fmt(v) + " °C" }
}
