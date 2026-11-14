import Foundation

/// Kalman filter for the room temperature (Phase 5).
///
/// State `[T, b_fast, b_slow]`:
/// - `T` — room temperature, a slow random walk.
/// - `b_fast`, `b_slow` — the transfer-function model's error, shared by all sensors,
///   as two AR(1) processes back to 0. Measured on held-out real days (2026-11-14):
///   SD 1.9 °C with autocorrelation 0.40 at 30 min, 0.10 at 1 h, ≈ 0.2 at 2–4 h —
///   i.e. a large error that fades in ~30 min (wake-up transients, charging, load
///   steps) plus ≈ 0.85 °C that persists for hours (placement, day-level offsets).
///   The fast part is averaged away; the slow part is indistinguishable from a room
///   change within a day, so it shows up honestly in the reported `±`.
///
/// Observations:
/// - the model's room estimate `y = T + b_fast + b_slow + e` (median over sensors);
/// - a cold-start / night estimate `y = T + e`, at each anchor.
///
/// The model is linear, so this is a plain Kalman filter (the plan said EKF because the
/// physical RC model was nonlinear in its parameters).
public struct RoomFilter: Sendable {
    public struct Tuning: Sendable {
        /// Room random walk, °C per √hour.
        public var roomWalk = 0.5
        /// Fast model error: persistence (s) and stationary SD (°C).
        public var fastTau = 1800.0
        public var fastSD = 1.7
        /// Slow model error: persistence (s) and stationary SD (°C).
        public var slowTau = 6 * 3600.0
        public var slowSD = 0.85
        /// Independent noise of one model observation (°C).
        public var observationSD = 0.3
        /// Change detection: if the model's readings stay this far (°C) from the estimate,
        /// averaged over `changeWindow` seconds, the room is taken to have really changed
        /// (e.g. the Mac was carried to another room) and the filter catches up quickly.
        /// `nil` disables it. 5 °C: on real data (replay 2026-11-14) 4 °C fired falsely
        /// on a bad model afternoon, 5 °C did not; in simulation a move from 17 °C to
        /// 5 °C then shows ≈ 11 °C after 1 h and ≈ 7.5 °C after 2 h (≈ 15 / 14 °C without).
        public var changeThreshold: Double? = 5.0
        public var changeWindow = 1200.0

        public init() {}

        /// Opt-in faster tracking: shows most of a room change within ~50 min instead of
        /// ~3 h, at the cost of ~0.35 °C jitter and larger errors on real data (replay
        /// 2026-11-14: worst next-night error 2.13 °C vs 1.46 °C).
        public static var responsive: Tuning {
            var t = Tuning()
            t.roomWalk = 1.0
            return t
        }
    }

    /// State `[T, b_fast, b_slow]` and its covariance.
    public private(set) var x: [Double]
    public private(set) var p: [[Double]]
    public let tuning: Tuning

    /// Smoothed gap between model observations and the room estimate (°C), for change detection.
    public private(set) var innovationMean = 0.0
    /// True while a detected room change is being followed.
    public private(set) var changeDetected = false
    private var sinceLastObservation = 0.0

    public var room: Double { x[0] }
    public var bias: Double { x[1] + x[2] }
    public var roomSD: Double { p[0][0].squareRoot() }

    public init(room: Double, roomSD: Double, tuning: Tuning = Tuning()) {
        self.tuning = tuning
        x = [room, 0, 0]
        p = [[roomSD * roomSD, 0, 0],
             [0, tuning.fastSD * tuning.fastSD, 0],
             [0, 0, tuning.slowSD * tuning.slowSD]]
    }

    /// Propagates the state over `dt` seconds: x ← F x, P ← F P Fᵀ + Q.
    public mutating func predict(dt: Double) {
        guard dt > 0 else { return }
        sinceLastObservation += dt
        let f = [1, exp(-dt / tuning.fastTau), exp(-dt / tuning.slowTau)]
        let q = [tuning.roomWalk * tuning.roomWalk * dt / 3600,
                 tuning.fastSD * tuning.fastSD * (1 - f[1] * f[1]),
                 tuning.slowSD * tuning.slowSD * (1 - f[2] * f[2])]
        for i in 0..<3 {
            x[i] *= f[i]
            for j in 0..<3 { p[i][j] *= f[i] * f[j] }
            p[i][i] += q[i]
        }
    }

    /// Scalar update with observation `y = h·x + e`, `e ~ N(0, r)`.
    mutating func update(_ y: Double, h: [Double], r: Double) {
        let ph = (0..<3).map { i in (0..<3).reduce(0) { $0 + p[i][$1] * h[$1] } }
        let s = zip(h, ph).reduce(0) { $0 + $1.0 * $1.1 } + r
        guard s > 0 else { return }
        let k = ph.map { $0 / s }
        let innovation = y - zip(h, x).reduce(0) { $0 + $1.0 * $1.1 }
        for i in 0..<3 { x[i] += k[i] * innovation }
        for i in 0..<3 { for j in 0..<3 { p[i][j] -= k[i] * ph[j] } }
        for i in 0..<3 { for j in 0..<i { let m = (p[i][j] + p[j][i]) / 2; p[i][j] = m; p[j][i] = m } }
    }

    /// The transfer model's room estimate at this tick. `trust` (0–1] scales how much it
    /// counts: the observation variance is divided by it.
    public mutating func observeModel(_ y: Double, trust: Double = 1) {
        guard trust > 0 else { return }
        // Only full-trust observations can signal a room change: charging and the first
        // hour after wake are when the model errs most (and when it looked like a change
        // on real data, 2026-11-14).
        if let threshold = tuning.changeThreshold, trust >= 1 {
            // How far the model's readings sit from the *room estimate* — the model error
            // the filter would have to believe in. Normally ≈ 1.9 °C SD; held beyond the
            // threshold for ~`changeWindow` it is not a plausible model error any more.
            let gap = y - x[0]
            // Gaps (sleep, recorder off) reset the running mean.
            let a = sinceLastObservation > 600 ? 0 : exp(-sinceLastObservation / tuning.changeWindow)
            innovationMean = a * innovationMean + (1 - a) * gap
            changeDetected = abs(innovationMean) > threshold
            if changeDetected {
                // The room really changed: stop blaming the model (clear the error
                // states) and make the room at least this uncertain, so the estimate
                // follows the new level. Ends by itself once the estimate has caught up.
                x[1] = 0
                x[2] = 0
                p[0][1] = 0; p[1][0] = 0; p[0][2] = 0; p[2][0] = 0; p[1][2] = 0; p[2][1] = 0
                p[1][1] = tuning.fastSD * tuning.fastSD
                p[2][2] = tuning.slowSD * tuning.slowSD
                let g2 = innovationMean * innovationMean
                if p[0][0] < g2 { p[0][0] = g2 }
            }
        }
        sinceLastObservation = 0
        update(y, h: [1, 1, 1], r: tuning.observationSD * tuning.observationSD / trust)
    }

    /// How much to trust the model at each tick of an awake segment. The largest fast
    /// errors on real data came while charging (charge heat is not linear in charge
    /// power) and in the first hour after wake (sensors rise faster than modelled).
    public static func modelTrust(_ input: PowerResponse.Input, chargeHold: Double = 3600,
                                  wakeHold: Double = 3600) -> [Double] {
        var lastCharge = -Double.infinity
        return input.t.indices.map { j in
            let t = input.t[j]
            if input.charge[j] > 5 { lastCharge = t }
            var trust = 1.0
            if t - input.t[0] < wakeHold { trust *= 0.25 }
            if t - lastCharge <= chargeHold { trust *= 0.1 }
            return trust
        }
    }

    /// A direct room observation, e.g. a night-cooling estimate at a cold-start anchor.
    public mutating func observeRoom(_ y: Double, sd: Double) {
        update(y, h: [1, 0, 0], r: sd * sd)
        innovationMean = 0
        changeDetected = false
    }
}
