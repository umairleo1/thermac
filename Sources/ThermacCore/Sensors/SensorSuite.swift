import Foundation

/// Owns every sensor source and reads a fixed, ordered list of channels.
/// Any source may be unavailable; channels degrade to nil, reads never fail.
public final class SensorSuite {
    public enum Mode: Sendable {
        /// The catalog's model set (~30 channels) — cheap enough to run continuously.
        case model
        /// Every readable sensor — research / discovery mode.
        case all
    }

    /// SMC power keys of interest, IEEE floats in watts. Verified on Mac16,8 (M4 Pro):
    /// each tracks load (e.g. PSTR 6.8 → 18.2 W, idle → all-core load).
    public static let powerKeys: [(key: String, label: String)] = [
        ("PSTR", "system total"),
        ("PPBR", "battery rail"),
        ("PDTR", "DC-in (adapter)"),
        ("PHPC", "CPU complex"),
        ("PMVC", "SoC main rail"),
        ("PZC0", "zone 0"),
        ("PZC1", "zone 1"),
    ]

    private enum Accessor {
        case hid(Int), smc(FourCC), fan(Int), gpu, cpuLoad, onAC, charging, batteryPercent
    }

    public let hub: HIDSensorHub?
    public let smc: SMC?
    public let energy: IOReportEnergy?
    public let smcError: String?
    /// Channels in read order; `read()` returns values aligned with this array.
    public let channels: [Channel]
    private let accessors: [Accessor]
    private let cpu = CPULoad()

    public init(mode: Mode = .model) {
        hub = HIDSensorHub()
        energy = IOReportEnergy()
        var smc: SMC?
        do { smc = try SMC(); smcError = nil } catch { smcError = String(describing: error) }
        self.smc = smc

        // Only sensors that report now; e.g. 25 `PMU tdev*` services on M4 Pro never do.
        let hidNames = hub.map { hub in hub.names.indices.filter { hub.read(index: $0) != nil }.map { hub.names[$0] } } ?? []
        let smcTemps = smc.map(Self.discoverTemperatureKeys) ?? []
        let selected = SensorCatalog.select(hid: hidNames, smc: smcTemps.map(\.description),
                                            all: mode == .all)

        var channels: [Channel] = []
        var accessors: [Accessor] = []
        func add(_ name: String, _ kind: ChannelKind, _ cat: SensorCategory, _ acc: Accessor) {
            channels.append(Channel(name: name, kind: kind, category: cat))
            accessors.append(acc)
        }

        // Temperatures
        let hidIndex = Dictionary(uniqueKeysWithValues: (hub?.names ?? []).enumerated().map { ($1, $0) })
        for name in selected.hid {
            add("hid:\(name)", .temperature, SensorCatalog.classify(hid: name), .hid(hidIndex[name]!))
        }
        for key in selected.smc {
            add("smc:\(key)", .temperature, SensorCatalog.classify(smc: key), .smc(FourCC(key)!))
        }
        // Power
        if let smc {
            for (key, _) in Self.powerKeys where smc.number(key) != nil {
                add("smc:\(key)", .power, .unknown, .smc(FourCC(key)!))
            }
        }
        if energy != nil { add("ioreport:gpu", .power, .soc, .gpu) }
        // Fans
        for i in 0..<Int(smc?.number("FNum") ?? 0) {
            add("fan:\(i)", .fan, .unknown, .fan(i))
        }
        // System state
        add("sys:cpu_load", .state, .unknown, .cpuLoad)
        if PowerSourceState.current() != nil {
            add("sys:on_ac", .state, .unknown, .onAC)
            add("sys:charging", .state, .unknown, .charging)
            add("sys:battery_pct", .state, .unknown, .batteryPercent)
        }

        self.channels = channels
        self.accessors = accessors
        _ = energy?.sample() // prime the delta
    }

    /// SMC keys that look like temperatures: start with `T` and decode to a plausible °C.
    static func discoverTemperatureKeys(_ smc: SMC) -> [FourCC] {
        smc.allKeys()
            .filter { $0.description.hasPrefix("T") }
            .filter { key in
                guard let value = try? smc.read(key),
                      ["flt ", "sp78", "ioft"].contains(value.type.description),
                      let c = value.number else { return false }
                return c > 0 && c < 130
            }
            .sorted()
    }

    /// Reads every channel once. Values align with `channels`; nil = not available now.
    public func read() -> [Double?] {
        let power = PowerSourceState.current()
        let load = cpu.sample()
        let gpu = energy.map { PowerBreakdown($0.sample()).gpu } ?? nil

        return accessors.map { accessor in
            switch accessor {
            case .hid(let i): hub?.read(index: i)
            case .smc(let key): (try? smc?.read(key))?.number
            case .fan(let i): smc?.number("F\(i)Ac")
            case .gpu: gpu
            case .cpuLoad: load
            case .onAC: power.map { $0.onAC ? 1 : 0 }
            case .charging: power.map { $0.charging ? 1 : 0 }
            case .batteryPercent: power?.batteryPercent
            }
        }
    }

    /// Reads once and pairs values with their channels, skipping unavailable ones.
    public func readings() -> [(channel: Channel, value: Double)] {
        zip(channels, read()).compactMap { ch, v in v.map { (ch, $0) } }
    }
}
