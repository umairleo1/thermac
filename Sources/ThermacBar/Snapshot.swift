import AppKit
import SwiftUI

/// Developer aid: `ThermacBar --snapshot DIR` renders the panel and settings in light and
/// dark mode to PNGs, then quits. Used to review the UI without clicking the menu bar.
@MainActor
enum Snapshot {
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(_ model: BarModel, to dir: URL) async {
        await model.refresh()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            await write(PanelView(model: model), dark: dark, to: dir.appendingPathComponent("panel-\(name).png"))
            await write(SettingsView(model: model, prefs: model.prefs, recorder: model.recorder),
                        dark: dark, to: dir.appendingPathComponent("settings-\(name).png"))
        }
        exit(0)
    }

    /// Hosts the view in a real (off-screen) window so native AppKit controls render too.
    private static func write(_ view: some View, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(800))      // let charts and controls lay out
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
