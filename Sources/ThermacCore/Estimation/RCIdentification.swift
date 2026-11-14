import Foundation

/// Grey-box identification of room temperature from a slow sensor `s`, a fast (SoC)
/// sensor `f` and fan speed, with power entering implicitly through `f`.
///
/// For the two-node model of `ThermalSimulator`, any sensor that reads
/// `s = T_room + k·(T_slow − T_room)` obeys exactly
///
///     ds/dt = α·f − (α + c₀ + c₁·g)·s + (c₀ + c₁·g)·T_room,   g = (rpm/1000)^0.8
///
/// so it is valid for partially-coupled sensors (palm rest, k < 1) too. It is fitted in
/// **integral form** over consecutive windows, so quantised, noisy sensors never have to
/// be differentiated:
///
///     s(b) − s(a) = α∫f − (α + c₀)∫s − c₁∫g·s + T_room·(c₀·Δt + c₁∫g)
///
/// Without fans the model is linear: `Δs = α∫f − β∫s + γΔt`, `T_room = γ / (β − α)`.
/// With fans the linear fit seeds a Levenberg–Marquardt solve over `[α, c₀, c₁, T_room]`.
///
/// Known limitation: a constant offset on the fast sensor biases `T_room` by
/// `α·offset / c₀`. The live system corrects this with cold-start anchors (Phase 4).
public enum RCIdentification {
    public struct Sample: Sendable {
        public let t: Double
        public let fast: Double
        public let slow: Double
        public let fanRPM: Double

        public init(t: Double, fast: Double, slow: Double, fanRPM: Double = 0) {
            self.t = t
            self.fast = fast
            self.slow = slow
            self.fanRPM = fanRPM
        }
    }

    public struct Estimate: Sendable {
        public let room: Double
        public let roomSE: Double?
        public let alpha: Double
        public let c0: Double
        public let c1: Double
        /// Equations (windows) used.
        public let windows: Int
        public let rms: Double
        /// Relaxation time 1/(α+c₀) of the slow sensor *with the fast node held fixed*,
        /// at zero fan speed — i.e. C₂/(1/R₁₂ + g₀) for a fully coupled sensor. This is
        /// shorter than the system's slow mode (≈ C₂/g₀).
        public var slowTau: Double { 1 / (alpha + c0) }
    }

    /// Combines per-sensor estimates of the same room by inverse-variance weighting.
    ///
    /// The reported per-sensor SEs are conservative (overlapping window endpoints make
    /// residuals negatively correlated), but proportionally so, which keeps them valid as
    /// relative weights. Sensors share the fast-sensor noise, so the combined SE (which
    /// assumes independence) is a lower bound.
    public static func combine(_ estimates: [Estimate]) -> (room: Double, se: Double)? {
        let usable = estimates.compactMap { e -> (Double, Double)? in
            guard let se = e.roomSE, se > 0, se.isFinite, e.room.isFinite else { return nil }
            return (e.room, 1 / (se * se))
        }
        let total = usable.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        let room = usable.reduce(0) { $0 + $1.0 * $1.1 } / total
        return (room, (1 / total).squareRoot())
    }

    static func fanTerm(_ rpm: Double) -> Double { pow(max(rpm, 0) / 1000, 0.8) }

    struct Window {
        let ds, intF, intS, intGS, intG, dt: Double
    }

    /// Splits samples into windows of about `window` seconds, skipping across gaps
    /// (e.g. sleep) longer than `maxStep`, and integrates with the trapezoid rule.
    static func windows(_ samples: [Sample], window: Double, maxStep: Double) -> [Window] {
        var out: [Window] = []
        var start = 0
        while start < samples.count - 1 {
            var i = start
            var intF = 0.0, intS = 0.0, intGS = 0.0, intG = 0.0
            while i + 1 < samples.count, samples[i + 1].t - samples[start].t <= window {
                let a = samples[i], b = samples[i + 1]
                let h = b.t - a.t
                if h <= 0 || h > maxStep { break }
                let ga = fanTerm(a.fanRPM), gb = fanTerm(b.fanRPM)
                intF += h * (a.fast + b.fast) / 2
                intS += h * (a.slow + b.slow) / 2
                intGS += h * (ga * a.slow + gb * b.slow) / 2
                intG += h * (ga + gb) / 2
                i += 1
            }
            if i > start {
                out.append(Window(ds: samples[i].slow - samples[start].slow, intF: intF, intS: intS,
                                  intGS: intGS, intG: intG, dt: samples[i].t - samples[start].t))
                start = i
            } else {
                start += 1 // gap: restart after it
            }
        }
        return out
    }

    public static func estimate(_ samples: [Sample], window: Double = 120,
                                maxStep: Double = 30) -> Estimate? {
        let sorted = samples.sorted { $0.t < $1.t }
        let w = windows(sorted, window: window, maxStep: maxStep)
        guard w.count >= 8 else { return nil }

        // 1. Linear fit without fan terms: Δs = α∫f − β∫s + γΔt.
        guard let lin = LinearAlgebra.leastSquares(w.map { [$0.intF, -$0.intS, $0.dt] }, w.map(\.ds))
        else { return nil }
        let (alpha0, beta0, gamma0) = (lin.theta[0], lin.theta[1], lin.theta[2])
        let c00 = beta0 - alpha0
        guard c00 > 0 else { return nil }
        let room0 = gamma0 / c00

        let fansUsed = w.contains { $0.intG > 1e-6 }
        if !fansUsed {
            // Delta-method SE of γ/(β−α) from the linear covariance.
            let c = lin.covariance
            let dA = gamma0 / (c00 * c00), dB = -gamma0 / (c00 * c00), dG = 1 / c00
            let grad = [dA, dB, dG]
            var variance = 0.0
            for i in 0..<3 { for j in 0..<3 { variance += grad[i] * c[i][j] * grad[j] } }
            return Estimate(room: room0, roomSE: variance >= 0 ? variance.squareRoot() : nil,
                            alpha: alpha0, c0: c00, c1: 0, windows: w.count, rms: lin.rms)
        }

        // 2. With fans: nonlinear in [α, c₀, c₁, T_room].
        guard let fit = LevenbergMarquardt.fit(initial: [alpha0, c00, 0, room0], residuals: { p in
            let (a, c0, c1, room) = (p[0], p[1], p[2], p[3])
            return w.map { x in
                a * x.intF - (a + c0) * x.intS - c1 * x.intGS + room * (c0 * x.dt + c1 * x.intG) - x.ds
            }
        }) else { return nil }
        let p = fit.parameters
        return Estimate(room: p[3], roomSE: fit.standardError(3), alpha: p[0], c0: p[1], c1: p[2],
                        windows: w.count, rms: fit.rms)
    }
}
