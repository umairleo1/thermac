import Foundation
import ThermacCore

extension Commands {
    /// The live estimate exactly as the menu bar app shows it.
    static func now(dbPath: String, bench: Bool = false) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<LiveEstimate, Error>?
        Task.detached {
            do {
                let estimator = LiveEstimator(dbPath: dbPath)
                let t0 = Date()
                var e = try await estimator.estimate()
                if bench {
                    let t1 = Date()
                    e = try await estimator.estimate()
                    print("bench  first (calibrate) \(fmt(t1.timeIntervalSince(t0), 2)) s · refresh \(fmt(Date().timeIntervalSince(t1), 2)) s")
                }
                result = .success(e)
            } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch result! {
        case .failure(let error):
            fail("\(error)")
        case .success(let e):
            if let room = e.room {
                print("room   \(fmt(room, 1)) °C ± \(fmt(e.roomSD, 1))   [\(e.source.rawValue)]")
            } else {
                print("room   —   [\(e.source.rawValue)]")
            }
            print("       \(e.message)")
            if let n = e.lastNight { print("night  \(fmt(n.room)) °C (woke \(stamp(n.time)))") }
            if let s = e.lastSample { print("data   last sample \(durationString(e.computedAt - s)) ago") }
            if e.history.count > 1 {
                let h = e.history.filter { $0.t >= e.computedAt - 12 * 3600 }
                let lo = h.map(\.room).min()!, hi = h.map(\.room).max()!
                print("12 h   \(fmt(lo, 1))–\(fmt(hi, 1)) °C over \(h.count) points")
            }
        }
    }
}
