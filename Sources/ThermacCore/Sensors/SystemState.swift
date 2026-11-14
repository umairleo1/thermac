import Darwin
import Foundation
import IOKit.ps

/// Battery / power-adapter state from the public IOPowerSources API.
public struct PowerSourceState: Sendable {
    public let onAC: Bool
    public let charging: Bool
    public let batteryPercent: Double?

    public static func current() -> PowerSourceState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            return PowerSourceState(
                onAC: state == kIOPSACPowerValue,
                charging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                batteryPercent: (desc[kIOPSCurrentCapacityKey] as? Int).map(Double.init))
        }
        return nil
    }
}

/// Whole-machine CPU utilisation from Mach tick counters.
public final class CPULoad {
    private var previous: host_cpu_load_info?

    public init() { _ = sample() }

    /// Fraction 0…1 of non-idle CPU time since the previous call.
    public func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let prev = previous else { return nil }

        func delta(_ i: Int32) -> Double {
            let now = withUnsafeBytes(of: info.cpu_ticks) { $0.load(fromByteOffset: Int(i) * 4, as: UInt32.self) }
            let old = withUnsafeBytes(of: prev.cpu_ticks) { $0.load(fromByteOffset: Int(i) * 4, as: UInt32.self) }
            return Double(now &- old)
        }
        let user = delta(CPU_STATE_USER), sys = delta(CPU_STATE_SYSTEM)
        let nice = delta(CPU_STATE_NICE), idle = delta(CPU_STATE_IDLE)
        let total = user + sys + nice + idle
        return total > 0 ? (user + sys + nice) / total : nil
    }
}

/// Boot, sleep and wake timestamps from the kernel — needed for cold-start anchors.
public enum PowerEvents {
    public static var bootTime: Date? { timeval(named: "kern.boottime") }
    public static var lastSleep: Date? { timeval(named: "kern.sleeptime") }
    public static var lastWake: Date? { timeval(named: "kern.waketime") }

    private static func timeval(named name: String) -> Date? {
        var tv = Darwin.timeval()
        var size = MemoryLayout<Darwin.timeval>.size
        guard sysctlbyname(name, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }
}
