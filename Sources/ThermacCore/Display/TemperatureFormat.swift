import Foundation

/// The user's unit preference. `.system` follows the Mac's measurement system
/// (System Settings → Language & Region), like Apple's own apps.
public enum TemperatureUnitPreference: String, CaseIterable, Sendable, Identifiable {
    case system, celsius, fahrenheit

    public var id: String { rawValue }

    public func resolved(locale: Locale = .current) -> UnitTemperature {
        switch self {
        case .celsius: .celsius
        case .fahrenheit: .fahrenheit
        case .system: locale.measurementSystem == .us ? .fahrenheit : .celsius
        }
    }
}

/// Locale-aware temperature formatting. Values are stored in °C everywhere; only display
/// converts. Differences (the ± uncertainty) scale by 1.8 in °F with no offset.
public struct TemperatureFormat: Sendable {
    public let unit: UnitTemperature
    public let decimals: Int
    public let locale: Locale

    public init(unit: UnitTemperature, decimals: Int, locale: Locale = .current) {
        self.unit = unit
        self.decimals = max(0, min(decimals, 2))
        self.locale = locale
    }

    public var isFahrenheit: Bool { unit == .fahrenheit }
    public var symbol: String { isFahrenheit ? "°F" : "°C" }

    /// Converts an absolute temperature from °C to the display unit.
    public func convert(_ celsius: Double) -> Double {
        isFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// Converts a temperature *difference* from °C to the display unit.
    public func convertDelta(_ celsius: Double) -> Double {
        isFahrenheit ? celsius * 9 / 5 : celsius
    }

    public func number(_ v: Double, decimals: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        f.usesGroupingSeparator = false
        // Avoid "-0".
        let rounded = (v * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        return f.string(from: NSNumber(value: rounded == 0 ? 0 : rounded)) ?? String(rounded)
    }

    /// Compact form for the menu bar, e.g. `18°`.
    public func compact(_ celsius: Double) -> String {
        number(convert(celsius), decimals: decimals) + "°"
    }

    /// Full form, e.g. `17.6 °C` (or `17,6 °C` in a comma locale).
    public func full(_ celsius: Double) -> String {
        number(convert(celsius), decimals: decimals) + " " + symbol
    }

    /// Just the number in the display unit, e.g. `17.6`.
    public func plain(_ celsius: Double) -> String {
        number(convert(celsius), decimals: decimals)
    }

    /// Uncertainty, e.g. `± 1 °C`. Shown with at least as many decimals as the value,
    /// but never more than one, so it does not suggest false precision.
    public func uncertainty(_ celsiusSD: Double) -> String {
        "± " + number(convertDelta(celsiusSD), decimals: min(max(decimals, 0), 1)) + " " + symbol
    }
}
