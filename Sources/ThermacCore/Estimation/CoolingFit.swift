import Foundation

/// Fits a cool-down curve `T(t) = T∞ + Σ Aᵢ·e^(−t/τᵢ)` and returns its asymptote.
///
/// ⚠︎ On an **awake** Mac the asymptote is NOT the room temperature: idle power keeps
/// heating the machine, so `T∞ = T_room + P_idle·R`. In the reference simulation that
/// bias is ≈ +8 °C. Use `RCIdentification` for the room temperature; this fit is for
/// time constants, sleep-cooling extrapolation and diagnostics.
public enum CoolingFit {
    public enum Model: Sendable { case single, double }

    public struct Result: Sendable {
        public let model: Model
        public let asymptote: Double
        public let asymptoteSE: Double?
        /// Time constants in seconds, fastest first.
        public let tau: [Double]
        public let amplitude: [Double]
        public let rms: Double
    }

    /// Closed-form asymptote of a single exponential from three evenly spaced samples:
    /// `T∞ = (T₁·T₃ − T₂²) / (T₁ + T₃ − 2·T₂)`. Nil when the samples are not decaying
    /// (denominator ≈ 0). Very noise-sensitive — use only to seed a fit.
    public static func threePointAsymptote(_ t1: Double, _ t2: Double, _ t3: Double) -> Double? {
        let d = t1 + t3 - 2 * t2
        guard abs(d) > 1e-9 else { return nil }
        let v = (t1 * t3 - t2 * t2) / d
        return v.isFinite ? v : nil
    }

    /// Fits the curve. Time constants are parameterised as logarithms so they stay positive.
    public static func fit(times: [Double], values: [Double], model: Model = .double) -> Result? {
        guard times.count == values.count, times.count >= 8, let t0 = times.first,
              let last = values.last, let first = values.first else { return nil }
        let t = times.map { $0 - t0 }
        let span = max(t.last ?? 1, 1)

        // Seed T∞ from the 3-point formula on the whole window, falling back to the tail.
        let mid = values[values.count / 2]
        var seed = threePointAsymptote(first, mid, last) ?? last
        if !seed.isFinite || abs(seed - last) > 3 * abs(first - last) + 1 { seed = last }
        let total = first - seed

        let initial: [Double]
        switch model {
        case .single: initial = [seed, total, log(span / 3)]
        case .double: initial = [seed, total * 0.4, log(span / 30), total * 0.6, log(span / 3)]
        }

        guard let r = LevenbergMarquardt.fit(initial: initial, residuals: { p in
            zip(t, values).map { ti, yi in evaluate(p, at: ti, model: model) - yi }
        }) else { return nil }

        let p = r.parameters
        var terms: [(tau: Double, amp: Double)] = model == .single
            ? [(exp(p[2]), p[1])]
            : [(exp(p[2]), p[1]), (exp(p[4]), p[3])]
        terms.sort { $0.tau < $1.tau }
        return Result(model: model, asymptote: p[0], asymptoteSE: r.standardError(0),
                      tau: terms.map(\.tau), amplitude: terms.map(\.amp), rms: r.rms)
    }

    static func evaluate(_ p: [Double], at t: Double, model: Model) -> Double {
        switch model {
        case .single: p[0] + p[1] * exp(-t / exp(p[2]))
        case .double: p[0] + p[1] * exp(-t / exp(p[2])) + p[3] * exp(-t / exp(p[4]))
        }
    }

    /// Room temperature from cooling **during sleep** (≈ zero power, so the asymptote is
    /// the room): given the slow-sensor reading at sleep and at wake and the sensor's time
    /// constant τ, `T_room = (T_wake − T_sleep·e^(−Δt/τ)) / (1 − e^(−Δt/τ))`.
    public static func sleepExtrapolation(beforeSleep: Double, afterWake: Double,
                                          slept: Double, tau: Double) -> Double? {
        guard slept > 0, tau > 0 else { return nil }
        let decay = exp(-slept / tau)
        guard decay < 0.999 else { return nil } // too short to tell anything
        return (afterWake - beforeSleep * decay) / (1 - decay)
    }
}

extension CoolingFit {
    public struct NightEstimate: Sendable {
        /// Median asymptote over sensors — the room temperature during the night.
        public let room: Double
        /// Median absolute deviation of the per-sensor asymptotes.
        public let spread: Double
        /// Median slow time constant (s).
        public let tau: Double
        public let sensors: Int
    }

    /// Room temperature from a sleep session: while asleep, power ≈ 0, so (unlike on an
    /// awake Mac) every slow sensor relaxes straight to the room temperature. The sparse
    /// readings taken during DarkWake maintenance wakes trace the curve; the first
    /// `skip` seconds (fast modes) are dropped and a single exponential is fitted.
    ///
    /// Assumes the room itself stays roughly constant overnight; a room that cools at
    /// night (heating set-back) pulls the asymptote down and lengthens τ.
    public static func night(_ series: [String: [(t: Double, value: Double)]], from start: Double,
                             skip: Double = 3600) -> NightEstimate? {
        var rooms: [Double] = [], taus: [Double] = []
        for (_, s) in series {
            let pts = s.filter { $0.t >= start + skip }
            guard pts.count >= 8, let t0 = pts.first?.t,
                  let fit = fit(times: pts.map { $0.t - t0 }, values: pts.map(\.value), model: .single),
                  let tau = fit.tau.first, tau > 600, tau < 86400,
                  fit.asymptote > 0, fit.asymptote < 40 else { continue }
            rooms.append(fit.asymptote)
            taus.append(tau)
        }
        guard !rooms.isEmpty else { return nil }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        let m = median(rooms)
        return NightEstimate(room: m, spread: median(rooms.map { abs($0 - m) }), tau: median(taus),
                             sensors: rooms.count)
    }
}
