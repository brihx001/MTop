import Foundation
import IOKit
import IOKit.ps

struct BatterySample {
    var percent: Double
    var isCharging: Bool
    var onAC: Bool
    /// Minutes restantes (decharge) ou avant charge complete ; nil si inconnu.
    var minutesRemaining: Int?
}

enum HardwareSampler {
    static let chipName: String =
        Sysctl.string("machdep.cpu.brand_string") ?? Sysctl.string("hw.model") ?? "CPU"

    static let performanceCores = Int(Sysctl.value("hw.perflevel0.logicalcpu", Int32(0)) ?? 0)
    static let efficiencyCores = Int(Sysctl.value("hw.perflevel1.logicalcpu", Int32(0)) ?? 0)

    static var bootDate: Date? {
        guard let boot = Sysctl.value("kern.boottime", timeval()), boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }

    /// Taux d'occupation du GPU (0...1), publie par le pilote IOAccelerator.
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(
                    service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = property as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, value / 100)
        }
        return best
    }

    static func battery() -> BatterySample? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? description[kIOPSTimeToFullChargeKey]
                                    : description[kIOPSTimeToEmptyKey]) as? Int
            return BatterySample(
                percent: Double(current) / Double(maximum),
                isCharging: charging,
                onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }
}
