import Foundation
import ThermacCore

@MainActor
enum Commands {
    // MARK: doctor

    /// Capability check. Returns true when the minimum set for the model is present.
    static func doctor() -> Bool {
        let suite = SensorSuite(mode: .all)
        Thread.sleep(forTimeInterval: 1)
        let readings = suite.readings()
        let value = Dictionary(readings.map { ($0.channel.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        func count(_ match: (Channel) -> Bool) -> Int { readings.filter { match($0.channel) }.count }
        func names(_ cat: SensorCategory) -> [String] {
            readings.filter { $0.channel.category == cat && $0.channel.kind == .temperature }.map(\.channel.name)
        }

        let model = sysctlString("hw.model") ?? "?"
        print("thermac doctor — \(model), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n")

        let temps = count { $0.kind == .temperature }
        let slow = names(.battery) + names(.ssd) + names(.skin)
        let fans = readings.filter { $0.channel.kind == .fan }
        let checks: [(String, Bool, String, Bool)] = [
            // (label, ok, detail, required)
            ("HID thermal sensors", suite.hub != nil,
             "\(count { $0.name.hasPrefix("hid:") && $0.kind == .temperature }) readable", false),
            ("AppleSMC access", suite.smc != nil, suite.smcError ?? "\(suite.smc?.keyCount() ?? 0) keys", true),
            ("Temperature channels", temps > 0, "\(temps) readable", true),
            ("Slow sensors (battery/SSD/skin)", !slow.isEmpty,
             "\(slow.count): " + slow.prefix(5).joined(separator: ", "), true),
            ("Ambient candidates", !names(.ambientCandidate).isEmpty,
             names(.ambientCandidate).map { "\($0) = \(fmt(value[$0])) °C" }.joined(separator: ", "), false),
            ("Fans", !fans.isEmpty,
             fans.isEmpty ? "none / fanless" : fans.map { fmt($0.value, 0) + " rpm" }.joined(separator: ", "), false),
            ("System power (SMC PSTR)", value["smc:PSTR"] != nil, fmt(value["smc:PSTR"]) + " W", true),
            ("CPU power (SMC PHPC)", value["smc:PHPC"] != nil, fmt(value["smc:PHPC"]) + " W", false),
            ("GPU power (IOReport)", value["ioreport:gpu"] != nil, fmt(value["ioreport:gpu"], 3) + " W", false),
            ("Power adapter state", value["sys:on_ac"] != nil,
             value["sys:on_ac"].map { $0 > 0 ? "AC" : "battery" } ?? "", false),
            ("Sleep/wake timestamps", PowerEvents.lastWake != nil || PowerEvents.bootTime != nil,
             "last wake: \(PowerEvents.lastWake.map(iso) ?? "none since boot")", false),
            ("Running without root", geteuid() != 0, "uid \(geteuid())", false),
        ]

        var go = true
        for (label, ok, detail, required) in checks {
            print("  \(ok ? "✓" : (required ? "✗" : "–")) \(pad(label, 34)) \(detail)")
            if required && !ok { go = false }
        }
        let modelSet = SensorSuite(mode: .model).channels.count
        print("\n  Model channel set: \(modelSet) channels (of \(suite.channels.count) available)")
        print("\nVerdict: \(go ? "GO — minimum sensor set available." : "NO-GO — a required capability is missing.")")
        return go
    }

    // MARK: sensors

    static func sensors(mode: SensorSuite.Mode, raw: Bool) {
        let suite = SensorSuite(mode: mode)
        Thread.sleep(forTimeInterval: 1)
        let readings = suite.readings()

        var groups: [(String, (Channel) -> Bool)] = SensorCategory.allCases.map { cat in
            ("temperature · \(cat.rawValue)", { $0.kind == .temperature && $0.category == cat })
        }
        // Explicit closure types keep older compilers from timing out on type inference.
        let isPower: (Channel) -> Bool = { $0.kind == .power }
        let isFan: (Channel) -> Bool = { $0.kind == .fan }
        let isState: (Channel) -> Bool = { $0.kind == .state }
        groups.append(("power", isPower))
        groups.append(("fans", isFan))
        groups.append(("system state", isState))
        for (title, match) in groups {
            let rows = readings.filter { match($0.channel) }
            guard !rows.isEmpty else { continue }
            print("== \(title) (\(rows.count)) ==")
            for r in rows {
                let unit = switch r.channel.kind {
                case .temperature: "°C"
                case .power: "W"
                case .fan: "rpm"
                case .state: ""
                }
                print("  \(pad(r.channel.name, 30)) \(fmt(r.value, r.channel.kind == .fan ? 0 : 3)) \(unit)")
            }
            print()
        }
        print("\(readings.count) of \(suite.channels.count) channels reporting (\(mode == .all ? "all" : "model set"))")

        if raw, let smc = suite.smc {
            print("\n== All SMC keys ==")
            for key in smc.allKeys() {
                guard let v = try? smc.read(key) else { continue }
                let hex = v.bytes.map { String(format: "%02x", $0) }.joined()
                print("  \(key) [\(v.type)] \(pad(fmt(v.number, 3), 14)) \(hex)")
            }
        }
    }

    // MARK: record

    static func record(dbPath: String, interval: Double, mode: SensorSuite.Mode) -> Never {
        let store: SampleStore
        do { store = try SampleStore(path: dbPath) } catch { fail("cannot open \(dbPath): \(error)") }
        let suite = SensorSuite(mode: mode)
        let recorder: Recorder
        do { recorder = try Recorder(store: store, suite: suite, interval: interval) } catch { fail("\(error)") }

        try? store.setMeta("interval", String(interval))
        try? store.setMeta("hw_model", sysctlString("hw.model") ?? "?")
        let modeName = mode == .all ? "all" : "model"
        let detail = "{\"interval\":\(interval),\"channels\":\(suite.channels.count),\"mode\":\"\(modeName)\",\"pid\":\(getpid())}"
        do { try recorder.start(detail: detail) } catch { fail("\(error)") }
        FileHandle.standardError.write(Data(
            "thermac: recording \(suite.channels.count) channels every \(interval)s → \(dbPath)\n".utf8))

        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    recorder.stop(reason: sig == SIGINT ? "interrupt" : "terminate")
                    FileHandle.standardError.write(Data("thermac: stopped after \(recorder.ticks) ticks\n".utf8))
                    exit(0)
                }
            }
            source.resume()
            sources.append(source)
        }
        // Drive the main queue from the main run loop. (`dispatchMain()` would run
        // main-queue blocks on a worker thread, breaking @MainActor isolation.)
        while true {
            _ = RunLoop.main.run(mode: .default, before: .distantFuture)
            withExtendedLifetime(sources) {}
        }
    }

    // MARK: status

    static func status(dbPath: String) {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            fail("no database at \(dbPath) — run `thermac record` first")
        }
        do {
            let store = try SampleStore(path: dbPath)
            let channels = try store.channelNames()
            let ticks = try store.tickTimes()
            let events = try store.events()
            let interval = store.meta("interval").flatMap(Double.init) ?? 5
            let now = Date().timeIntervalSince1970

            print("Database   \(dbPath) (\(byteString(store.fileSize)))")
            let kinds = Dictionary(grouping: channels, by: \.kind).map { "\($0.value.count) \($0.key)" }.sorted()
            print("Channels   \(channels.count) — \(kinds.joined(separator: ", "))")
            guard let first = ticks.first, let last = ticks.last else { print("Samples    none yet"); return }
            print("Samples    \(try store.count()) values in \(ticks.count) ticks")
            print("Span       \(stamp(first)) → \(stamp(last)) (\(durationString(last - first)))")
            let stale = now - last > 3 * interval
            print("Last tick  \(durationString(now - last)) ago\(stale ? "  ⚠︎ recorder not running?" : "")")

            let counts = Dictionary(grouping: events, by: \.type).mapValues(\.count)
            print("Events     " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

            let gaps = GapAnalysis.unexplainedGaps(ticks: ticks, events: events, threshold: 3 * interval)
            let gapTotal = gaps.reduce(0) { $0 + $1.duration }
            print("Gaps       \(gaps.count) unexplained (> \(fmt(3 * interval, 0)) s, not sleep/stop), total \(durationString(gapTotal))")
            for g in gaps.suffix(5) { print("             \(stamp(g.start)) for \(durationString(g.duration))") }

            let anchors = events.filter { $0.type == "cold_start" }
            print("Cold-start anchors  \(anchors.count)")
            for a in anchors.suffix(5) { print("             \(stamp(a.time))  \(a.detail ?? "")") }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: events

    static func events(dbPath: String, since: Double) {
        do {
            let store = try SampleStore(path: dbPath)
            for e in try store.events(from: since) {
                print("\(stamp(e.time))  \(pad(e.type, 10)) \(e.detail ?? "")")
            }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: export

    static func export(dbPath: String, since: Double, path: String?) {
        do {
            let store = try SampleStore(path: dbPath)
            let names = try store.channelNames().map(\.name)
            let column = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
            let out = try output(path)

            out.write(Data(((["time", "unix"] + names).map(csv).joined(separator: ",") + "\n").utf8))
            var currentT: Double?
            var row = [String](repeating: "", count: names.count)
            var lines = 0
            func flush() {
                guard let t = currentT else { return }
                let line = [stamp(t), fmt(t, 3)] + row
                out.write(Data((line.joined(separator: ",") + "\n").utf8))
                row = [String](repeating: "", count: names.count)
                lines += 1
            }
            for r in try store.rows(from: since) {
                if r.t != currentT { flush(); currentT = r.t }
                if let i = column[r.channel] { row[i] = fmt(r.value, 4) }
            }
            flush()
            if let path { FileHandle.standardError.write(Data("thermac: wrote \(lines) rows to \(path)\n".utf8)) }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: agent

    static let agentLabel = "com.thermac.recorder"
    static var agentPlist: String { NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist" }

    static func agent(_ action: String, interval: Double) {
        let domain = "gui/\(getuid())"
        switch action {
        case "install":
            guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
                fail("cannot resolve executable path")
            }
            let logDir = NSHomeDirectory() + "/Library/Logs/thermac"
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [exe, "record", "-i", String(interval)],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Standard",
                "Nice": 10,
                "LowPriorityIO": true,
                "StandardErrorPath": logDir + "/recorder.log",
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try FileManager.default.createDirectory(atPath: (agentPlist as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                launchctl(["bootout", "\(domain)/\(agentLabel)"]) // replace if already loaded
                try data.write(to: URL(fileURLWithPath: agentPlist))
            } catch {
                fail("cannot write \(agentPlist): \(error)")
            }
            let rc = launchctl(["bootstrap", domain, agentPlist])
            print(rc == 0
                  ? "Installed and started \(agentLabel)\n  binary: \(exe)\n  every \(interval)s, log: \(logDir)/recorder.log"
                  : "Wrote \(agentPlist) but launchctl bootstrap failed (\(rc))")
        case "uninstall":
            launchctl(["bootout", "\(domain)/\(agentLabel)"])
            try? FileManager.default.removeItem(atPath: agentPlist)
            print("Removed \(agentLabel)")
        case "status":
            let installed = FileManager.default.fileExists(atPath: agentPlist)
            let running = launchctl(["print", "\(domain)/\(agentLabel)"]) == 0
            print("agent \(agentLabel): \(installed ? "installed" : "not installed"), \(running ? "loaded" : "not loaded")")
        default:
            fail("unknown agent action '\(action)' (install | uninstall | status)")
        }
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: log (CSV stream, no database)

    static func log(path: String?, interval: Double, mode: SensorSuite.Mode) {
        let suite = SensorSuite(mode: mode)
        let out: FileHandle
        do { out = try output(path) } catch { fail("\(error)") }

        out.write(Data(((["time", "unix"] + suite.channels.map(\.name)).map(csv).joined(separator: ",") + "\n").utf8))
        if let path {
            FileHandle.standardError.write(Data(
                "logging \(suite.channels.count) channels every \(interval)s to \(path) — Ctrl-C to stop\n".utf8))
        }
        Thread.sleep(forTimeInterval: interval)
        while true {
            let started = Date()
            let values = suite.read()
            let row = [iso(started), fmt(started.timeIntervalSince1970, 3)] + values.map { $0.map { fmt($0, 3) } ?? "" }
            out.write(Data((row.joined(separator: ",") + "\n").utf8))
            Thread.sleep(forTimeInterval: max(0, interval - Date().timeIntervalSince(started)))
        }
    }

    // MARK: helpers

    static func output(_ path: String?) throws -> FileHandle {
        guard let path else { return .standardOutput }
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return handle
    }

    /// Parses durations like `90s`, `30m`, `24h`, `7d` into seconds.
    nonisolated static func parseDuration(_ s: String) -> Double? {
        guard let unit = s.last, unit.isLetter else { return Double(s) }
        guard let n = Double(s.dropLast()) else { return nil }
        switch unit {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return nil
        }
    }

    static func durationString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 120 { return "\(s)s" }
        if s < 7200 { return "\(s / 60)m" }
        if s < 172_800 { return String(format: "%.1fh", seconds / 3600) }
        return String(format: "%.1fd", seconds / 86400)
    }

    static func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    static func csv(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func stamp(_ t: Double) -> String { iso(Date(timeIntervalSince1970: t)) }

    static func iso(_ d: Date) -> String {
        ISO8601DateFormatter.string(from: d, timeZone: .current,
                                    formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
