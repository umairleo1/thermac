import Foundation
import ThermacCore

/// User settings, persisted in UserDefaults (`com.thermac.bar`).
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var unit: TemperatureUnitPreference { didSet { defaults.set(unit.rawValue, forKey: "unit") } }
    /// 0 = whole degrees (default: the estimate is only good to about ± 1 °C).
    @Published var decimals: Int { didSet { defaults.set(decimals, forKey: "decimals") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }

    private init() {
        unit = TemperatureUnitPreference(rawValue: defaults.string(forKey: "unit") ?? "") ?? .system
        decimals = defaults.object(forKey: "decimals") as? Int ?? 0
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5
    }

    var format: TemperatureFormat { TemperatureFormat(unit: unit.resolved(), decimals: decimals) }
}
