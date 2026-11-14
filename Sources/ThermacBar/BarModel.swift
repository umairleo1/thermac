import AppKit
import Combine
import os
import ThermacCore

/// Refreshes the live estimate on a timer. `LiveEstimator` is an actor, so the work runs
/// off the main thread; a refresh between nights costs well under a second.
@MainActor
final class BarModel: ObservableObject {
    @Published private(set) var estimate: LiveEstimate?
    @Published private(set) var problem: String?
    @Published private(set) var refreshing = false
    /// Chart hover position.
    @Published var selection: Date?

    let prefs = Preferences.shared
    let recorder = RecorderManager()
    private let estimator = LiveEstimator()
    private let log = Logger(subsystem: "com.thermac.bar", category: "estimate")
    private var loop: Task<Void, Never>?
    private var bag: Set<AnyCancellable> = []

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        // Re-render when settings change; restart the timer when the interval changes.
        prefs.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        prefs.$refreshMinutes.dropFirst().sink { [weak self] _ in self?.startLoop() }.store(in: &bag)
        prefs.$responsive.dropFirst().sink { [weak self] on in
            guard let self else { return }
            Task {
                await self.estimator.setTuning(on ? .responsive : RoomFilter.Tuning())
                await self.refresh()
            }
        }.store(in: &bag)
        recorder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        if prefs.responsive {
            let estimator = self.estimator
            Task { await estimator.setTuning(.responsive) }
        }
        if let dir = Snapshot.requestedDirectory {
            Task { await Snapshot.run(self, to: dir) }
            return
        }
        startLoop()
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.prefs.refreshMinutes * 60))
            }
        }
    }

    var format: TemperatureFormat { prefs.format }
    var panelFormat: TemperatureFormat { prefs.panelFormat }

    /// e.g. "↓ 0.3 °C in the last hour", "Steady over the last hour", or nil without
    /// an hour of history.
    var trend: (text: String, symbol: String)? {
        guard let d = estimate?.trend(over: 3600), estimate?.source != .stale else { return nil }
        let f = panelFormat
        let shown = f.convertDelta(abs(d))
        if shown < 0.1 { return ("Steady over the last hour", "arrow.right") }
        let amount = f.number(shown, decimals: 1) + " " + f.symbol
        return d > 0 ? ("Up \(amount) in the last hour", "arrow.up.right")
                     : ("Down \(amount) in the last hour", "arrow.down.right")
    }

    /// Menu bar text, e.g. `18°`; `—` until the first estimate.
    var menuTitle: String {
        guard let room = estimate?.room else { return "—" }
        return format.compact(room)
    }

    var menuSymbol: String {
        switch estimate?.source {
        case .filter, .night: "thermometer.medium"
        case .stale: "thermometer.medium.slash"
        default: "thermometer.low"
        }
    }

    var accessibilitySummary: String {
        guard let e = estimate, let room = e.room else { return "Room temperature not available yet" }
        var s = "Room temperature \(panelFormat.full(room))"
        if let sd = e.roomSD { s += ", plus or minus \(panelFormat.uncertainty(sd).dropFirst(2))" }
        if let t = trend { s += ". \(t.text)" }
        if e.source == .stale { s += ". Recording has stopped" }
        return s
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        recorder.refresh()
        do {
            estimate = try await estimator.estimate()
            problem = nil
        } catch {
            log.error("estimate failed: \(String(describing: error), privacy: .public)")
            problem = Self.friendly(error)
        }
    }

    /// Plain-language message for the panel; technical detail goes to the system log.
    static func friendly(_ error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("unable to open") || text.contains("no such") || text.contains("cannot open") {
            return "No recorded data yet. Start recording to begin."
        }
        if text.contains("locked") || text.contains("busy") {
            return "The data is busy right now. It will refresh shortly."
        }
        return "Couldn't read the recorded data. Details are in Console (com.thermac.bar)."
    }
}
