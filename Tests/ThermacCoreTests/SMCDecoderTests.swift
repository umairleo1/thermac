import Testing
@testable import ThermacCore

@Suite("FourCC")
struct FourCCTests {
    @Test func roundTrip() {
        #expect(FourCC("TB0T")?.description == "TB0T")
        #expect(FourCC("flt")?.description == "flt ")
        #expect(FourCC("TOOLONG") == nil)
        #expect(FourCC("#KEY")?.raw == 0x234B_4559)
    }
}

@Suite("SMC decoding")
struct SMCDecoderTests {
    func decode(_ type: String, _ bytes: [UInt8]) -> Double? {
        SMCDecoder.decode(type: FourCC(type)!, bytes: bytes)
    }

    @Test func littleEndianFloat() {
        // 36.5 as IEEE-754 float = 0x42120000, stored little-endian
        #expect(decode("flt ", [0x00, 0x00, 0x12, 0x42]) == 36.5)
    }

    @Test func bigEndianIntegers() {
        #expect(decode("ui8 ", [0x07]) == 7)
        #expect(decode("ui16", [0x01, 0x00]) == 256)
        #expect(decode("ui32", [0x00, 0x00, 0x08, 0x9a]) == 2202)
        #expect(decode("si16", [0xff, 0xfe]) == -2)
    }

    @Test func fixedPoint() {
        #expect(decode("sp78", [0x28, 0x80]) == 40.5)
        #expect(decode("fpe2", [0x1f, 0x40]) == 2000)
        // 1.5 in 48.16 little-endian = 0x18000
        #expect(decode("ioft", [0x00, 0x80, 0x01, 0, 0, 0, 0, 0]) == 1.5)
    }

    @Test func rejectsUnknownAndShort() {
        #expect(decode("ch8*", [0x41]) == nil)
        #expect(decode("ui32", [0x01]) == nil)
        #expect(decode("flt ", [0x00, 0x00, 0xc0, 0x7f]) == nil) // NaN
    }
}

@Suite("Energy units")
struct EnergyUnitTests {
    @Test func conversions() {
        #expect(IOReportEnergy.toJoules(1500, unit: "mJ") == 1.5)
        #expect(IOReportEnergy.toJoules(2_000_000, unit: "uJ") == 2)
        #expect(IOReportEnergy.toJoules(5, unit: "W") == nil)
    }

    @Test func uniqueNames() {
        #expect(HIDSensorHub.uniqued(["a", "b", "a", "a"]) == ["a", "b", "a #2", "a #3"])
    }
}
