import AppKit
import SwiftUI

@main
struct ThermacBarApp: App {
    @StateObject private var model = BarModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Label(model.menuTitle, systemImage: model.menuSymbol)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(model.accessibilitySummary)
        }
        .menuBarExtraStyle(.window)

        Window("thermac Settings", id: SettingsView.windowID) {
            SettingsView(model: model, prefs: model.prefs, recorder: model.recorder)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    @MainActor static func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "thermac",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: "Estimates the temperature of your room from your Mac's own sensors — "
                    + "no thermometer, no extra hardware.\n\nExperimental: about ± 1 °C. "
                    + "All data stays on this Mac.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }
}
