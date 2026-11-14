import AppKit
import Charts
import SwiftUI
import ThermacCore

struct PanelView: View {
    @ObservedObject var model: BarModel
    @ObservedObject var recorder: RecorderManager
    @Environment(\.openWindow) private var openWindow

    init(model: BarModel) {
        self.model = model
        self.recorder = model.recorder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            setupCallout
            if let e = model.estimate, e.history.count > 1 {
                HistoryChart(history: e.history, format: model.panelFormat, selection: $model.selection)
            }
            details
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 330)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Room temperature")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.estimate?.room.map(model.panelFormat.full) ?? "—")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let sd = model.estimate?.roomSD {
                    Text(model.panelFormat.uncertainty(sd))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilitySummary)

            if let trend = model.trend {
                Label(trend.text, systemImage: trend.symbol)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .accessibilityHidden(true)   // included in the summary above
            }

            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if let source = model.estimate?.source {
                Label(sourceText(source), systemImage: sourceIcon(source))
                    .font(.callout)
                    .foregroundStyle(source == .stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
    }

    private func sourceText(_ s: LiveEstimate.Source) -> String {
        switch s {
        case .filter: "Based on \(model.estimate?.goodNights ?? 0) nights and today's sensor readings"
            + (model.prefs.responsive ? " · responsive mode" : "")
        case .night: "Based on last night only — gets better after a second night"
        case .waiting: "Waiting for the first night — close the lid for 2 hours or more"
        case .stale: "Recording has stopped — this value is getting older"
        }
    }

    private func sourceIcon(_ s: LiveEstimate.Source) -> String {
        switch s {
        case .filter: "checkmark.seal"
        case .night: "moon.zzz"
        case .waiting: "hourglass"
        case .stale: "pause.circle"
        }
    }

    // MARK: Setup

    @ViewBuilder private var setupCallout: some View {
        switch recorder.state {
        case .off:
            callout(icon: "record.circle", title: "Recording is off",
                    text: "thermac needs to record your Mac's sensors in the background to estimate the room temperature.",
                    button: "Start Recording") { recorder.start(); refreshSoon() }
        case .needsApproval:
            callout(icon: "lock", title: "Allow background recording",
                    text: "Turn on thermac in System Settings → General → Login Items.",
                    button: "Open Login Items…") { recorder.openLoginItemsSettings() }
        case .unavailable where model.estimate?.source == .stale || model.estimate == nil:
            callout(icon: "shippingbox", title: "Install the app to record",
                    text: "Move ThermacBar to Applications and open it from there to enable background recording.",
                    button: nil) {}
        default:
            EmptyView()
        }
        if let err = recorder.lastError {
            Label(err, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        }
    }

    private func callout(icon: String, title: String, text: String, button: String?,
                         action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let button {
                Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.regular)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func refreshSoon() {
        Task {
            try? await Task.sleep(for: .seconds(15))
            await model.refresh()
        }
    }

    // MARK: Details

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            if let n = model.estimate?.lastNight {
                GridRow {
                    Text("Last night").foregroundStyle(.secondary)
                    Text("\(model.panelFormat.full(n.room)) · woke \(Date(timeIntervalSince1970: n.time).formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                }
            }
            GridRow {
                Text("Recording").foregroundStyle(.secondary)
                recordingStatus
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var recordingStatus: some View {
        if let s = model.estimate?.lastSample {
            let date = Date(timeIntervalSince1970: s)
            // Relative dates update live, every second.
            if model.estimate?.source == .stale {
                Text("stopped \(Text(date, style: .relative)) ago").foregroundStyle(.orange)
            } else {
                Text("on · last reading \(Text(date, style: .relative)) ago")
            }
        } else {
            Text(recorder.state == .running ? "starting…" : "off")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.refresh() }
            } label: {
                if model.refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.refreshing)
            .keyboardShortcut("r")
            .help("Refresh now")

            Spacer()

            Menu {
                Button("Settings…") { openSettings() }.keyboardShortcut(",")
                Button("About thermac") { AppInfo.showAbout() }
                Divider()
                Button("Quit thermac") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings, About and Quit")
            .accessibilityLabel("More")
        }
        .controlSize(.regular)
    }

    private func openSettings() {
        openWindow(id: SettingsView.windowID)
        NSApp.activate()
    }
}

// MARK: - Chart

struct HistoryChart: View {
    let history: [(t: Double, room: Double, sd: Double)]
    let format: TemperatureFormat
    @Binding var selection: Date?

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let value: Double
        let low: Double
        let high: Double
    }

    private var points: [Point] {
        history.enumerated().map { i, p in
            Point(id: i, date: Date(timeIntervalSince1970: p.t), value: format.convert(p.room),
                  low: format.convert(p.room - p.sd), high: format.convert(p.room + p.sd))
        }
    }

    /// "Last 24 hours · °C", or the real span while there is less history than that.
    private var title: String {
        guard let first = history.first?.t, let last = history.last?.t else { return format.symbol }
        let hours = Int(((last - first) / 3600).rounded())
        return (hours >= 23 ? "Last 24 hours" : "Last \(max(hours, 1)) hours") + " · " + format.symbol
    }

    private var selected: Point? {
        guard let selection else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        let pts = points
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Time", p.date), yStart: .value("Low", p.low), yEnd: .value("High", p.high))
                        .foregroundStyle(.tint.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.date), y: .value("Room", p.value))
                        .interpolationMethod(.monotone)
                }
                if let s = selected {
                    RuleMark(x: .value("Selected", s.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            VStack(spacing: 1) {
                                Text(format.number(s.value, decimals: max(format.decimals, 1)) + " " + format.symbol)
                                    .font(.caption.weight(.semibold)).monospacedDigit()
                                Text(s.date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5))
                        }
                    PointMark(x: .value("Selected", s.date), y: .value("Room", s.value)).symbolSize(30)
                }
            }
            .chartXSelection(value: $selection)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(height: 120)
            .accessibilityChartDescriptor(HistoryChartDescriptor(points: pts.map { ($0.date, $0.value) }, format: format))
        }
    }
}

/// VoiceOver Audio Graph and chart summary.
struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
    let points: [(Date, Double)]
    let format: TemperatureFormat

    func makeChartDescriptor() -> AXChartDescriptor {
        let times = points.map { $0.0.timeIntervalSince1970 }
        let values = points.map(\.1)
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        let x = AXNumericDataAxisDescriptor(title: "Time", range: (times.first ?? 0)...(times.last ?? 1), gridlinePositions: []) {
            Date(timeIntervalSince1970: $0).formatted(.dateTime.weekday().hour().minute())
        }
        let y = AXNumericDataAxisDescriptor(title: "Room temperature", range: lo...max(hi, lo + 0.1), gridlinePositions: []) {
            format.number($0, decimals: 1) + " " + format.symbol
        }
        let series = AXDataSeriesDescriptor(name: "Room temperature", isContinuous: true,
                                            dataPoints: zip(times, values).map { AXDataPoint(x: $0, y: $1) })
        return AXChartDescriptor(title: "Room temperature, last 24 hours",
                                 summary: "Ranges from \(format.number(lo, decimals: 1)) to \(format.number(hi, decimals: 1)) \(format.symbol).",
                                 xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
