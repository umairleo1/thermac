import CThermacPrivate
import Foundation

/// Average power per IOReport "Energy Model" channel over a sampling interval.
/// Reads the same counters as `powermetrics`, without root.
public final class IOReportEnergy {
    private let subscription: CFTypeRef
    private let subscribed: CFMutableDictionary
    private var previous: (samples: CFDictionary, time: Date)?

    public init?() {
        guard let channels = tm_IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0),
              let desired = CFDictionaryCreateMutableCopy(
                  kCFAllocatorDefault, CFDictionaryGetCount(channels), channels)
        else { return nil }

        var subscribedOut: Unmanaged<CFMutableDictionary>?
        guard let subscription = tm_IOReportCreateSubscription(nil, desired, &subscribedOut, 0, nil),
              let subscribed = subscribedOut?.takeRetainedValue()
        else { return nil }
        self.subscription = subscription
        self.subscribed = subscribed
    }

    /// Returns watts per channel name since the previous call (empty on the first call).
    public func sample() -> [String: Double] {
        guard let current = tm_IOReportCreateSamples(subscription, subscribed, nil) else { return [:] }
        let now = Date()
        defer { previous = (current, now) }
        guard let (prev, prevTime) = previous,
              let delta = tm_IOReportCreateSamplesDelta(prev, current, nil) else { return [:] }

        let seconds = now.timeIntervalSince(prevTime)
        guard seconds > 0,
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return [:] }

        var watts: [String: Double] = [:]
        for item in items {
            let channel = item as CFDictionary
            guard let name = tm_IOReportChannelGetChannelName(channel) as String? else { continue }
            let unit = (tm_IOReportChannelGetUnitLabel(channel) as String?)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let raw = Double(tm_IOReportSimpleGetIntegerValue(channel, 0))
            guard let joules = Self.toJoules(raw, unit: unit) else { continue }
            watts[name, default: 0] += joules / seconds
        }
        return watts
    }

    static func toJoules(_ value: Double, unit: String) -> Double? {
        switch unit {
        case "J": value
        case "mJ": value / 1e3
        case "uJ", "µJ": value / 1e6
        case "nJ": value / 1e9
        default: nil
        }
    }
}

/// Convenience view of the channels that matter for the thermal model.
public struct PowerBreakdown: Sendable {
    public let cpu: Double?
    public let gpu: Double?
    public let ane: Double?
    public let dram: Double?

    public init(_ watts: [String: Double]) {
        cpu = watts["CPU Energy"]
        gpu = watts["GPU Energy"] ?? watts["GPU"]
        ane = watts.first { $0.key.hasPrefix("ANE") }?.value
        dram = watts["DRAM"]
    }
}
