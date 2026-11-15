import Foundation

/// Kalman filter for the room temperature (Phase 5).
///
/// State `[T, b_fast, b_slow]`:
/// - `T` — room temperature, a slow random walk.
/// - `b_fast`, `b_slow` — the transfer-function model's error, shared by all sensors,
///   as two AR(1) processes back to 0. The fast part (wake-up transients, charging, load
///   steps) is averaged away; anything slower is indistinguishable from a room change
///   within a day and shows up in the reported `±`.
///
/// Observations:
/// - the model's room estimate `y = T + b_fast + b_slow + e` (median over sensors);
/// - a cold-start / night estimate `y = T + e`, at each anchor.
///
/// **Relocation:** laptops are carried with the lid closed. After the Mac has been away
/// (asleep) for `relocationGap` or longer during the day, the room may be a different
/// one, so the filter widens the room's uncertainty and stops blaming the model; the
/// estimate then re-converges at the new place within about the Mac's own response time.
///
/// The model is linear, so this is a plain Kalman filter (the plan said EKF because the
/// physical RC model was nonlinear in its parameters).
public struct RoomFilter: Sendable {
    public struct Tuning: Sendable {
        /// Room random walk, °C per √hour. Kept at 0.5: faster settings only added noise
        /// at home (tracking RMS 0.52 → 1.12 °C at 1.5); moves are handled by `relocation*`
        /// and `changeThreshold` instead.
        public var roomWalk = 0.5
        /// Model error, measured on held-out real days at known places (2026-11-15):
        /// SD 1.8 °C, autocorrelation 0.51 / 0.24 / 0.11 / −0.01 at 30 min / 1 h / 2 h / 4 h —
        /// one fast component (τ ≈ 45 min) plus a small slow remainder. (An earlier, larger
        /// "slow error" of 0.85 °C turned out to be an office afternoon mislabelled as home.)
        public var fastTau = 2700.0
        public var fastSD = 1.75
        public var slowTau = 6 * 3600.0
        public var slowSD = 0.35
        /// Independent noise of one model observation (°C).
        public var observationSD = 0.3
        /// Change detection: if the model's readings stay this far (°C) from the estimate,
        /// averaged over `changeWindow` seconds, the room is taken to have really changed
        /// and the filter catches up quickly. `nil` disables it.
        public var changeThreshold: Double? = 5.0
        public var changeWindow = 1200.0
        /// An absence (asleep, lid closed) at least this long (s) may mean a new place.
        public var relocationGap = 1800.0
        /// After such an absence the room is at least this uncertain (°C, 1 σ). A trade-off,
        /// measured in simulation (move 18 → 22 °C vs. a break in the same room, shown 1 h
        /// after waking): off 19.5 °C / 0.57 °C RMS · 1.5 → 20.4 °C / 0.89 °C ·
        /// 2 → 20.7 °C / 1.03 °C · 3 → 21.0 °C / 1.19 °C. 1.5 keeps breaks at home inside
        /// the ± 1 °C the app shows; the model's own ~45-min error limits anything faster.
        public var relocationSD = 1.5

        public init() {}

        /// Opt-in faster tracking: a larger room random walk follows changes sooner at
        /// the cost of more jitter.
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

    // MARK: Kalman steps

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

    /// Clears the model-error states: from here on, differences are attributed to the room.
    private mutating func resetModelError() {
        x[1] = 0
        x[2] = 0
        p[0][1] = 0; p[1][0] = 0; p[0][2] = 0; p[2][0] = 0; p[1][2] = 0; p[2][1] = 0
        p[1][1] = tuning.fastSD * tuning.fastSD
        p[2][2] = tuning.slowSD * tuning.slowSD
    }

    /// The transfer model's room estimate at this tick. `trust` (0–1] scales how much it
    /// counts: the observation variance is divided by it.
    public mutating func observeModel(_ y: Double, trust: Double = 1) {
        guard trust > 0 else { return }
        // Only full-trust observations can signal a room change: charging and the first
        // hour after wake are when the model errs most.
        if let threshold = tuning.changeThreshold, trust >= 1 {
            // How far the model's readings sit from the *room estimate*: the model error the
            // filter would have to believe in. Held beyond the threshold for ~`changeWindow`
            // it is no longer a plausible model error.
            let gap = y - x[0]
            let a = sinceLastObservation > 600 ? 0 : exp(-sinceLastObservation / tuning.changeWindow)
            innovationMean = a * innovationMean + (1 - a) * gap
            changeDetected = abs(innovationMean) > threshold
            if changeDetected {
                resetModelError()
                let g2 = innovationMean * innovationMean
                if p[0][0] < g2 { p[0][0] = g2 }
            }
        }
        sinceLastObservation = 0
        update(y, h: [1, 1, 1], r: tuning.observationSD * tuning.observationSD / trust)
    }

    /// A direct room observation, e.g. a night-cooling estimate at a cold-start anchor.
    public mutating func observeRoom(_ y: Double, sd: Double) {
        update(y, h: [1, 0, 0], r: sd * sd)
        innovationMean = 0
        changeDetected = false
    }

    /// The Mac was away (asleep) for `duration` seconds. If that is long enough to have
    /// been carried somewhere else, the room becomes uncertain again.
    public mutating func noteAbsence(_ duration: Double) {
        guard duration >= tuning.relocationGap else { return }
        resetModelError()
        let floor = tuning.relocationSD * tuning.relocationSD
        if p[0][0] < floor { p[0][0] = floor }
        innovationMean = 0
        changeDetected = false
    }

    // MARK: Driving the filter over recorded data

    /// Longest step (s) between ticks that still counts as being awake. While asleep the
    /// recorder only logs isolated readings at maintenance wakes (~15 min apart).
    public static let awakeStep = 60.0

    /// Absences inside a recording: for the first awake tick after each period asleep,
    /// how long the Mac was away (from the last awake tick before it).
    public static func absences(_ t: [Double], awakeStep: Double = RoomFilter.awakeStep) -> [Int: Double] {
        guard t.count > 1 else { return [:] }
        // A tick is "awake" if it has a neighbour within `awakeStep`.
        let awake = t.indices.map { j in
            (j > 0 && t[j] - t[j - 1] <= awakeStep) || (j + 1 < t.count && t[j + 1] - t[j] <= awakeStep)
        }
        var out: [Int: Double] = [:]
        var lastAwake: Int?
        for j in t.indices where awake[j] {
            if let l = lastAwake, j > l + 1 || t[j] - t[l] > awakeStep { out[j] = t[j] - t[l] }
            lastAwake = j
        }
        return out
    }

    /// How much to trust the model at each tick. The largest fast errors on real data came
    /// while charging (charge heat is not linear in charge power) and in the first hour
    /// after waking (sensors rise faster than modelled) — after the segment start and
    /// after any absence of `wakeAfterGap` or more.
    public static func modelTrust(_ input: PowerResponse.Input, chargeHold: Double = 3600,
                                  wakeHold: Double = 3600, wakeAfterGap: Double = 1800) -> [Double] {
        let away = absences(input.t)
        var lastCharge = -Double.infinity
        var lastWake = input.t.first ?? 0
        return input.t.indices.map { j in
            let t = input.t[j]
            if let d = away[j], d >= wakeAfterGap { lastWake = t }
            if input.charge[j] > 5 { lastCharge = t }
            var trust = 1.0
            if t - lastWake < wakeHold { trust *= 0.25 }
            if t - lastCharge <= chargeHold { trust *= 0.1 }
            return trust
        }
    }

    /// Runs the filter over one recording (the single code path used by the live app and
    /// by `thermac replay`): propagates between ticks, handles absences, and folds in the
    /// model's room estimates. `observe` is called after every tick.
    /// - Returns: the time of the last tick processed (or `from` if there were none).
    @discardableResult
    public mutating func run(_ input: PowerResponse.Input, predictions: [Double?], trust: [Double],
                             from start: Double, observe: ((Double, RoomFilter) -> Void)? = nil) -> Double {
        let away = Self.absences(input.t)
        var t = start
        for j in input.t.indices {
            predict(dt: input.t[j] - t)
            t = input.t[j]
            if let d = away[j] { noteAbsence(d) }
            if j < predictions.count, let y = predictions[j] { observeModel(y, trust: j < trust.count ? trust[j] : 1) }
            observe?(t, self)
        }
        return t
    }
}
