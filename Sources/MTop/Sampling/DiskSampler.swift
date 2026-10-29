import Foundation
import IOKit

struct VolumeSample: Identifiable {
    var id: URL { url }
    var url: URL
    var name: String
    var total: Int64
    /// Espace strictement libre (celui de df).
    var free: Int64
    /// Espace que macOS libere a la demande : instantanes locaux, caches...
    var purgeable: Int64

    /// Ce qu'affiche le Finder : libre + purgeable.
    var available: Int64 { free + purgeable }
    var used: Int64 { max(total - available, 0) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var purgeableFraction: Double { total > 0 ? Double(purgeable) / Double(total) : 0 }
}

struct DiskSample {
    var volumes: [VolumeSample]
    /// Octets par seconde, tous disques confondus.
    var readRate: Double
    var writeRate: Double
}

final class DiskSampler {
    private var previousIO: (read: UInt64, write: UInt64)?
    private var cachedVolumes: [VolumeSample] = []
    private var lastVolumeRefresh = Date.distantPast

    func sample(elapsed: Double) -> DiskSample {
        let io = Self.readIOCounters()
        var readRate = 0.0, writeRate = 0.0
        if let before = previousIO, elapsed > 0, io.read >= before.read, io.write >= before.write {
            readRate = Double(io.read - before.read) / elapsed
            writeRate = Double(io.write - before.write) / elapsed
        }
        previousIO = io

        // L'occupation des volumes change lentement : inutile de l'interroger a chaque tick.
        if Date().timeIntervalSince(lastVolumeRefresh) > 5 {
            cachedVolumes = Self.readVolumes()
            lastVolumeRefresh = Date()
        }
        return DiskSample(volumes: cachedVolumes, readRate: readRate, writeRate: writeRate)
    }

    private static func readVolumes() -> [VolumeSample] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable ?? true,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let free = Int64(values.volumeAvailableCapacity ?? 0)
            // Certains systemes de fichiers (virtiofs, SMB...) renvoient 0 ici.
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            return VolumeSample(url: url, name: values.volumeName ?? url.lastPathComponent,
                                total: Int64(total), free: free, purgeable: max(important - free, 0))
        }
    }

    private static func readIOCounters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(
                    service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = property as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}
