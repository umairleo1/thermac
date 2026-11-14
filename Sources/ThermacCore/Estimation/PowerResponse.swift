import Foundation

/// Room temperature from **measured power** and several slow sensors (the
/// "steady-state heat model", made dynamic).
///
/// For a linear thermal network every sensor obeys `s(t) = T_room + (h ∗ P)(t)`: the
/// room plus a lagged response to total power. The impulse response `h` is approximated
/// by two first-order lags, so with `x_τ = low-pass(P, τ)`
///
///     s_k(t) = T_room + g_k1·x_τk1(t) + g_k2·x_τk2(t)
///
/// Battery charging adds a third term `g_k3·x_τk3(P_charge)`: charge power (DC-in minus
/// system power) heats the battery but is not part of system power.
///
/// All sensors share one `T_room`; gains and time constants are per sensor. Lags are
/// chosen per sensor on a grid, then a single weighted least-squares solve gives the
/// shared room temperature.
///
/// The lag states need a known starting point. After a long sleep (a cold-start anchor)
/// power has been ≈ 0 for hours, so `x = 0` is exact; otherwise the first `burnIn`
/// seconds are used only to warm the filters up. Gaps longer than `maxStep` count as
/// sleep (P = 0), so the filters decay through them instead of breaking.
///
/// Why not RC identification on real data: it uses the SoC temperature as the heat
/// input, and that breaks down when heat comes from elsewhere — the display, and
/// above all **battery charging**, which heats the battery without showing up on the
/// SoC. Measured power sees every watt delivered to the system.
public enum PowerResponse {
    public struct Input: Sendable {
        public let t: [Double]
        /// Total system power (W), e.g. SMC `PSTR`.
        public let power: [Double]
        /// Power going into the battery (W), e.g. `max(0, PDTR − PSTR)`; zeros if unknown.
        public let charge: [Double]
        /// Sensor name → readings aligned with `t` (nil = missing / excluded).
        public let sensors: [String: [Double?]]

        public init(t: [Double], power: [Double], charge: [Double]? = nil, sensors: [String: [Double?]]) {
            self.t = t
            self.power = power
            self.charge = charge ?? [Double](repeating: 0, count: t.count)
            self.sensors = sensors
        }
    }

    public struct SensorFit: Sendable {
        public let name: String
        public let tau: [Double]
        public let gain: [Double]
        /// Room temperature this sensor alone implies.
        public let room: Double
        public let rms: Double
        public let samples: Int
        /// Steady-state rise per watt (°C/W) — sum of the gains.
        public var rPerWatt: Double { gain.reduce(0, +) }
    }

    public struct Estimate: Sendable {
        /// Room temperature (at the window start when `drift` is fitted).
        public let room: Double
        /// Fitted room drift (°C per hour); 0 unless requested.
        public let drift: Double
        /// Standard error from the joint fit (optimistic: residuals are autocorrelated).
        public let roomSE: Double
        /// Spread (SD) of the per-sensor room estimates — the honest uncertainty.
        public let sensorSpread: Double
        public let sensors: [SensorFit]
    }

    public static let fastTaus: [Double] = [60, 120, 240, 480, 900]
    public static let slowTaus: [Double] = [1200, 1800, 2700, 3600, 5400, 7200, 10800, 14400, 21600]
    public static let chargeTaus: [Double] = [600, 1200, 2400, 4800]

    /// Exact first-order low-pass of piecewise-linear power, decaying through gaps.
    static func lowPass(_ input: Input, _ signal: [Double], tau: Double, maxStep: Double,
                        initial: Double) -> [Double] {
        var out = [Double](repeating: 0, count: input.t.count)
        guard !out.isEmpty else { return out }
        var x = initial
        out[0] = x
        for j in 1..<input.t.count {
            let h = input.t[j] - input.t[j - 1]
            let a = exp(-h / tau)
            let p = h <= maxStep ? (signal[j - 1] + signal[j]) / 2 : 0
            x = a * x + (1 - a) * p
            out[j] = x
        }
        return out
    }

    /// Ordinary least squares for one sensor with given lags; nil if the steady-state
    /// response is non-physical or the system is singular.
    /// `hours` (if given) adds a linear room-drift column.
    static func fitSensor(_ s: [Double?], lags: [[Double]], use: [Bool],
                          hours: [Double]? = nil) -> (theta: [Double], rms: Double, n: Int)? {
        var rows: [[Double]] = [], y: [Double] = []
        for j in s.indices where use[j] {
            guard let v = s[j] else { continue }
            rows.append([1] + (hours.map { [$0[j]] } ?? []) + lags.map { $0[j] })
            y.append(v)
        }
        guard rows.count > 20, let fit = LinearAlgebra.leastSquares(rows, y) else { return nil }
        // A sensor heated *through* another node has a delayed rise, A·(e^(−t/τ₂) − e^(−t/τ₁)):
        // its fast gain is negative. Only the steady state must be physical: the slow
        // power gain (and charge gain) ≥ 0 and the total rise per watt > 0.
        let g = Array(fit.theta.suffix(lags.count))
        guard g[1] >= 0, g[0] + g[1] > 0, g.count < 3 || g[2] >= 0 else { return nil }
        return (fit.theta, fit.rms, rows.count)
    }

    /// - Parameters:
    ///   - coldStart: the window begins right after a long sleep (filters start at 0).
    ///   - burnIn: otherwise, seconds excluded from the fit while the filters settle.
    ///   - drift: let the room temperature change linearly over the window.
    public static func estimate(_ input: Input, coldStart: Bool, drift: Bool = false,
                                burnIn: Double = 7200, maxStep: Double = 60) -> Estimate? {
        guard input.t.count > 50 else { return nil }
        let initial = coldStart ? 0 : input.power.prefix(60).reduce(0, +) / Double(min(60, input.power.count))
        let use = input.t.map { coldStart || $0 - input.t[0] >= burnIn }
        let hours = drift ? input.t.map { ($0 - input.t[0]) / 3600 } : nil
        let d = drift ? 1 : 0

        var cache: [Double: [Double]] = [:], chargeCache: [Double: [Double]] = [:]
        func lag(_ tau: Double) -> [Double] {
            if let c = cache[tau] { return c }
            let x = lowPass(input, input.power, tau: tau, maxStep: maxStep, initial: initial)
            cache[tau] = x
            return x
        }
        func chargeLag(_ tau: Double) -> [Double] {
            if let c = chargeCache[tau] { return c }
            let x = lowPass(input, input.charge, tau: tau, maxStep: maxStep, initial: 0)
            chargeCache[tau] = x
            return x
        }
        let charged = zip(input.charge, use).contains { $0 > 5 && $1 }
        func lags(_ tau: [Double]) -> [[Double]] {
            [lag(tau[0]), lag(tau[1])] + (tau.count > 2 ? [chargeLag(tau[2])] : [])
        }

        // 1. Per sensor: best lag pair on the grid.
        var fits: [SensorFit] = []
        for (name, s) in input.sensors.sorted(by: { $0.key < $1.key }) {
            var best: SensorFit?
            for t1 in fastTaus {
                for t2 in slowTaus {
                    for tc in charged ? chargeTaus : [0] {
                        let tau = tc > 0 ? [t1, t2, tc] : [t1, t2]
                        guard let f = fitSensor(s, lags: lags(tau), use: use, hours: hours) else { continue }
                        if f.rms < best?.rms ?? .infinity {
                            best = SensorFit(name: name, tau: tau, gain: Array(f.theta.dropFirst(1 + d)),
                                             room: f.theta[0], rms: f.rms, samples: f.n)
                        }
                    }
                }
            }
            if let best { fits.append(best) }
        }
        guard !fits.isEmpty else { return nil }

        // 2. Joint weighted fit: shared intercept, per-sensor gains.
        var offset = [Int](), p = 1 + d
        for f in fits { offset.append(p); p += f.tau.count }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var atb = [Double](repeating: 0, count: p)
        for (i, f) in fits.enumerated() {
            let w = 1 / max(f.rms * f.rms, 1e-4)
            let x = lags(f.tau), s = input.sensors[f.name]!
            for j in s.indices where use[j] {
                guard let v = s[j] else { continue }
                let cols = [(0, 1.0)] + (hours.map { [(1, $0[j])] } ?? []) + x.indices.map { (offset[i] + $0, x[$0][j]) }
                for (a, va) in cols {
                    atb[a] += w * va * v
                    for (b, vb) in cols { ata[a][b] += w * va * vb }
                }
            }
        }
        let k = fits.count
        guard let inv = LinearAlgebra.invert(ata) else { return nil }
        let theta = inv.map { row in zip(row, atb).reduce(0) { $0 + $1.0 * $1.1 } }
        // Weighted residuals have unit variance by construction → SE = sqrt(inv[0][0]).
        let room = theta[0]
        let rooms = fits.map(\.room)
        let mean = rooms.reduce(0, +) / Double(k)
        let spread = k > 1 ? (rooms.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(k - 1)).squareRoot() : 0
        return Estimate(room: room, drift: drift ? theta[1] : 0, roomSE: inv[0][0].squareRoot(), sensorSpread: spread, sensors: fits)
    }

    // MARK: Nonlinear heat transfer

    /// Same estimate with **temperature-dependent conductance**: convection and radiation
    /// shed more heat per degree as the Mac warms (G = G₀·(1 + 2κ·ΔT)), so the rise is
    /// concave in power. With ΔT = s − T_room the model becomes
    ///
    ///     ΔT + κ·ΔT² = g₁·x₁ + g₂·x₂ [+ g₃·x₃]
    ///
    /// A linear model (κ = 0) fitted at 4–18 W then extrapolates too high to P = 0 and
    /// overestimates the room. Solved by fixed-point iteration on T_room.
    public static func estimate(_ input: Input, coldStart: Bool, kappa: Double,
                                burnIn: Double = 7200, maxStep: Double = 60) -> Estimate? {
        guard kappa > 0 else { return estimate(input, coldStart: coldStart, burnIn: burnIn, maxStep: maxStep) }
        guard var room = estimate(input, coldStart: coldStart, burnIn: burnIn, maxStep: maxStep)?.room else { return nil }
        // Intercept c in z-space ↔ a shift Δ in temperature: Δ + κΔ² = c.
        func shift(_ c: Double) -> Double { (-1 + (1 + 4 * kappa * c).squareRoot()) / (2 * kappa) }
        var last: Estimate?
        for _ in 0..<12 {
            let t = room
            let z = input.sensors.mapValues { s in s.map { $0.map { v in (v - t) + kappa * (v - t) * (v - t) } } }
            guard let e = estimate(Input(t: input.t, power: input.power, charge: input.charge, sensors: z),
                                   coldStart: coldStart, burnIn: burnIn, maxStep: maxStep),
                  (1 + 4 * kappa * e.room) >= 0 else { return nil }
            room = t + shift(e.room)
            let sensors = e.sensors.map {
                SensorFit(name: $0.name, tau: $0.tau, gain: $0.gain, room: t + shift($0.room),
                          rms: $0.rms, samples: $0.samples)
            }
            let rooms = sensors.map(\.room), mean = rooms.reduce(0, +) / Double(rooms.count)
            let spread = rooms.count > 1
                ? (rooms.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rooms.count - 1)).squareRoot() : 0
            last = Estimate(room: room, drift: 0, roomSE: e.roomSE, sensorSpread: spread, sensors: sensors)
            if abs(e.room) < 1e-4 { break }
        }
        return last
    }
}
