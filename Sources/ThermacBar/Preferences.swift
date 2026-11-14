import Foundation
import ThermacCore

/// User settings, persisted in UserDefaults (`com.thermac.bar`).
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var unit: TemperatureUnitPreference { didSet { defaults.set(unit.rawValue, forKey: "unit") } }
    /// Menu bar precision. Default 1 decimal, matching the panel (whole degrees made the
    /// menu bar read 18° next to 17.6 °C in the panel). 0 = whole degrees.
    @Published var decimals: Int { didSet { defaults.set(decimals, forKey: "decimals") } }
    /// Opt-in faster tracking (less accurate); see `RoomFilter.Tuning.responsive`.
    @Published var responsive: Bool { didSet { defaults.set(responsive, forKey: "responsive") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }

    private init() {
        unit = TemperatureUnitPreference(rawValue: defaults.string(forKey: "unit") ?? "") ?? .system
        decimals = defaults.object(forKey: "decimals") as? Int ?? 1
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 1
        responsive = defaults.bool(forKey: "responsive")
    }

    /// Menu bar format (user's precision).
    var format: TemperatureFormat { TemperatureFormat(unit: unit.resolved(), decimals: decimals) }
    /// Panel format: always one decimal.
    var panelFormat: TemperatureFormat { TemperatureFormat(unit: unit.resolved(), decimals: 1) }
}
