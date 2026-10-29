import Darwin

struct MemorySample {
    var total: UInt64
    /// Memoire des applications (pages anonymes hors purgeables).
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    /// Fichiers en cache et pages purgeables, recuperables a la demande.
    var cached: UInt64
    var free: UInt64
    var swapTotal: UInt64
    var swapUsed: UInt64
    /// 1 normal, 2 avertissement, 4 critique.
    var pressureLevel: Int32

    var used: UInt64 { app + wired + compressed }
}

/// Memes categories que le Moniteur d'activite.
enum MemorySampler {
    static let physical: UInt64 = Sysctl.value("hw.memsize", UInt64(0)) ?? 0

    static func sample() -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let swap = Sysctl.value("vm.swapusage", xsw_usage()) ?? xsw_usage()

        let app = internalPages > purgeable ? (internalPages - purgeable) * page : 0
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let used = app + wired + compressed
        let free = physical > used + cached ? physical - used - cached : 0

        return MemorySample(
            total: physical, app: app, wired: wired, compressed: compressed,
            cached: cached, free: free,
            swapTotal: swap.xsu_total, swapUsed: swap.xsu_used,
            pressureLevel: Sysctl.value("kern.memorystatus_vm_pressure_level", Int32(1)) ?? 1
        )
    }
}
