import Foundation
import Testing
@testable import ThermacCore

@Suite("Linear algebra & LM")
struct SolverTests {
    @Test func solvesLinearSystem() throws {
        let x = try #require(LinearAlgebra.solve([[2, 1], [1, 3]], [3, 5]))
        #expect(abs(x[0] - 0.8) < 1e-12 && abs(x[1] - 1.4) < 1e-12)
        #expect(LinearAlgebra.solve([[1, 2], [2, 4]], [1, 2]) == nil) // singular
    }

    @Test func leastSquaresRecoversLine() throws {
        let xs = (0..<20).map(Double.init)
        let fit = try #require(LinearAlgebra.leastSquares(xs.map { [$0, 1] }, xs.map { 3 * $0 - 2 }))
        #expect(abs(fit.theta[0] - 3) < 1e-9 && abs(fit.theta[1] + 2) < 1e-9)
    }

    @Test func lmFitsExponential() throws {
        let t = stride(from: 0.0, to: 300, by: 5).map { $0 }
        let y = t.map { 20 + 10 * exp(-$0 / 60) }
        let r = try #require(LevenbergMarquardt.fit(initial: [15, 5, 30]) { p in
            zip(t, y).map { p[0] + p[1] * exp(-$0 / p[2]) - $1 }
        })
        #expect(abs(r.parameters[0] - 20) < 1e-6)
        #expect(abs(r.parameters[2] - 60) < 1e-4)
        #expect(r.rms < 1e-8)
    }
}

@Suite("Cooling fit")
struct CoolingFitTests {
    @Test func threePointIsExactForSingleExponential() throws {
        let f = { (t: Double) in 22 + 15 * exp(-t / 300) }
        let est = try #require(CoolingFit.threePointAsymptote(f(0), f(200), f(400)))
        #expect(abs(est - 22) < 1e-9)
        #expect(CoolingFit.threePointAsymptote(5, 5, 5) == nil) // flat: undefined
    }

    @Test func doubleExponentialRecoversAsymptoteUnderNoise() throws {
        var rng = SeededRandom(seed: 7)
        let t = stride(from: 0.0, through: 3600, by: 5).map { $0 }
        let y = t.map { 25 + 4 * exp(-$0 / 45) + 9 * exp(-$0 / 900) + 0.03 * rng.gaussian() }
        let fit = try #require(CoolingFit.fit(times: t, values: y, model: .double))
        #expect(abs(fit.asymptote - 25) < 0.15)
        #expect(abs(fit.tau[0] - 45) / 45 < 0.2)
        #expect(abs(fit.tau[1] - 900) / 900 < 0.1)
    }

    @Test func sleepExtrapolation() throws {
        // Slow sensor at 33 °C goes to sleep in a 20 °C room; τ = 30 min; wakes after 40 min.
        let tau = 1800.0, slept = 2400.0
        let wake = 20 + 13 * exp(-slept / tau)
        let est = try #require(CoolingFit.sleepExtrapolation(beforeSleep: 33, afterWake: wake, slept: slept, tau: tau))
        #expect(abs(est - 20) < 1e-9)
        #expect(CoolingFit.sleepExtrapolation(beforeSleep: 33, afterWake: 33, slept: 1, tau: tau) == nil)
    }

    /// Key Phase 3 finding: an awake Mac cools toward T_room + P_idle/G, not T_room.
    @Test func awakeCoolDownAsymptoteIsBiasedByIdlePower() throws {
        let p = ThermalParameters.m4ProLike
        let room = 21.0, idle = 5.0
        let profile = PowerProfile(segments: [(0, idle), (600, 35), (1500, idle)])
        let trace = ThermalSimulator.run(parameters: p, duration: 1500 + 3 * 3600, power: profile,
                                         room: { _ in room }, sensors: [SimulatedSensor(name: "battery", node: 2)])
        let after = trace.t.indices.filter { trace.t[$0] >= 1500 + 120 }
        let fit = try #require(CoolingFit.fit(times: after.map { trace.t[$0] },
                                              values: after.map { trace.sensors["battery"]![$0] }))
        let expected = p.steadyState(power: idle, room: room).t2      // room + 8.3 °C
        #expect(abs(fit.asymptote - expected) < 0.3)
        #expect(fit.asymptote - room > 7)                             // naive Newton: badly wrong
    }
}

@Suite("Simulator")
struct SimulatorTests {
    @Test func holdsAnalyticSteadyState() {
        let p = ThermalParameters.m4ProLike
        let trace = ThermalSimulator.run(parameters: p, duration: 600, power: PowerProfile(segments: [(0, 6)]),
                                         room: { _ in 20 }, sensors: [], fan: nil)
        let ss = p.steadyState(power: 6, room: 20)
        #expect(abs(trace.t1.last! - ss.t1) < 1e-6 && abs(trace.t2.last! - ss.t2) < 1e-6)
    }

    @Test func approachesNewSteadyStateWithSlowTimeConstant() {
        let p = ThermalParameters.m4ProLike
        let trace = ThermalSimulator.run(parameters: p, duration: 6 * 3600,
                                         power: PowerProfile(segments: [(0, 5), (1, 12)]),
                                         room: { _ in 20 }, sensors: [], fan: nil)
        let ss = p.steadyState(power: 12, room: 20)
        #expect(abs(trace.t2.last! - ss.t2) < 0.05)
    }

    @Test func fanSpinsOnlyUnderHeavyLoad() {
        let trace = ThermalSimulator.run(parameters: .m4ProLike, duration: 1800,
                                         power: PowerProfile(segments: [(0, 5), (300, 45)]),
                                         room: { _ in 22 }, sensors: [])
        #expect(trace.fanRPM.first == 0)
        #expect(trace.fanRPM.max()! > 1000)
    }

    @Test func isDeterministicPerSeed() {
        let run = { (seed: UInt64) in
            ThermalSimulator.run(parameters: .m4ProLike, duration: 300, power: PowerProfile(segments: [(0, 5)]),
                                 room: { _ in 20 }, seed: seed).sensors["soc"]!
        }
        #expect(run(3) == run(3))
        #expect(run(3) != run(4))
    }
}

@Suite("RC identification")
struct RCIdentificationTests {
    func randomScenario(seed: UInt64) -> (trace: SimulationTrace, room: Double) {
        var rng = SeededRandom(seed: seed)
        let base = ThermalParameters.m4ProLike
        let p = ThermalParameters(c1: base.c1 * rng.uniform(0.7...1.3), c2: base.c2 * rng.uniform(0.7...1.3),
                                  r12: base.r12 * rng.uniform(0.7...1.3), g0: base.g0 * rng.uniform(0.7...1.3),
                                  gFan: base.gFan * rng.uniform(0.7...1.3))
        let room = rng.uniform(15...28)
        let profile = PowerProfile.idleWithBursts(duration: 3 * 3600, rng: &rng)
        let trace = ThermalSimulator.run(parameters: p, duration: 3 * 3600, power: profile,
                                         room: { _ in room }, seed: seed)
        return (trace, room)
    }

    @Test func exactDataRecoversRoomPrecisely() throws {
        let profile = PowerProfile(segments: [(0, 5), (1200, 30), (1800, 5), (5400, 25), (6000, 5)])
        let trace = ThermalSimulator.run(parameters: .m4ProLike, duration: 3 * 3600, power: profile,
                                         room: { _ in 19.5 },
                                         sensors: [SimulatedSensor(name: "soc", node: 1),
                                                   SimulatedSensor(name: "battery", node: 2)])
        let est = try #require(RCIdentification.estimate(ThermalSimulator.samples(trace, fast: "soc", slow: "battery")))
        #expect(abs(est.room - 19.5) < 0.05)
        let expectedTau = 1100 / (1 / 1.0 + 0.6)          // C2 / (1/R12 + g0) ≈ 688 s
        #expect(abs(est.slowTau - expectedTau) / expectedTau < 0.05)
    }

    /// Phase 3 exit criterion: recover T_room within 0.2 °C in simulation with realistic
    /// noise and quantisation — across random laptops, rooms and usage, with fans —
    /// combining the slow sensors (a real Mac has 4 battery, 4 SSD and 15 skin sensors).
    @Test(arguments: 1...12)
    func exitCriterionRealisticNoise(seed: Int) throws {
        let (trace, room) = randomScenario(seed: UInt64(seed))
        let estimates = try ["battery", "palm"].map { slow in
            try #require(RCIdentification.estimate(ThermalSimulator.samples(trace, fast: "soc", slow: slow)))
        }
        let combined = try #require(RCIdentification.combine(estimates))
        #expect(abs(combined.room - room) < 0.2, "seed \(seed): combined \(combined.room) vs \(room)")
    }

    /// Single-sensor accuracy, reported honestly: RMS over 12 random scenarios.
    @Test func singleSensorAccuracyAcrossScenarios() throws {
        var errors: [String: [Double]] = [:]
        for seed in 1...12 as ClosedRange<UInt64> {
            let (trace, room) = randomScenario(seed: seed)
            for slow in ["battery", "palm"] {
                let est = try #require(RCIdentification.estimate(ThermalSimulator.samples(trace, fast: "soc", slow: slow)))
                errors[slow, default: []].append(est.room - room)
            }
        }
        for (slow, e) in errors {
            let rms = (e.map { $0 * $0 }.reduce(0, +) / Double(e.count)).squareRoot()
            #expect(rms < 0.15, "\(slow) RMS \(rms)")
            #expect(e.map(abs).max()! < 0.3, "\(slow) worst \(e.map(abs).max()!)")
        }
    }

    @Test func gapsAreSkippedNotIntegratedAcross() {
        let s = [0.0, 5, 10, 15, 4000, 4005, 4010].map { RCIdentification.Sample(t: $0, fast: 30, slow: 25) }
        let w = RCIdentification.windows(s, window: 120, maxStep: 30)
        #expect(w.allSatisfy { $0.dt <= 120 })
        #expect(w.map(\.dt) == [15, 10])
    }

    @Test func notEnoughDataReturnsNil() {
        let s = (0..<5).map { RCIdentification.Sample(t: Double($0) * 5, fast: 30, slow: 25) }
        #expect(RCIdentification.estimate(s) == nil)
    }
}
