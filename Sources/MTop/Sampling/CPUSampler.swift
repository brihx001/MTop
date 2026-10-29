import Darwin

struct CPUSample {
    /// Charge par coeur, 0...1.
    var cores: [Double]
    var total: Double
    var user: Double
    var system: Double
    var loadAverage: (Double, Double, Double)
}

/// Lit les compteurs de ticks par coeur et en deduit la charge depuis la
/// lecture precedente.
final class CPUSampler {
    private struct Ticks { var user, system, idle, nice: UInt32 }
    private var previous: [Ticks] = []

    func sample() -> CPUSample {
        let current = Self.readTicks()
        defer { previous = current }

        var cores: [Double] = []
        var sumUser = 0.0, sumSystem = 0.0, sumAll = 0.0
        for (index, now) in current.enumerated() {
            guard index < previous.count else { cores.append(0); continue }
            let before = previous[index]
            // Les compteurs sont sur 32 bits et bouclent : soustraction modulaire.
            let user = Double(now.user &- before.user) + Double(now.nice &- before.nice)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let all = user + system + idle
            cores.append(all > 0 ? (user + system) / all : 0)
            sumUser += user; sumSystem += system; sumAll += all
        }

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        return CPUSample(
            cores: cores,
            total: sumAll > 0 ? (sumUser + sumSystem) / sumAll : 0,
            user: sumAll > 0 ? sumUser / sumAll : 0,
            system: sumAll > 0 ? sumSystem / sumAll : 0,
            loadAverage: (load[0], load[1], load[2])
        )
    }

    private static func readTicks() -> [Ticks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        func tick(_ cpu: Int, _ state: Int32) -> UInt32 {
            UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + Int(state)])
        }
        return (0..<Int(count)).map { cpu in
            Ticks(user: tick(cpu, CPU_STATE_USER), system: tick(cpu, CPU_STATE_SYSTEM),
                  idle: tick(cpu, CPU_STATE_IDLE), nice: tick(cpu, CPU_STATE_NICE))
        }
    }
}
