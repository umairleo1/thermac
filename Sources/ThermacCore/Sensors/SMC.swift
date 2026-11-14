import CThermacPrivate

/// A raw value read from the SMC.
public struct SMCValue: Sendable {
    public let key: FourCC
    public let type: FourCC
    public let bytes: [UInt8]

    public init(key: FourCC, type: FourCC, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    /// The value decoded as a number, or nil for unknown/non-numeric types.
    public var number: Double? { SMCDecoder.decode(type: type, bytes: bytes) }
}

/// Decodes SMC data types. SMC integers are big-endian; on Apple Silicon `flt ` is a
/// little-endian IEEE-754 float and `ioft` a little-endian 48.16 fixed-point value.
public enum SMCDecoder {
    public static func decode(type: FourCC, bytes: [UInt8]) -> Double? {
        func be(_ n: Int) -> UInt64? {
            guard bytes.count >= n else { return nil }
            return bytes[0..<n].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func le(_ n: Int) -> UInt64? {
            guard bytes.count >= n else { return nil }
            return bytes[0..<n].reversed().reduce(0) { ($0 << 8) | UInt64($1) }
        }
        switch type.description {
        case "flt ":
            guard let v = le(4) else { return nil }
            let f = Double(Float(bitPattern: UInt32(v)))
            return f.isFinite ? f : nil
        case "ui8 ", "flag": return be(1).map { Double($0) }
        case "ui16": return be(2).map { Double($0) }
        case "ui32": return be(4).map { Double($0) }
        case "si8 ": return be(1).map { Double(Int8(truncatingIfNeeded: $0)) }
        case "si16": return be(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "sp78": return be(2).map { Double(Int16(truncatingIfNeeded: $0)) / 256 }
        case "fpe2": return be(2).map { Double($0) / 4 }
        case "ioft": return le(8).map { Double(Int64(bitPattern: $0)) / 65536 }
        default: return nil
        }
    }
}

public enum SMCError: Error, CustomStringConvertible {
    case openFailed(Int32)
    case readFailed(FourCC, Int32)

    public var description: String {
        switch self {
        case .openFailed(let rc): "could not open AppleSMC (code \(rc))"
        case .readFailed(let key, let rc): "could not read SMC key \(key) (code \(rc))"
        }
    }
}

/// Unprivileged read-only connection to the System Management Controller.
public final class SMC {
    private let connection: UInt32
    /// Key → (size, type) learned on first read; saves one kernel call per later read.
    private var keyInfo: [UInt32: (size: UInt32, type: UInt32)] = [:]

    public init() throws {
        var conn: UInt32 = 0
        let rc = tm_smc_open(&conn)
        guard rc == 0 else { throw SMCError.openFailed(rc) }
        connection = conn
    }

    deinit { tm_smc_close(connection) }

    public func read(_ key: FourCC) throws -> SMCValue {
        var out = tm_smc_value()
        let rc: Int32
        if let info = keyInfo[key.raw] {
            rc = tm_smc_read_known(connection, key.raw, info.size, info.type, &out)
        } else {
            rc = tm_smc_read(connection, key.raw, &out)
            if rc == 0 { keyInfo[key.raw] = (out.dataSize, out.dataType) }
        }
        guard rc == 0 else { throw SMCError.readFailed(key, rc) }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(out.dataSize))) }
        return SMCValue(key: key, type: FourCC(raw: out.dataType), bytes: bytes)
    }

    /// Reads a key and decodes it as a number; nil if missing or non-numeric.
    public func number(_ key: String) -> Double? {
        guard let code = FourCC(key) else { return nil }
        return (try? read(code))?.number
    }

    /// Number of keys the SMC exposes (`#KEY`).
    public func keyCount() -> Int {
        Int(number("#KEY") ?? 0)
    }

    /// Every key the SMC exposes, in index order.
    public func allKeys() -> [FourCC] {
        (0..<keyCount()).compactMap { index in
            var raw: UInt32 = 0
            return tm_smc_key_at_index(connection, UInt32(index), &raw) == 0 ? FourCC(raw: raw) : nil
        }
    }

    /// Fan speeds in RPM (`F0Ac`, `F1Ac`, …), empty on fanless Macs.
    public func fanSpeeds() -> [Double] {
        let count = Int(number("FNum") ?? 0)
        return (0..<count).compactMap { number("F\($0)Ac") }
    }
}
