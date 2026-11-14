import Foundation
import os
import ServiceManagement

/// Owns the background recorder. The recorder (`thermac record`) ships inside the app
/// bundle and is registered as a login agent with `SMAppService`, so installing the app
/// is the only setup step. A recorder installed earlier from the command line
/// (`thermac agent install`) is detected and left alone — two writers must never run.
@MainActor
final class RecorderManager: ObservableObject {
    enum State: Equatable {
        /// Registered and enabled by this app.
        case running
        /// Registered, waiting for the user to allow it in System Settings → Login Items.
        case needsApproval
        /// Managed by the command-line LaunchAgent.
        case commandLine
        case off
        /// Not running from an app bundle (e.g. a development build).
        case unavailable
    }

    static let agentPlist = "com.thermac.bar.recorder.plist"
    static let legacyLabel = "com.thermac.recorder"
    private let log = Logger(subsystem: "com.thermac.bar", category: "recorder")
    private let service = SMAppService.agent(plistName: agentPlist)

    @Published private(set) var state: State = .off
    @Published var lastError: String?

    var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.legacyLabel).plist")
    }

    init() { refresh() }

    func refresh() {
        if FileManager.default.fileExists(atPath: legacyPlist.path) {
            state = .commandLine
            return
        }
        switch service.status {
        case .enabled: state = .running
        case .requiresApproval: state = .needsApproval
        case .notRegistered: state = .off
        case .notFound: state = .unavailable
        @unknown default: state = .off
        }
    }

    func start() {
        lastError = nil
        do {
            try service.register()
        } catch {
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't start recording. Open the installed app from Applications and try again."
        }
        refresh()
    }

    func stop() {
        lastError = nil
        do {
            try service.unregister()
        } catch {
            log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't stop the recorder."
        }
        refresh()
    }

    /// Replaces the command-line recorder with the app-managed one. Recorded data is
    /// kept: both use the same database.
    func adoptCommandLineRecorder() {
        lastError = nil
        let uid = getuid()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(uid)/\(Self.legacyLabel)"]
        try? p.run()
        p.waitUntilExit()
        do {
            try FileManager.default.removeItem(at: legacyPlist)
        } catch {
            log.error("remove legacy plist failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't remove the command-line recorder. Run `thermac agent uninstall`."
            refresh()
            return
        }
        start()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
