/// Result of a nonlinear least-squares fit.
public struct LMResult: Sendable {
    public let parameters: [Double]
    /// Parameter covariance `s²·(JᵀJ)⁻¹`, nil if singular. Assumes independent residuals;
    /// with autocorrelated sensor noise the true uncertainty is larger.
    public let covariance: [[Double]]?
    public let rms: Double
    public let iterations: Int
    public let converged: Bool

    public func standardError(_ i: Int) -> Double? {
        guard let c = covariance?[i][i], c >= 0 else { return nil }
        return c.squareRoot()
    }
}

/// Levenberg–Marquardt with a numerical (central-difference) Jacobian.
public enum LevenbergMarquardt {
    public static func fit(initial: [Double],
                           maxIterations: Int = 200,
                           tolerance: Double = 1e-10,
                           residuals: ([Double]) -> [Double]) -> LMResult? {
        var p = initial
        var r = residuals(p)
        guard r.count > p.count, r.allSatisfy(\.isFinite) else { return nil }
        var cost = r.reduce(0) { $0 + $1 * $1 }
        var lambda = 1e-3
        var converged = false
        var iteration = 0

        func jacobian(at p: [Double]) -> [[Double]] {
            var columns: [[Double]] = []
            for i in p.indices {
                let h = 1e-6 * max(1, abs(p[i]))
                var hi = p, lo = p
                hi[i] += h
                lo[i] -= h
                let rh = residuals(hi), rl = residuals(lo)
                columns.append(zip(rh, rl).map { ($0 - $1) / (2 * h) })
            }
            return r.indices.map { k in columns.map { $0[k] } }
        }

        while iteration < maxIterations {
            iteration += 1
            let (jtj, jtr) = LinearAlgebra.normalEquations(jacobian(at: p), r)
            var improved = false
            while lambda < 1e12 {
                var damped = jtj
                for i in p.indices { damped[i][i] += lambda * max(jtj[i][i], 1e-12) }
                guard let step = LinearAlgebra.solve(damped, jtr.map { -$0 }) else { lambda *= 10; continue }
                let candidate = zip(p, step).map(+)
                let rc = residuals(candidate)
                let cc = rc.reduce(0) { $0 + $1 * $1 }
                if cc.isFinite && cc < cost {
                    let relative = (cost - cc) / max(cost, 1e-300)
                    p = candidate
                    r = rc
                    cost = cc
                    lambda = max(lambda / 10, 1e-12)
                    improved = true
                    if relative < tolerance { converged = true }
                    break
                }
                lambda *= 10
            }
            if !improved { converged = true; break } // no downhill step left: at a minimum
            if converged { break }
        }

        let n = r.count, k = p.count
        let (jtj, _) = LinearAlgebra.normalEquations(jacobian(at: p), r)
        let s2 = cost / Double(n - k)
        let covariance = LinearAlgebra.invert(jtj).map { $0.map { $0.map { $0 * s2 } } }
        return LMResult(parameters: p, covariance: covariance,
                        rms: (cost / Double(n)).squareRoot(),
                        iterations: iteration, converged: converged)
    }
}
