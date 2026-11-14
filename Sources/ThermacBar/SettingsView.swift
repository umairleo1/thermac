import AppKit
import ServiceManagement
import SwiftUI
import ThermacCore

struct SettingsView: View {
    static let windowID = "settings"

    @ObservedObject var model: BarModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var recorder: RecorderManager
    @StateObject private var login = LoginItem()

    var body: some View {
        Form {
            Section("Display") {
                Picker("Units", selection: $prefs.unit) {
                    Text("System (\(TemperatureUnitPreference.system.resolved() == .fahrenheit ? "°F" : "°C"))")
                        .tag(TemperatureUnitPreference.system)
                    Text("Celsius (°C)").tag(TemperatureUnitPreference.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnitPreference.fahrenheit)
                }
                Picker("Menu bar precision", selection: $prefs.decimals) {
                    Text("One decimal").tag(1)
                    Text("Whole degrees").tag(0)
                }
                Text("The estimate is good to about ± 1 °C. With whole degrees the menu bar rounds (17.6 shows as 18°); the panel always shows one decimal.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Refresh", selection: $prefs.refreshMinutes) {
                    Text("Every minute").tag(1)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                }
            }

            Section("Estimate") {
                Picker("Response", selection: $prefs.responsive) {
                    Text("Steady — most accurate").tag(false)
                    Text("Responsive — reacts faster").tag(true)
                }
                Text(prefs.responsive
                     ? "Shows most of a room change within about an hour, but jitters more and is less accurate."
                     : "Shows room changes over a few hours. Your Mac itself takes hours to cool or warm, so this is the most accurate.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("General") {
                Toggle("Open thermac at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                    .disabled(!login.available)
                if let err = login.error {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Background recording") {
                LabeledContent("Status") { Text(recorderStatus).foregroundStyle(.secondary) }
                recorderControls
                if let err = recorder.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                Button("Show Data in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: SampleStore.defaultPath)])
                }
            }

            Section {
                HStack {
                    Text("thermac \(AppInfo.version)").foregroundStyle(.secondary)
                    Spacer()
                    Button("About thermac") { AppInfo.showAbout() }
                }
            } footer: {
                Text("thermac makes no network connections. All data stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { recorder.refresh(); login.refresh() }
    }

    private var recorderStatus: String {
        switch recorder.state {
        case .running: "Recording every 5 seconds"
        case .needsApproval: "Waiting for approval in Login Items"
        case .commandLine: "Recording (installed from the command line)"
        case .off: "Off"
        case .unavailable: "Unavailable — open the app from Applications"
        }
    }

    @ViewBuilder private var recorderControls: some View {
        switch recorder.state {
        case .running:
            Button("Stop Recording") { recorder.stop() }
        case .off:
            Button("Start Recording") { recorder.start() }
        case .needsApproval:
            Button("Open Login Items…") { recorder.openLoginItemsSettings() }
        case .commandLine:
            VStack(alignment: .leading, spacing: 6) {
                Text("Let the app manage the recorder instead. Your recorded data is kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Switch to App-Managed Recording") { recorder.adoptCommandLineRecorder() }
            }
        case .unavailable:
            EmptyView()
        }
    }
}

/// "Open at login" via SMAppService (needs the app bundle).
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var available = true
    @Published private(set) var error: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        available = status != .notFound
    }

    func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = on ? "Couldn't add thermac to Login Items. Open it from Applications and try again."
                            : "Couldn't remove thermac from Login Items."
        }
        refresh()
    }
}
