import Foundation
import ThermacCore

let usage = """
    thermac — estimate room temperature from your Mac's internal sensors

    USAGE
      thermac doctor                         Check which capabilities work on this Mac
      thermac sensors [--all] [--raw]        List channels by category (--raw: every SMC key)

      thermac record [-i SECS] [--all] [--db PATH]
                                             Record to SQLite until stopped (default 5 s)
      thermac status [--db PATH]             Database summary, gaps, cold-start anchors
      thermac events [--since DUR] [--db PATH]
      thermac export [--since DUR] [-o FILE] [--db PATH]
                                             Wide CSV export (DUR like 30m, 24h, 7d)
      thermac agent install [-i SECS] | uninstall | status
                                             Run the recorder in the background at login

      thermac estimate [--since DUR] [--drift] [--kappa K] [--scan] [-v] [--db PATH]
                                             Room temperature since the last cold start (Phase 4)
      thermac now [--db PATH]               Live room estimate (what the menu bar shows)
      thermac replay [-v] [--db PATH]       Room filter over the log; predicts each next night
      thermac calibrate [--db PATH]         Anchor-calibrated model, leave-one-day-out test
      thermac validate [--db PATH]          Compare estimators at every cold-start anchor
      thermac fit [--since DUR] [--db PATH] Estimate room temperature from recorded data (experimental)
      thermac simulate [--room C] [--hours H] [--seed N] [-o FILE]
                                             Run the reference simulation vs known truth

      thermac log [-o FILE] [-i SECS] [--all]
                                             Stream channels to CSV without a database
    """

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
let args = Array(arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fmt(_ value: Double?, _ digits: Int = 2) -> String {
    guard let value else { return "—" }
    return String(format: "%.\(digits)f", value)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("thermac: \(message)\n".utf8))
    exit(1)
}

let dbPath = option("--db") ?? SampleStore.defaultPath
let interval = max(0.5, option("-i").flatMap(Double.init) ?? (command == "log" ? 1 : 5))
let mode: SensorSuite.Mode = args.contains("--all") ? .all : .model
let since: Double = {
    guard let raw = option("--since") else { return 0 }
    guard let d = Commands.parseDuration(raw) else { fail("bad --since value '\(raw)'") }
    return Date().timeIntervalSince1970 - d
}()

switch command {
case "doctor":
    exit(Commands.doctor() ? 0 : 1)
case "sensors":
    Commands.sensors(mode: mode, raw: args.contains("--raw"))
case "record":
    Commands.record(dbPath: dbPath, interval: interval, mode: mode)
case "status":
    Commands.status(dbPath: dbPath)
case "events":
    Commands.events(dbPath: dbPath, since: since)
case "export":
    Commands.export(dbPath: dbPath, since: since, path: option("-o"))
case "agent":
    Commands.agent(args.first ?? "status", interval: interval)
case "estimate":
    Commands.estimate(dbPath: dbPath, since: since, verbose: args.contains("-v"), drift: args.contains("--drift"),
                       kappa: option("--kappa").flatMap(Double.init) ?? 0, scan: args.contains("--scan"))
case "now":
    Commands.now(dbPath: dbPath, bench: args.contains("--bench"))
case "replay":
    {
        var t = RoomFilter.Tuning()
        if let v = option("--change") { t.changeThreshold = Double(v).flatMap { $0 > 0 ? $0 : nil } }
        if let v = option("--change-window").flatMap(Double.init) { t.changeWindow = v }
        if let v = option("--walk").flatMap(Double.init) { t.roomWalk = v }
        if let v = option("--slow-sd").flatMap(Double.init) { t.slowSD = v }
        if let v = option("--fast-tau").flatMap(Double.init) { t.fastTau = v }
        if let v = option("--fast-sd").flatMap(Double.init) { t.fastSD = v }
        if let v = option("--relocation-gap").flatMap(Double.init) { t.relocationGap = v }
        if let v = option("--relocation-sd").flatMap(Double.init) { t.relocationSD = v }
        Commands.replay(dbPath: dbPath, verbose: args.contains("-v"), weighting: !args.contains("--no-weighting"), tuning: t)
    }()
case "calibrate":
    Commands.calibrate(dbPath: dbPath, verbose: args.contains("-v"))
case "validate":
    Commands.validate(dbPath: dbPath)
case "fit":
    Commands.fit(dbPath: dbPath, since: since)
case "simulate":
    Commands.simulate(room: option("--room").flatMap(Double.init) ?? 21,
                      hours: option("--hours").flatMap(Double.init) ?? 3,
                      seed: option("--seed").flatMap(UInt64.init) ?? 1,
                      csvPath: option("-o"))
case "log":
    Commands.log(path: option("-o"), interval: interval, mode: mode)
case "-h", "--help", "help":
    print(usage)
default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n\n\(usage)\n".utf8))
    exit(2)
}
