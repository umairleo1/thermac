import Foundation
import ThermacCore

/// User settings, persisted in UserDefaults (`com.thermac.bar`).
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var unit: TemperatureUnitPreference { didSet { defaults.set(unit.rawValue, forKey: "unit") } }
    /// Menu bar precision. 0 = whole degrees (default: the estimate is good to about
    /// ± 1 °C). The panel always shows one decimal so slow changes stay visible.
    @Published var decimals: Int { didSet { defaults.set(decimals, forKey: "decimals") } }
    /// Opt-in faster tracking (less accurate); see `RoomFilter.Tuning.responsive`.
    @Published var responsive: Bool { didSet { defaults.set(responsive, forKey: "responsive") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }

    private init() {
        unit = TemperatureUnitPreference(rawValue: defaults.string(forKey: "unit") ?? "") ?? .system
        decimals = defaults.object(forKey: "decimals") as? Int ?? 0
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 1
        responsive = defaults.bool(forKey: "responsive")
    }

    /// Menu bar format (user's precision).
    var format: TemperatureFormat { TemperatureFormat(unit: unit.resolved(), decimals: decimals) }
    /// Panel format: always one decimal.
    var panelFormat: TemperatureFormat { TemperatureFormat(unit: unit.resolved(), decimals: 1) }
}
