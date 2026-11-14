/// Small dense linear algebra for the estimators (problems have ≤ ~8 parameters).
enum LinearAlgebra {
    /// Solves A·x = b by Gaussian elimination with partial pivoting. Nil if singular.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a
        var x = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }),
                  abs(m[pivot][col]) > 1e-300 else { return nil }
            m.swapAt(col, pivot)
            x.swapAt(col, pivot)
            for row in (col + 1)..<n where m[row][col] != 0 {
                let f = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= f * m[col][k] }
                x[row] -= f * x[col]
            }
        }
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = x[row]
            for k in (row + 1)..<n { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Inverse via column-by-column solves. Nil if singular.
    static func invert(_ a: [[Double]]) -> [[Double]]? {
        let n = a.count
        var columns: [[Double]] = []
        for j in 0..<n {
            var e = [Double](repeating: 0, count: n)
            e[j] = 1
            guard let col = solve(a, e) else { return nil }
            columns.append(col)
        }
        return (0..<n).map { i in (0..<n).map { j in columns[j][i] } }
    }

    /// JᵀJ and Jᵀr for a Jacobian stored row-per-residual.
    static func normalEquations(_ jacobian: [[Double]], _ r: [Double]) -> (jtj: [[Double]], jtr: [Double]) {
        let p = jacobian.first?.count ?? 0
        var jtj = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var jtr = [Double](repeating: 0, count: p)
        for (row, ri) in zip(jacobian, r) {
            for i in 0..<p {
                jtr[i] += row[i] * ri
                for j in i..<p { jtj[i][j] += row[i] * row[j] }
            }
        }
        for i in 0..<p { for j in 0..<i { jtj[i][j] = jtj[j][i] } }
        return (jtj, jtr)
    }

    /// Ordinary least squares: minimises |X·θ − y|². Returns θ and its covariance.
    static func leastSquares(_ x: [[Double]], _ y: [Double]) -> (theta: [Double], covariance: [[Double]], rms: Double)? {
        let n = y.count, p = x.first?.count ?? 0
        guard n > p, p > 0 else { return nil }
        let (xtx, xty) = normalEquations(x, y)
        guard let theta = solve(xtx, xty), let inv = invert(xtx) else { return nil }
        let rss = zip(x, y).reduce(0) { acc, pair in
            let fit = zip(pair.0, theta).reduce(0) { $0 + $1.0 * $1.1 }
            return acc + (pair.1 - fit) * (pair.1 - fit)
        }
        let s2 = rss / Double(n - p)
        return (theta, inv.map { $0.map { $0 * s2 } }, (rss / Double(n)).squareRoot())
    }
}
