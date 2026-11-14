import Foundation
import Testing
@testable import ThermacCore

@Suite("Temperature format")
struct TemperatureFormatTests {
    let us = Locale(identifier: "en_US"), uk = Locale(identifier: "en_GB"), de = Locale(identifier: "de_DE")

    @Test func systemPreferenceFollowsMeasurementSystem() {
        #expect(TemperatureUnitPreference.system.resolved(locale: us) == .fahrenheit)
        #expect(TemperatureUnitPreference.system.resolved(locale: uk) == .celsius)
        #expect(TemperatureUnitPreference.celsius.resolved(locale: us) == .celsius)
    }

    @Test func wholeDegreesByDefaultStyle() {
        let f = TemperatureFormat(unit: .celsius, decimals: 0, locale: uk)
        #expect(f.compact(17.6) == "18°")
        #expect(f.full(17.6) == "18 °C")
        #expect(f.uncertainty(1.03) == "± 1 °C")
    }

    @Test func fahrenheitConvertsValuesAndDifferencesCorrectly() {
        let f = TemperatureFormat(unit: .fahrenheit, decimals: 1, locale: us)
        #expect(f.full(20) == "68.0 °F")
        #expect(f.uncertainty(1.0) == "± 1.8 °F")      // a difference: no +32
    }

    @Test func respectsDecimalComma() {
        let f = TemperatureFormat(unit: .celsius, decimals: 1, locale: de)
        #expect(f.full(17.64) == "17,6 °C")
    }

    @Test func neverShowsNegativeZero() {
        let f = TemperatureFormat(unit: .celsius, decimals: 0, locale: uk)
        #expect(f.compact(-0.3) == "0°")
    }
}
