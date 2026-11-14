/// A four-character code as used by the SMC for keys and data types, e.g. `TB0T`, `flt `.
public struct FourCC: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    /// Creates a code from a 4-character ASCII string. Shorter strings are space-padded.
    public init?(_ string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count <= 4 else { return nil }
        let padded = bytes + Array(repeating: UInt8(ascii: " "), count: 4 - bytes.count)
        raw = padded.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: raw >> UInt32($0)) }
        return String(decoding: bytes.map { (0x20...0x7e).contains($0) ? $0 : UInt8(ascii: "?") },
                      as: UTF8.self)
    }

    public static func < (lhs: FourCC, rhs: FourCC) -> Bool { lhs.description < rhs.description }
}
