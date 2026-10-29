import Foundation
import Observation
import SystemConfiguration

/// Historique glissant de valeurs, la plus ancienne en premier.
struct History {
    var capacity: Int = SystemMonitor.historyLength
    private(set) var values: [Double] = []

    var last: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

struct Snapshot {
    var cpu: CPUSample
    var memory: MemorySample
    var interfaces: [NetworkInterfaceSample]
    var disk: DiskSample
    var processes: [ProcessSample]
    var gpu: Double?
    var battery: BatterySample?
}

/// Effectue les mesures hors du fil principal ; les echantillonneurs gardent
/// l'etat de la mesure precedente pour calculer des debits.
actor SystemSampler {
    private let cpu = CPUSampler()
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private let processes = ProcessSampler()
    private var lastSample: Date?

    func sample() -> Snapshot {
        let now = Date()
        let elapsed = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now
        return Snapshot(
            cpu: cpu.sample(),
            memory: MemorySampler.sample(),
            interfaces: network.sample(elapsed: elapsed),
            disk: disk.sample(elapsed: elapsed),
            processes: processes.sample(elapsed: elapsed),
            gpu: HardwareSampler.gpuUtilization(),
            battery: HardwareSampler.battery())
    }
}

@Observable
@MainActor
final class SystemMonitor {
    nonisolated static let historyLength = 120
    static let intervals: [Double] = [0.5, 1, 2, 3, 5]

    var interval: Double = UserDefaults.standard.object(forKey: "interval") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(interval, forKey: "interval") }
    }
    var isPaused = false

    private(set) var snapshot: Snapshot?

    private(set) var cpuHistory = History()
    private(set) var coreHistories: [History] = []
    private(set) var memoryHistory = History()
    private(set) var gpuHistory = History()
    private(set) var receiveHistory = History()
    private(set) var sendHistory = History()
    private(set) var readHistory = History()
    private(set) var writeHistory = History()
    private(set) var processCPUHistory: [pid_t: History] = [:]
    private(set) var processMemoryHistory: [pid_t: History] = [:]

    /// Interface reseau suivie ; nil = choix automatique.
    var selectedInterface: String? {
        didSet {
            receiveHistory = History()
            sendHistory = History()
        }
    }

    private let sampler = SystemSampler()
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPaused { await self.refresh() }
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    func refresh() async {
        let snapshot = await sampler.sample()
        apply(snapshot)
    }

    /// Interface affichee : celle choisie, sinon l'interface principale (route par
    /// defaut), sinon la plus active depuis le demarrage.
    var activeInterface: NetworkInterfaceSample? {
        guard let interfaces = snapshot?.interfaces, !interfaces.isEmpty else { return nil }
        for name in [selectedInterface, Self.primaryInterface()].compactMap({ $0 }) {
            if let match = interfaces.first(where: { $0.name == name }) { return match }
        }
        return interfaces.max { $0.totalReceived + $0.totalSent < $1.totalReceived + $1.totalSent }
    }

    private static func primaryInterface() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any],
               let name = value["PrimaryInterface"] as? String {
                return name
            }
        }
        return nil
    }

    private func apply(_ snapshot: Snapshot) {
        // Le premier echantillon ne contient pas de debits : on ne l'historise pas.
        let isFirst = self.snapshot == nil
        self.snapshot = snapshot
        guard !isFirst else { return }

        cpuHistory.append(snapshot.cpu.total)
        if coreHistories.count != snapshot.cpu.cores.count {
            coreHistories = Array(repeating: History(capacity: 40), count: snapshot.cpu.cores.count)
        }
        for (index, load) in snapshot.cpu.cores.enumerated() { coreHistories[index].append(load) }

        let memory = snapshot.memory
        memoryHistory.append(memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0)
        if let gpu = snapshot.gpu { gpuHistory.append(gpu) }

        if let interface = activeInterface {
            receiveHistory.append(interface.receiveRate)
            sendHistory.append(interface.sendRate)
        }
        readHistory.append(snapshot.disk.readRate)
        writeHistory.append(snapshot.disk.writeRate)

        var cpuHistories: [pid_t: History] = [:]
        var memoryHistories: [pid_t: History] = [:]
        cpuHistories.reserveCapacity(snapshot.processes.count)
        memoryHistories.reserveCapacity(snapshot.processes.count)
        for process in snapshot.processes where !process.restricted {
            var cpu = processCPUHistory[process.pid] ?? History(capacity: 60)
            cpu.append(process.cpu)
            cpuHistories[process.pid] = cpu
            var memory = processMemoryHistory[process.pid] ?? History(capacity: 60)
            memory.append(Double(process.memory))
            memoryHistories[process.pid] = memory
        }
        processCPUHistory = cpuHistories
        processMemoryHistory = memoryHistories
    }

    func process(_ pid: pid_t) -> ProcessSample? {
        snapshot?.processes.first { $0.pid == pid }
    }

    /// Envoie un signal ; renvoie un message d'erreur pour les processus refuses.
    func send(_ signal: Int32, to pids: [pid_t]) -> String? {
        var failures: [String] = []
        for pid in pids where kill(pid, signal) != 0 {
            let name = process(pid)?.name ?? String(pid)
            failures.append("\(name) (\(pid)) : \(String(cString: strerror(errno)))")
        }
        if !failures.isEmpty { return failures.joined(separator: "\n") }
        Task { await refresh() }
        return nil
    }
}
