import CThermacPrivate
import CoreFoundation
import Foundation

/// One temperature reading from the HID thermal sensor hub.
public struct HIDTemperature: Sendable {
    /// Unique name (duplicates from the hub get a `#2`, `#3`… suffix).
    public let name: String
    public let celsius: Double
}

/// Reads the Apple Silicon thermal sensors exposed through the private
/// IOHIDEventSystem API (vendor page 0xff00, usage 5).
public final class HIDSensorHub {
    private let client: CFTypeRef
    private let services: [CFTypeRef]
    public let names: [String]

    public init?() {
        guard let client = tm_HIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        let match = [
            "PrimaryUsagePage": Int(TM_HID_PAGE_APPLE_VENDOR),
            "PrimaryUsage": Int(TM_HID_USAGE_TEMPERATURE),
        ] as CFDictionary
        _ = tm_HIDEventSystemClientSetMatching(client, match)
        guard let array = tm_HIDEventSystemClientCopyServices(client) else { return nil }

        let services = (array as NSArray as [AnyObject]).map { $0 as CFTypeRef }
        let raw = services.map { service in
            tm_HIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? "unknown"
        }
        // Sort by name for stable column order; keep services aligned.
        let order = raw.indices.sorted { raw[$0] < raw[$1] }
        self.client = client
        self.services = order.map { services[$0] }
        self.names = Self.uniqued(order.map { raw[$0] })
    }

    /// Reads every sensor. Sensors that fail to report are omitted.
    public func read() -> [HIDTemperature] {
        names.indices.compactMap { i in read(index: i).map { HIDTemperature(name: names[i], celsius: $0) } }
    }

    /// Reads one sensor by its index in `names`; nil if it does not report.
    public func read(index: Int) -> Double? {
        let type = Int64(TM_HID_EVENT_TYPE_TEMPERATURE)
        guard let event = tm_HIDServiceClientCopyEvent(services[index], type, 0, 0) else { return nil }
        let value = tm_HIDEventGetFloatValue(event, Int32(type) << 16)
        return value.isFinite && value > -40 && value < 150 ? value : nil
    }

    static func uniqued(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            seen[name, default: 0] += 1
            let n = seen[name]!
            return n == 1 ? name : "\(name) #\(n)"
        }
    }
}

