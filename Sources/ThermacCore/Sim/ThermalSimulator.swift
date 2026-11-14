import Foundation

/// Deterministic pseudo-random numbers (SplitMix64) so simulations are reproducible.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * uniform()
    }

    /// Standard normal (Box–Muller).
    public mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Two-node lumped thermal model of a laptop.
///
///     C1·dT1/dt = P − (T1 − T2)/R12                      SoC + heatsink (fast)
///     C2·dT2/dt = (T1 − T2)/R12 − G(rpm)·(T2 − T_room)   chassis + battery (slow)
///     G(rpm)    = g0 + gFan·(rpm/1000)^0.8
public struct ThermalParameters: Sendable {
    public var c1: Double      // J/K
    public var c2: Double      // J/K
    public var r12: Double     // K/W
    public var g0: Double      // W/K, natural convection + conduction
    public var gFan: Double    // W/K per (krpm)^0.8

    /// Calibrated to look like the Phase 1 M4 Pro readings: ~5 W idle gives a SoC
    /// ≈ 14 °C and a battery ≈ 8 °C above a ~21 °C room; τ_fast ≈ 40 s, τ_slow ≈ 30 min.
    public static let m4ProLike = ThermalParameters(c1: 40, c2: 1100, r12: 1.0, g0: 0.6, gFan: 0.9)

    public init(c1: Double, c2: Double, r12: Double, g0: Double, gFan: Double) {
        self.c1 = c1
        self.c2 = c2
        self.r12 = r12
        self.g0 = g0
        self.gFan = gFan
    }

    public func conductance(rpm: Double) -> Double { g0 + gFan * RCIdentification.fanTerm(rpm) }

    /// Steady-state node temperatures at constant power and fan speed.
    public func steadyState(power: Double, room: Double, rpm: Double = 0) -> (t1: Double, t2: Double) {
        let t2 = room + power / conductance(rpm: rpm)
        return (t2 + power * r12, t2)
    }
}

/// A simulated sensor: `reading = T_room + k·(T_node − T_room) + offset + noise`, quantised.
/// `node` 1 = fast SoC node, 2 = slow chassis node.
public struct SimulatedSensor: Sendable {
    public var name: String
    public var node: Int
    public var coupling: Double = 1
    public var offset: Double = 0
    public var noise: Double = 0
    public var quantum: Double = 0

    public init(name: String, node: Int, coupling: Double = 1, offset: Double = 0,
                noise: Double = 0, quantum: Double = 0) {
        self.name = name
        self.node = node
        self.coupling = coupling
        self.offset = offset
        self.noise = noise
        self.quantum = quantum
    }

    /// Noise levels observed on the M4 Pro in Phase 1 (gas-gauge battery steps 0.1 °C,
    /// PMU tdie steps ≈ 0.08 °C, SMC floats fine-grained).
    public static let realistic: [SimulatedSensor] = [
        SimulatedSensor(name: "soc", node: 1, noise: 0.25, quantum: 0.08),
        SimulatedSensor(name: "battery", node: 2, noise: 0.03, quantum: 0.1),
        SimulatedSensor(name: "palm", node: 2, coupling: 0.6, noise: 0.03, quantum: 0.01),
    ]
}

/// A piecewise-constant power schedule.
public struct PowerProfile: Sendable {
    public var segments: [(start: Double, watts: Double)]

    public init(segments: [(start: Double, watts: Double)]) {
        self.segments = segments.sorted { $0.start < $1.start }
    }

    public func power(at t: Double) -> Double {
        segments.last { $0.start <= t }?.watts ?? segments.first?.watts ?? 0
    }

    /// Idle with randomly placed load bursts — like normal use: compiling, a video call…
    public static func idleWithBursts(duration: Double, idle: Double = 5, burst: ClosedRange<Double> = 15...40,
                                      every: Double = 1800, length: ClosedRange<Double> = 120...600,
                                      rng: inout SeededRandom) -> PowerProfile {
        var segments: [(Double, Double)] = [(0, idle)]
        var t = rng.uniform(0...every)
        while t < duration {
            let len = rng.uniform(length)
            segments.append((t, rng.uniform(burst)))
            segments.append((t + len, idle + rng.uniform(-1...1)))
            t += len + rng.uniform(0.5 * every...1.5 * every)
        }
        return PowerProfile(segments: segments)
    }
}

/// Simple fan curve resembling the M4 Pro: off until the SoC is hot, then ramps.
public struct FanCurve: Sendable {
    public var onAbove: Double = 70     // °C on node 1
    public var maxAt: Double = 95
    public var minRPM: Double = 1200
    public var maxRPM: Double = 5000

    public init() {}

    public func rpm(soc: Double) -> Double {
        guard soc > onAbove else { return 0 }
        let x = min(1, (soc - onAbove) / (maxAt - onAbove))
        return minRPM + x * (maxRPM - minRPM)
    }
}

public struct SimulationTrace: Sendable {
    public var t: [Double] = []
    public var room: [Double] = []
    public var power: [Double] = []
    public var fanRPM: [Double] = []
    public var t1: [Double] = []
    public var t2: [Double] = []
    /// Sensor name → readings aligned with `t`.
    public var sensors: [String: [Double]] = [:]
}

public enum ThermalSimulator {
    /// Integrates the model with RK4 (`step` seconds) and samples sensors every `sampleInterval`.
    /// Starts at the steady state of the initial power so there is no artificial warm-up.
    public static func run(parameters p: ThermalParameters,
                           duration: Double,
                           power: PowerProfile,
                           room: @Sendable (Double) -> Double,
                           sensors: [SimulatedSensor] = SimulatedSensor.realistic,
                           fan: FanCurve? = FanCurve(),
                           sampleInterval: Double = 5,
                           step: Double = 0.5,
                           seed: UInt64 = 1) -> SimulationTrace {
        var rng = SeededRandom(seed: seed)
        var (t1, t2) = p.steadyState(power: power.power(at: 0), room: room(0))
        var trace = SimulationTrace()
        for s in sensors { trace.sensors[s.name] = [] }

        func derivatives(_ x1: Double, _ x2: Double, _ t: Double, _ rpm: Double) -> (Double, Double) {
            let q12 = (x1 - x2) / p.r12
            return ((power.power(at: t) - q12) / p.c1,
                    (q12 - p.conductance(rpm: rpm) * (x2 - room(t))) / p.c2)
        }

        var t = 0.0
        var nextSample = 0.0
        while t <= duration {
            let rpm = fan?.rpm(soc: t1) ?? 0
            if t >= nextSample - 1e-9 {
                trace.t.append(t)
                trace.room.append(room(t))
                trace.power.append(power.power(at: t))
                trace.fanRPM.append(rpm)
                trace.t1.append(t1)
                trace.t2.append(t2)
                for s in sensors {
                    let node = s.node == 1 ? t1 : t2
                    var v = room(t) + s.coupling * (node - room(t)) + s.offset + s.noise * rng.gaussian()
                    if s.quantum > 0 { v = (v / s.quantum).rounded() * s.quantum }
                    trace.sensors[s.name]!.append(v)
                }
                nextSample += sampleInterval
            }
            // RK4, fan speed held over the step.
            let (k1a, k1b) = derivatives(t1, t2, t, rpm)
            let (k2a, k2b) = derivatives(t1 + step / 2 * k1a, t2 + step / 2 * k1b, t + step / 2, rpm)
            let (k3a, k3b) = derivatives(t1 + step / 2 * k2a, t2 + step / 2 * k2b, t + step / 2, rpm)
            let (k4a, k4b) = derivatives(t1 + step * k3a, t2 + step * k3b, t + step, rpm)
            t1 += step / 6 * (k1a + 2 * k2a + 2 * k3a + k4a)
            t2 += step / 6 * (k1b + 2 * k2b + 2 * k3b + k4b)
            t += step
        }
        return trace
    }

    /// Converts a trace to identification samples using the named fast and slow sensors.
    public static func samples(_ trace: SimulationTrace, fast: String, slow: String) -> [RCIdentification.Sample] {
        let f = trace.sensors[fast]!, s = trace.sensors[slow]!
        return trace.t.indices.map {
            RCIdentification.Sample(t: trace.t[$0], fast: f[$0], slow: s[$0], fanRPM: trace.fanRPM[$0])
        }
    }
}
