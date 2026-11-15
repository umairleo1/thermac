import Foundation

/// **Anchor-calibrated transfer function** (Phase 4).
///
/// Fitting the room as a free intercept each day proved biased on real hardware (+1.7 to
/// +3.8 °C, varying by day). Instead, the room is *fixed* to a reference built from the
/// trustworthy night estimates, and only the machine's own response is fitted — the
/// per-sensor gains and lags of
///
///     s_k(t) − T_ref(t) = g_k1·x_τk1(t) + g_k2·x_τk2(t) [+ g_k3·x_τk3(P_charge)]
///
/// jointly across all awake segments. These are physical constants of the Mac. The
/// live estimate then needs no constant-room assumption at all:
///
///     T̂(t) = median_k [ s_k(t) − Σ g_k·x_k(t) ]
public enum TransferCalibration {
    /// One awake period starting at a cold-start anchor (filters start at 0).
    public struct Segment: Sendable {
        public let input: PowerResponse.Input
        /// Reference room temperature at each tick; `NaN` where the place is unknown
        /// (those ticks still drive the model's lag states but are not fitted).
        public let reference: [Double]

        public init(input: PowerResponse.Input, reference: [Double]) {
            self.input = input
            self.reference = reference
        }
    }

    public struct SensorModel: Sendable {
        public let name: String
        public let tau: [Double]
        public let gain: [Double]
        public let rms: Double
    }

    public struct Model: Sendable {
        public let sensors: [SensorModel]
        public let usesCharge: Bool
    }

    static func lags(_ input: PowerResponse.Input, _ tau: [Double]) -> [[Double]] {
        var out = tau.prefix(2).map { PowerResponse.lowPass(input, input.power, tau: $0, maxStep: 60, initial: 0) }
        if tau.count > 2 {
            out.append(PowerResponse.lowPass(input, input.charge, tau: tau[2], maxStep: 60, initial: 0))
        }
        return out
    }

    /// Fits every sensor present in all segments. The steady-state response must be
    /// physical (slow gain ≥ 0, total > 0); the fast gain may be negative, which is how
    /// a delayed rise looks. Lags are chosen on the `PowerResponse` grids.
    public static func calibrate(_ segments: [Segment]) -> Model? {
        guard !segments.isEmpty else { return nil }
        let names = segments.map { Set($0.input.sensors.keys) }.reduce(Set(segments[0].input.sensors.keys)) { $0.intersection($1) }
        let usesCharge = segments.contains { $0.input.charge.contains { $0 > 5 } }

        // Precompute lag signals per segment per τ.
        var powerLag: [[Double: [Double]]] = Array(repeating: [:], count: segments.count)
        var chargeLag: [[Double: [Double]]] = Array(repeating: [:], count: segments.count)
        for (i, s) in segments.enumerated() {
            for tau in PowerResponse.fastTaus + PowerResponse.slowTaus {
                powerLag[i][tau] = PowerResponse.lowPass(s.input, s.input.power, tau: tau, maxStep: 60, initial: 0)
            }
            if usesCharge {
                for tau in PowerResponse.chargeTaus {
                    chargeLag[i][tau] = PowerResponse.lowPass(s.input, s.input.charge, tau: tau, maxStep: 60, initial: 0)
                }
            }
        }

        var models: [SensorModel] = []
        for name in names.sorted() {
            var best: SensorModel?
            for t1 in PowerResponse.fastTaus {
                for t2 in PowerResponse.slowTaus {
                    for tc in usesCharge ? PowerResponse.chargeTaus : [0] {
                        var rows: [[Double]] = [], y: [Double] = []
                        for (i, seg) in segments.enumerated() {
                            let s = seg.input.sensors[name]!
                            let x1 = powerLag[i][t1]!, x2 = powerLag[i][t2]!
                            let xc = tc > 0 ? chargeLag[i][tc]! : nil
                            for j in s.indices where seg.reference[j].isFinite {
                                guard let v = s[j] else { continue }
                                rows.append([x1[j], x2[j]] + (xc.map { [$0[j]] } ?? []))
                                y.append(v - seg.reference[j])
                            }
                        }
                        // Fast gain may be negative (delayed rise); steady state must be physical.
                        guard rows.count > 50, let fit = LinearAlgebra.leastSquares(rows, y),
                              fit.theta[1] >= 0, fit.theta[0] + fit.theta[1] > 0,
                              fit.theta.count < 3 || fit.theta[2] >= 0 else { continue }
                        if fit.rms < best?.rms ?? .infinity {
                            best = SensorModel(name: name, tau: tc > 0 ? [t1, t2, tc] : [t1, t2],
                                               gain: fit.theta, rms: fit.rms)
                        }
                    }
                }
            }
            if let best { models.append(best) }
        }
        return models.isEmpty ? nil : Model(sensors: models, usesCharge: usesCharge)
    }

    /// Live room estimate at every tick: the median over sensors of what each implies.
    public static func predict(_ model: Model, _ input: PowerResponse.Input) -> [Double?] {
        let implied: [[Double?]] = model.sensors.compactMap { m in
            guard let s = input.sensors[m.name] else { return nil }
            let x = lags(input, m.tau)
            return s.indices.map { j in
                s[j].map { v in v - zip(m.gain, x).reduce(0) { $0 + $1.0 * $1.1[j] } }
            }
        }
        return input.t.indices.map { j in
            let v = implied.compactMap { $0[j] }.sorted()
            return v.isEmpty ? nil : v[v.count / 2]
        }
    }
}
