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
        if values.isEmpty { values.reserveCapacity(capacity) }
        if values.count >= capacity { values.removeFirst(values.count - capacity + 1) }
        values.append(value)
    }
}

/// Historiques du tableau de bord.
struct SystemHistories {
    var cpu = History()
    var cores: [History] = []
    var memory = History()
    var gpu = History()
    var receive = History()
    var send = History()
    var read = History()
    var write = History()
}

/// Historique d'un processus ; `lastSeen` repere les processus disparus.
struct ProcessHistory {
    var cpu = History(capacity: 60)
    var memory = History(capacity: 60)
    var lastSeen = 0
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
            battery: battery(now))
    }

    private var cachedBattery: BatterySample?
    private var lastBatteryRead = Date.distantPast

    /// La batterie evolue lentement et IOPS interroge powerd : une lecture toutes les 10 s.
    private func battery(_ now: Date) -> BatterySample? {
        if now.timeIntervalSince(lastBatteryRead) >= 10 {
            cachedBattery = HardwareSampler.battery()
            lastBatteryRead = now
        }
        return cachedBattery
    }
}

@Observable
@MainActor
final class SystemMonitor {
    nonisolated static let historyLength = 120
    static let intervals: [Double] = [0.5, 1, 2, 3, 5]

    var interval: Double = SystemMonitor.validInterval(UserDefaults.standard.object(forKey: "interval")) {
        didSet {
            if !Self.intervals.contains(interval) { interval = Self.validInterval(interval) }
            UserDefaults.standard.set(interval, forKey: "interval")
        }
    }

    /// Une valeur de preferences corrompue (0, negative, NaN) ferait tourner la
    /// boucle de mesure a vide : on ne garde que les intervalles proposes.
    private static func validInterval(_ raw: Any?) -> Double {
        guard let value = raw as? Double, intervals.contains(value) else { return 1 }
        return value
    }
    var isPaused = false

    /// Icone du Dock animee ; mise a jour meme fenetre masquee.
    var dockIconMode = DockIconMode(rawValue: UserDefaults.standard.string(forKey: "dockIcon") ?? "")
        ?? .application {
        didSet {
            UserDefaults.standard.set(dockIconMode.rawValue, forKey: "dockIcon")
            dockIcon.mode = dockIconMode
            updateDockIcon()
        }
    }
    @ObservationIgnored private let dockIcon = DockIconController()

    /// Derniere mesure publiee vers l'interface.
    private(set) var snapshot: Snapshot?
    private(set) var histories = SystemHistories()

    var cpuHistory: History { histories.cpu }
    var coreHistories: [History] { histories.cores }
    var memoryHistory: History { histories.memory }
    var gpuHistory: History { histories.gpu }
    var receiveHistory: History { histories.receive }
    var sendHistory: History { histories.send }
    var readHistory: History { histories.read }
    var writeHistory: History { histories.write }

    /// Non observe : seul l'inspecteur le lit, et il se redessine deja a chaque
    /// nouvelle mesure. Modifie en place, sans recopie des tableaux.
    @ObservationIgnored private(set) var processHistories: [pid_t: ProcessHistory] = [:]
    @ObservationIgnored private var processIndex: [pid_t: Int] = [:]
    @ObservationIgnored private var tick = 0
    /// Nom de l'interface principale, relu a chaque mesure (et non a chaque affichage).
    @ObservationIgnored private var primaryInterfaceName: String?

    /// Fenetre masquee, reduite ou recouverte : on continue de mesurer pour que
    /// les historiques restent complets, mais rien n'est publie vers SwiftUI.
    /// C'est la mise a jour de la table des processus qui coute, pas la mesure.
    @ObservationIgnored var isWindowVisible = true {
        didSet { if isWindowVisible && !oldValue { publish() } }
    }
    @ObservationIgnored private var latest: Snapshot?
    @ObservationIgnored private var working = SystemHistories()

    /// Interface reseau suivie ; nil = choix automatique.
    var selectedInterface: String? {
        didSet {
            working.receive = History()
            working.send = History()
            publish()
        }
    }

    private let sampler = SystemSampler()
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        dockIcon.mode = dockIconMode
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
    var activeInterface: NetworkInterfaceSample? { activeInterface(in: snapshot) }

    private func activeInterface(in snapshot: Snapshot?) -> NetworkInterfaceSample? {
        guard let interfaces = snapshot?.interfaces, !interfaces.isEmpty else { return nil }
        for name in [selectedInterface, primaryInterfaceName].compactMap({ $0 }) {
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
        let isFirst = latest == nil
        latest = snapshot
        primaryInterfaceName = Self.primaryInterface()
        if !isFirst { record(snapshot) }
        if isWindowVisible { publish() }
        updateDockIcon()
    }

    private func updateDockIcon() {
        guard dockIconMode != .application, let latest else { return }
        dockIcon.update(DockIconContent.make(dockIconMode, snapshot: latest, histories: working,
                                             interface: activeInterface(in: latest)))
    }

    private func record(_ snapshot: Snapshot) {
        working.cpu.append(snapshot.cpu.total)
        if working.cores.count != snapshot.cpu.cores.count {
            working.cores = Array(repeating: History(capacity: 40), count: snapshot.cpu.cores.count)
        }
        for (index, load) in snapshot.cpu.cores.enumerated() { working.cores[index].append(load) }

        let memory = snapshot.memory
        working.memory.append(memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0)
        if let gpu = snapshot.gpu { working.gpu.append(gpu) }

        if let interface = activeInterface(in: snapshot) {
            working.receive.append(interface.receiveRate)
            working.send.append(interface.sendRate)
        }
        working.read.append(snapshot.disk.readRate)
        working.write.append(snapshot.disk.writeRate)

        tick &+= 1
        var live = 0
        for process in snapshot.processes where !process.restricted {
            processHistories[process.pid, default: ProcessHistory()].cpu.append(process.cpu)
            processHistories[process.pid]!.memory.append(Double(process.memory))
            processHistories[process.pid]!.lastSeen = tick
            live += 1
        }
        if processHistories.count > live {
            processHistories = processHistories.filter { $0.value.lastSeen == tick }
        }
    }

    /// Transmet la derniere mesure a l'interface.
    private func publish() {
        guard let latest else { return }
        var index: [pid_t: Int] = [:]
        index.reserveCapacity(latest.processes.count)
        for (position, process) in latest.processes.enumerated() { index[process.pid] = position }
        processIndex = index
        snapshot = latest
        histories = working
    }

    func process(_ pid: pid_t) -> ProcessSample? {
        guard let snapshot, let position = processIndex[pid],
              position < snapshot.processes.count else { return nil }
        let process = snapshot.processes[position]
        return process.pid == pid ? process : nil
    }

    /// Prepare un signal a confirmer, en relevant l'identite des processus vises.
    func request(_ signal: Int32, pids: [pid_t]) -> PendingSignal {
        var startTimes: [pid_t: Int] = [:]
        for pid in pids {
            if let process = process(pid) { startTimes[pid] = Int(process.startDate.timeIntervalSince1970) }
        }
        return PendingSignal(signal: signal, pids: pids, startTimes: startTimes)
    }

    /// Envoie un signal confirme ; renvoie un message d'erreur pour les processus
    /// refuses ou ignores.
    func send(_ pending: PendingSignal) -> String? {
        var failures: [String] = []
        for pid in pending.pids {
            let name = process(pid)?.name ?? String(pid)
            // kill(0) viserait tout le groupe de processus de MTop, kill(-n) un
            // autre groupe : seuls les PID strictement positifs sont acceptes.
            guard pid > 0 else {
                failures.append("\(name) (\(pid)) : ce processus ne peut pas recevoir de signal")
                continue
            }
            // Le processus a pu quitter depuis la demande, et son PID etre reattribue.
            guard let expected = pending.startTimes[pid],
                  ProcessSampler.startTime(of: pid) == expected else {
                failures.append("\(name) (\(pid)) : le processus n'existe plus, aucun signal envoyé")
                continue
            }
            if kill(pid, pending.signal) != 0 {
                failures.append("\(name) (\(pid)) : \(String(cString: strerror(errno)))")
            }
        }
        Task { await refresh() }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}
