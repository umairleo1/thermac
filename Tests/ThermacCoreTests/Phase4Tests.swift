import Foundation
import Testing
@testable import ThermacCore

@Suite("Power response")
struct PowerResponseTests {
    /// A morning after a cold start: idle with bursts, room constant, linear thermal network.
    func coldStartDay(room: Double, seed: UInt64) -> SimulationTrace {
        let profile = PowerProfile(segments: [(0, 0), (60, 5), (1800, 25), (2700, 6), (6000, 30),
                                              (6600, 5), (10_000, 18), (11_000, 7)])
        return ThermalSimulator.run(parameters: .m4ProLike, duration: 5 * 3600, power: profile,
                                    room: { _ in room }, fan: nil, seed: seed)
    }

    func input(_ trace: SimulationTrace, sensors: [String]) -> PowerResponse.Input {
        let step = 5.0
        let idx = trace.t.indices.filter { trace.t[$0].truncatingRemainder(dividingBy: step) == 0 }
        return PowerResponse.Input(t: idx.map { trace.t[$0] }, power: idx.map { trace.power[$0] },
                                   sensors: Dictionary(uniqueKeysWithValues: sensors.map { n in
                                       (n, idx.map { Optional(trace.sensors[n]![$0]) })
                                   }))
    }

    @Test(arguments: [(18.5, UInt64(1)), (21.0, 2), (26.0, 3)])
    func recoversRoomAfterColdStart(room: Double, seed: UInt64) throws {
        let trace = coldStartDay(room: room, seed: seed)
        let e = try #require(PowerResponse.estimate(input(trace, sensors: ["battery", "palm"]), coldStart: true))
        #expect(abs(e.room - room) < 0.2, "room \(room): got \(e.room)")
        #expect(e.sensors.allSatisfy { $0.rPerWatt > 0 })
    }

    @Test func lowPassDecaysThroughGaps() {
        let input = PowerResponse.Input(t: [0, 5, 10, 3610], power: [10, 10, 10, 10], sensors: [:])
        let x = PowerResponse.lowPass(input, input.power, tau: 600, maxStep: 60, initial: 10)
        #expect(abs(x[2] - 10) < 1e-12)
        #expect(abs(x[3] - 10 * exp(-3600 / 600)) < 1e-9)   // asleep: P = 0 during the gap
    }

    @Test func chargingHeatIsSeparatedFromSystemPower() throws {
        // Battery sensor = room + 0.5 °C/W of lagged system power + 0.08 °C/W of lagged charge power.
        let t = stride(from: 0.0, through: 6 * 3600, by: 5).map { $0 }
        let power: [Double] = t.map { $0 < 3600 ? 5 : ($0 < 7200 ? 20 : ($0 < 12_000 ? 6 : 12)) }
        let charge: [Double] = t.map { $0 >= 9000 && $0 < 15_000 ? 60.0 : 0 }
        var input = PowerResponse.Input(t: t, power: power, charge: charge, sensors: [:])
        let xp = PowerResponse.lowPass(input, power, tau: 2700, maxStep: 60, initial: 0)
        let xc = PowerResponse.lowPass(input, charge, tau: 1200, maxStep: 60, initial: 0)
        let s = t.indices.map { Optional(20 + 0.5 * xp[$0] + 0.08 * xc[$0]) }
        input = PowerResponse.Input(t: t, power: power, charge: charge, sensors: ["battery": s])
        let e = try #require(PowerResponse.estimate(input, coldStart: true))
        #expect(abs(e.room - 20) < 0.05)
        #expect(e.sensors[0].tau.count == 3)
    }
}

@Suite("Night cooling")
struct NightCoolingTests {
    /// Evening use, then a night asleep (P = 0), sampled only at DarkWakes every ~15 min.
    @Test(arguments: [17.0, 19.0, 23.5])
    func asymptoteFromDarkWakeTicks(room: Double) throws {
        let sleepAt = 2 * 3600.0
        let trace = ThermalSimulator.run(parameters: .m4ProLike, duration: sleepAt + 9 * 3600,
                                         power: PowerProfile(segments: [(0, 8), (sleepAt, 0)]),
                                         room: { _ in room }, fan: nil, seed: 5)
        var series: [String: [(t: Double, value: Double)]] = [:]
        for name in ["battery", "palm"] {
            series[name] = trace.t.indices
                .filter { trace.t[$0] >= sleepAt && (trace.t[$0] - sleepAt).truncatingRemainder(dividingBy: 905) == 0 }
                .map { (trace.t[$0], trace.sensors[name]![$0]) }
        }
        let night = try #require(CoolingFit.night(series, from: sleepAt))
        #expect(abs(night.room - room) < 0.2, "room \(room): got \(night.room)")
        #expect(night.sensors == 2)
    }
}

@Suite("Transfer calibration")
struct TransferCalibrationTests {
    func day(room: Double, seed: UInt64, bursts: [(Double, Double)]) -> TransferCalibration.Segment {
        let profile = PowerProfile(segments: [(0, 0), (60, 5)] + bursts)
        let trace = ThermalSimulator.run(parameters: .m4ProLike, duration: 6 * 3600, power: profile,
                                         room: { _ in room }, fan: nil, seed: seed)
        let idx = trace.t.indices.filter { trace.t[$0].truncatingRemainder(dividingBy: 5) == 0 }
        let input = PowerResponse.Input(t: idx.map { trace.t[$0] }, power: idx.map { trace.power[$0] },
                                        sensors: ["battery", "palm"].reduce(into: [:]) { d, n in
                                            d[n] = idx.map { Optional(trace.sensors[n]![$0]) }
                                        })
        return TransferCalibration.Segment(input: input, reference: idx.map { _ in room })
    }

    /// Calibrated on two days in other rooms with other usage, it predicts a third day.
    @Test func predictsHeldOutDayInADifferentRoom() throws {
        let a = day(room: 18, seed: 1, bursts: [(1800, 25), (2700, 6), (9000, 15), (12_000, 5)])
        let b = day(room: 22, seed: 2, bursts: [(3600, 30), (4500, 7), (14_000, 20), (16_000, 6)])
        let c = day(room: 16.5, seed: 3, bursts: [(2400, 18), (6000, 9), (11_000, 28), (12_500, 5)])
        let model = try #require(TransferCalibration.calibrate([a, b]))
        let pred = TransferCalibration.predict(model, c.input).compactMap { $0 }
        let mean = pred.reduce(0, +) / Double(pred.count)
        #expect(abs(mean - 16.5) < 0.2, "mean \(mean)")
        // Brief misses at sudden load steps (lags come from a grid); bound the bulk tightly.
        let errors = pred.map { abs($0 - 16.5) }.sorted()
        let p95 = errors[errors.count * 95 / 100]
        #expect(p95 < 0.5, "p95 \(p95)")
        #expect(errors.last! < 1.5, "worst \(errors.last!)")
    }
}

@Suite("Room filter")
struct RoomFilterTests {
    /// Model observations = room + AR(1) error with the measured fast statistics.
    func run(room: (Double) -> Double, start: Double, hours: Double, seed: UInt64) -> RoomFilter {
        var rng = SeededRandom(seed: seed)
        var f = RoomFilter(room: start, roomSD: 0.25)
        var err = 0.0
        let dt = 5.0, phi = exp(-dt / 1800)
        for k in 1...Int(hours * 3600 / dt) {
            err = phi * err + 1.7 * (1 - phi * phi).squareRoot() * rng.gaussian()
            f.predict(dt: dt)
            f.observeModel(room(Double(k) * dt) + err + 0.3 * rng.gaussian())
        }
        return f
    }

    @Test(arguments: 1...5)
    func averagesAwayFastModelError(seed: Int) {
        let f = run(room: { _ in 19 }, start: 19, hours: 8, seed: UInt64(seed))
        #expect(abs(f.room - 19) < 2 * f.roomSD, "seed \(seed): \(f.room) ± \(f.roomSD)")
        #expect(f.roomSD < 1.2)
    }

    /// Room drops 2 °C an hour after the anchor (window opened). A slow model error and
    /// a room change look alike within a day, so the filter follows only partly — the
    /// honest price of the measured error statistics — and its ± must cover the lag.
    @Test func followsARoomChangeAndReportsTheLag() {
        var errs: [Double] = []
        for seed in 1...8 as ClosedRange<UInt64> {
            let f = run(room: { $0 < 3600 ? 19 : 17 }, start: 19, hours: 9, seed: seed)
            errs.append(f.room - 17)
            #expect(abs(f.room - 17) < 2 * f.roomSD, "seed \(seed): \(f.room) ± \(f.roomSD)")
        }
        let mean = errs.reduce(0, +) / Double(errs.count)
        #expect(mean < 1.0, "recovered only \(2 - mean) of 2 °C")   // ≥ half of the step
    }

    @Test func anchorObservationDominates() {
        var f = RoomFilter(room: 22, roomSD: 3)
        f.observeRoom(18, sd: 0.2)
        #expect(abs(f.room - 18) < 0.05 && f.roomSD < 0.21)
        f.predict(dt: 10 * 3600)                      // a day without data: uncertainty grows
        #expect(f.roomSD > 1.5)
    }
}

@Suite("Live estimator")
struct LiveEstimatorTests {
    @Test func emptyDatabaseWaitsForFirstNight() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("thermac-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SampleStore(path: path)
        let e = try await LiveEstimator(dbPath: path).estimate(now: 1_000_000)
        #expect(e.source == .waiting && e.room == nil && e.goodNights == 0)
    }

    @Test func modelTrustDropsWhileChargingAndAfterWake() {
        let t = stride(from: 0.0, through: 4 * 3600, by: 5).map { $0 }
        let charge = t.map { $0 >= 7200 && $0 < 9000 ? 60.0 : 0 }
        let input = PowerResponse.Input(t: t, power: t.map { _ in 5 }, charge: charge, sensors: [:])
        let trust = RoomFilter.modelTrust(input)
        func at(_ s: Double) -> Double { trust[Int(s / 5)] }
        #expect(at(600) == 0.25)              // first hour after wake
        #expect(at(5000) == 1)                // normal use
        #expect(at(8000) == 0.1)              // charging
        #expect(at(9000 + 1800) == 0.1)       // within an hour after charging
        #expect(at(9000 + 4000) == 1)
    }
}

@Suite("Live trend")
struct LiveTrendTests {
    func estimate(_ history: [(Double, Double)]) -> LiveEstimate {
        LiveEstimate(room: history.last?.1, roomSD: 1, source: .filter, lastNight: nil, goodNights: 2,
                     history: history.map { ($0.0, $0.1, 1) }, lastSample: history.last?.0,
                     computedAt: history.last?.0 ?? 0, message: "")
    }

    @Test func trendOverLastHour() throws {
        let h = stride(from: 0.0, through: 7200, by: 300).map { ($0, 18 - $0 / 7200) }   // −0.5 °C/h
        let trend = try #require(estimate(h).trend())
        #expect(abs(trend + 0.5) < 0.01)
    }

    @Test func noTrendWithoutEnoughHistory() {
        #expect(estimate([(0, 18), (600, 18.2)]).trend() == nil)
    }
}

@Suite("Change detection")
struct ChangeDetectionTests {
    /// Model observations follow what the Mac "feels" (45-min lag to a new environment)
    /// plus the measured fast model error.
    func run(to newRoom: Double, minutes: Double, tuning: RoomFilter.Tuning, seed: UInt64) -> RoomFilter {
        var rng = SeededRandom(seed: seed)
        var f = RoomFilter(room: 17, roomSD: 0.3, tuning: tuning)
        var err = 0.0, felt = 17.0
        let dt = 5.0, phi = exp(-dt / 1800), a = exp(-dt / 2700)
        for _ in 0..<(2 * 720) {
            err = phi * err + 1.7 * (1 - phi * phi).squareRoot() * rng.gaussian()
            f.predict(dt: dt); f.observeModel(17 + err + 0.3 * rng.gaussian())
        }
        for _ in 0..<Int(minutes * 12) {
            felt = a * felt + (1 - a) * newRoom
            err = phi * err + 1.7 * (1 - phi * phi).squareRoot() * rng.gaussian()
            f.predict(dt: dt); f.observeModel(felt + err + 0.3 * rng.gaussian())
        }
        return f
    }

    @Test func carriedOutsideIsFollowedWithinTwoHours() {
        var on: [Double] = [], off: [Double] = []
        var noDetect = RoomFilter.Tuning(); noDetect.changeThreshold = nil
        for seed in 1...10 as ClosedRange<UInt64> {
            on.append(run(to: 5, minutes: 120, tuning: RoomFilter.Tuning(), seed: seed).room)
            off.append(run(to: 5, minutes: 120, tuning: noDetect, seed: seed).room)
        }
        let meanOn = on.reduce(0, +) / 10, meanOff = off.reduce(0, +) / 10
        #expect(meanOn < 9, "with detection: \(meanOn)")
        #expect(meanOff > 12, "without detection: \(meanOff)")
    }

    @Test func noFalseAlarmInASteadyRoom() {
        for seed in 1...10 as ClosedRange<UInt64> {
            let f = run(to: 17, minutes: 12 * 60, tuning: RoomFilter.Tuning(), seed: seed)
            #expect(!f.changeDetected && abs(f.room - 17) < 2 * f.roomSD)
        }
    }

    @Test func lowTrustObservationsCannotTriggerIt() {
        var f = RoomFilter(room: 17, roomSD: 0.3)
        for _ in 0..<720 { f.predict(dt: 5); f.observeModel(30, trust: 0.1) }   // e.g. charging heat
        #expect(!f.changeDetected)
    }
}
