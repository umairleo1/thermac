import Foundation
import Testing
@testable import ThermacCore

@Suite("Relocation")
struct RelocationTests {
    /// Ticks every 5 s while awake; while asleep only isolated maintenance-wake ticks.
    func ticks(awake: [ClosedRange<Double>], darkEvery: Double = 900) -> [Double] {
        var t: [Double] = []
        for (k, r) in awake.enumerated() {
            t += stride(from: r.lowerBound, through: r.upperBound, by: 5).map { $0 }
            if k + 1 < awake.count {
                t += stride(from: r.upperBound + darkEvery, to: awake[k + 1].lowerBound, by: darkEvery).map { $0 }
            }
        }
        return t
    }

    @Test func detectsAbsencesThroughMaintenanceWakes() {
        // Awake 0–1 h, lid closed 80 min (maintenance ticks inside), awake again.
        let t = ticks(awake: [0...3600, 8400...9000])
        let away = RoomFilter.absences(t)
        #expect(away.count == 1)
        let (j, d) = away.first!
        #expect(t[j] == 8400 && d == 4800)
        // A plain 10 s hiccup is not an absence.
        #expect(RoomFilter.absences([0, 5, 10, 20, 25]).isEmpty)
    }

    /// Model observations follow what the Mac "feels" (45-min lag to its surroundings)
    /// plus the measured fast model error.
    func simulate(room: (Double) -> Double, t: [Double], tuning: RoomFilter.Tuning, seed: UInt64) -> [Double] {
        var rng = SeededRandom(seed: seed)
        var f = RoomFilter(room: room(t[0]), roomSD: 0.3, tuning: tuning)
        var felt = room(t[0]), err = 0.0
        let input = PowerResponse.Input(t: t, power: t.map { _ in 5 }, sensors: [:])
        var y: [Double?] = []
        var prev = t[0]
        for ti in t {
            let dt = ti - prev; prev = ti
            felt += (room(ti) - felt) * (1 - exp(-dt / 2700))
            let phi = exp(-dt / 2700)
            err = phi * err + 1.75 * (1 - phi * phi).squareRoot() * rng.gaussian()
            y.append(felt + err + 0.3 * rng.gaussian())
        }
        var out: [Double] = []
        f.run(input, predictions: y, trust: RoomFilter.modelTrust(input), from: t[0]) { _, s in out.append(s.room) }
        return out
    }

    @Test func followsAMoveMadeWithTheLidClosed() {
        // Home 18 °C until 3 h; lid closed 80 min (commute); office 22 °C afterwards.
        let wake = 3 * 3600.0 + 4800
        let t = ticks(awake: [0.0...(3 * 3600.0), wake...(wake + 2 * 3600)])
        let room = { (x: Double) in x < 3 * 3600 + 1200 ? 18.0 : 22.0 }
        var noRelocation = RoomFilter.Tuning(); noRelocation.relocationGap = .infinity
        var with: [Double] = [], without: [Double] = []
        let oneHourIn = t.firstIndex { $0 >= wake + 3600 }!
        for seed in 1...10 as ClosedRange<UInt64> {
            with.append(simulate(room: room, t: t, tuning: RoomFilter.Tuning(), seed: seed)[oneHourIn])
            without.append(simulate(room: room, t: t, tuning: noRelocation, seed: seed)[oneHourIn])
        }
        // Measured trade-off (see `Tuning.relocationSD`): about 0.9 °C closer after 1 h.
        let mWith = with.reduce(0, +) / 10, mWithout = without.reduce(0, +) / 10
        #expect(mWith - mWithout > 0.6, "1 h after arriving: \(mWith) °C with vs \(mWithout) °C without")
        #expect(mWith > 19.7, "1 h after arriving: \(mWith) °C")   // no-relocation baseline ≈ 19.5
    }

    @Test func aLunchBreakAtHomeDoesNoHarm() {
        let wake = 3 * 3600.0 + 4800
        let t = ticks(awake: [0.0...(3 * 3600.0), wake...(wake + 2 * 3600)])
        let oneHourIn = t.firstIndex { $0 >= wake + 3600 }!
        var errors: [Double] = []
        for seed in 1...10 as ClosedRange<UInt64> {
            errors.append(abs(simulate(room: { _ in 18 }, t: t, tuning: RoomFilter.Tuning(), seed: seed)[oneHourIn] - 18))
        }
        let rms = (errors.map { $0 * $0 }.reduce(0, +) / 10).squareRoot()
        #expect(rms < 1.0, "same room after a break: RMS \(rms) °C")   // inside the app's ± 1 °C
    }

    @Test func modelIsTrustedLessForAnHourAfterAnAbsence() {
        let t = ticks(awake: [0...7200, 12000...20000])
        let trust = RoomFilter.modelTrust(PowerResponse.Input(t: t, power: t.map { _ in 5 }, sensors: [:]))
        func at(_ s: Double) -> Double { trust[t.firstIndex { $0 >= s }!] }
        #expect(at(5000) == 1)
        #expect(at(12000 + 600) == 0.25)
        #expect(at(12000 + 4000) == 1)
    }
}

@Suite("Place-aware reference")
struct PlaceAwareReferenceTests {
    let home = AnchorData.Night(start: 0, end: 10_000, room: 18, atWake: 18.2, spread: 0.2, consistent: [])
    let nextHome = AnchorData.Night(start: 60_000, end: 90_000, room: 17, atWake: 17.1, spread: 0.2, consistent: [])

    @Test func noAbsenceInterpolatesBetweenNights() {
        let t = stride(from: 10_000.0, through: 60_000, by: 5).map { $0 }
        let ref = AnchorData.dayReference(t: t, night: home, next: nextHome, nights: [home, nextHome])
        #expect(ref.first! == 18 && abs(ref.last! - 17) < 1e-6 && ref.allSatisfy(\.isFinite))
    }

    @Test func middleOfTheDayAfterAMoveIsUnknown() {
        // Home morning, lid closed 80 min, office, lid closed again, home evening.
        let t = stride(from: 10_000.0, through: 20_000, by: 5).map { $0 }
            + stride(from: 24_800.0, through: 40_000, by: 5).map { $0 }
            + stride(from: 45_000.0, through: 59_000, by: 5).map { $0 }
        let ref = AnchorData.dayReference(t: t, night: home, next: nextHome, nights: [home, nextHome])
        #expect(ref[0] == 18)                                       // morning: last night's place
        #expect(ref[t.firstIndex { $0 >= 30_000 }!].isNaN)          // office: unknown
        #expect(ref.last! == 17)                                    // evening: next night's place
        let noNext = AnchorData.dayReference(t: t, night: home, next: nil, nights: [home])
        #expect(noNext.last!.isNaN)                                 // next sleep elsewhere: unknown
    }
}

@Suite("Calibration with unknown places")
struct CalibrationMaskTests {
    @Test func unknownTicksAreNotFitted() throws {
        // A sensor that reads room + 0.4·lag(P); half the day's reference is unknown and
        // wildly wrong values there must not matter.
        let t = stride(from: 0.0, through: 6 * 3600, by: 5).map { $0 }
        let power: [Double] = t.map { $0 < 7200 ? 5 : ($0 < 10_800 ? 20 : 8) }
        var input = PowerResponse.Input(t: t, power: power, sensors: [:])
        let lag = PowerResponse.lowPass(input, power, tau: 2700, maxStep: 60, initial: 0)
        input = PowerResponse.Input(t: t, power: power, sensors: ["s": t.indices.map { Optional(19 + 0.4 * lag[$0]) }])
        let clean = TransferCalibration.Segment(input: input, reference: t.map { _ in 19 })
        let masked = TransferCalibration.Segment(input: input, reference: t.map { $0 > 12_000 ? .nan : 19 })
        let a = try #require(TransferCalibration.calibrate([clean]))
        let b = try #require(TransferCalibration.calibrate([masked]))
        #expect(abs(a.sensors[0].gain.reduce(0, +) - b.sensors[0].gain.reduce(0, +)) < 0.02)
        let pred = TransferCalibration.predict(b, input).compactMap { $0 }
        #expect(pred.allSatisfy { abs($0 - 19) < 0.2 })
    }
}
