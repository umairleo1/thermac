/// What a channel physically measures, used to pick which sensors the model needs.
public enum SensorCategory: String, CaseIterable, Sendable {
    /// Battery cells — large thermal mass, slowest sensors.
    case battery
    /// SSD / NAND — slow, isolated from the SoC.
    case ssd
    /// Palm rest, chassis, airflow, wireless module — the "skin" of the machine.
    case skin
    /// Display panel / hinge sensors.
    case display
    /// SoC die and power-delivery sensors — fast, track load closely.
    case soc
    /// Values that may be Apple's own ambient estimates (e.g. SMC `TVA0`, `TAOL`).
    /// Logged so they can be checked against cold-start anchors; never trusted blindly.
    case ambientCandidate = "ambient_candidate"
    /// Constant calibration references (e.g. `PMU tcal`) — not real temperatures.
    case calibration
    case unknown
}

public enum ChannelKind: String, Sendable {
    case temperature, power, fan, state
}

/// One recorded quantity. `name` is globally unique, e.g. `smc:TB0T`, `hid:NAND CH0 temp`.
public struct Channel: Hashable, Sendable {
    public let name: String
    public let kind: ChannelKind
    public let category: SensorCategory

    public init(name: String, kind: ChannelKind, category: SensorCategory) {
        self.name = name
        self.kind = kind
        self.category = category
    }
}

/// Classifies sensors by name and chooses the subset the thermal model records.
///
/// SMC key names are not standardised across Macs, so classification is by prefix rule
/// and was derived on a Mac16,8 (M4 Pro). Unrecognised keys fall into `.unknown` and are
/// only recorded in `--all` mode. Phase 2+ refines the choice with measured time constants.
public enum SensorCatalog {

    public static func classify(hid name: String) -> SensorCategory {
        let n = baseName(name).lowercased()
        if n.contains("battery") || n.contains("gas gauge") { return .battery }
        if n.contains("nand") || n.contains("ssd") { return .ssd }
        if n.contains("tcal") { return .calibration }
        if n.hasPrefix("pmu tdie") || n.hasPrefix("pmu tdev") || n.contains("soc") { return .soc }
        return .unknown
    }

    public static func classify(smc key: String) -> SensorCategory {
        let k = Array(key)
        guard k.count == 4, k[0] == "T" else { return .unknown }
        let p2 = String(k[0...1]), p3 = String(k[0...2])

        if ["TVA0", "TAOL"].contains(key) { return .ambientCandidate }
        if key == "TR0Z" { return .calibration }
        if p2 == "TB", k[2].isNumber, k[3] == "T" { return .battery }
        if p3 == "TH0" { return .ssd }
        if ["Ts0P", "Ts1P", "TS0P", "TSCP", "TW0P", "TPMP", "TPSP", "TCHP"].contains(key)
            || ["TaL", "TaR", "TaT"].contains(p3) { return .skin }
        // TD<digit> (~24 °C) and TG* (TG0B mirrors the battery) are not die sensors.
        if p2 == "TD" { return k[2].isNumber ? .unknown : .display }
        if socFamilies.contains(p2) || ["TP", "TR", "TU", "TV", "TC", "TM", "Ts"].contains(p2) { return .soc }
        return .unknown
    }

    /// Strips the ` #n` suffix that `HIDSensorHub` adds to duplicate names.
    static func baseName(_ name: String) -> String {
        guard let r = name.range(of: " #", options: .backwards),
              name[r.upperBound...].allSatisfy(\.isNumber) else { return name }
        return String(name[..<r.lowerBound])
    }

    /// SMC die-sensor families in preference order: P-cores, E-cores, GPU, fabric.
    static let socFamilies = ["Tp", "Te", "Tg", "Tf"]

    /// Maximum fast SoC sensors to keep per source — enough to see load, cheap to read.
    static let socLimit = 4

    /// Chooses which HID sensors and SMC keys to record.
    /// - all: record every readable sensor (research mode).
    /// - otherwise: every battery/ssd/skin/display/ambient sensor, one instance per HID
    ///   name, and at most `socLimit` SoC sensors per source.
    public static func select(hid: [String], smc: [String], all: Bool) -> (hid: [String], smc: [String]) {
        if all { return (hid, smc) }
        let wanted: Set<SensorCategory> = [.battery, .ssd, .skin, .display, .ambientCandidate]

        var seenBase = Set<String>()
        var socCount = 0
        let pickedHID = hid.filter { name in
            guard seenBase.insert(baseName(name)).inserted else { return false }
            let c = classify(hid: name)
            if c == .soc { socCount += 1; return socCount <= socLimit }
            return wanted.contains(c)
        }

        // For SMC SoC keys take the first key of each preferred die family (Tp, Te, Tg, Tf)
        // so the few we keep span different parts of the die.
        let socPicks = Set(socFamilies.compactMap { family in
            smc.sorted().first { $0.hasPrefix(family) && classify(smc: $0) == .soc }
        }.prefix(socLimit))
        let pickedSMC = smc.filter { wanted.contains(classify(smc: $0)) || socPicks.contains($0) }
        return (pickedHID, pickedSMC)
    }
}
