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
        recorder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
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
        var s = "Room temperature \(format.full(room))"
        if let sd = e.roomSD { s += ", plus or minus \(format.uncertainty(sd).dropFirst(2))" }
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
