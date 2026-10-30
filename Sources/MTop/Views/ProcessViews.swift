import AppKit
import SwiftUI

extension ProcessSample {
    var diskRate: Double { readRate + writeRate }
}

/// Signal en attente de confirmation.
struct PendingSignal: Identifiable {
    let id = UUID()
    var signal: Int32
    var pids: [pid_t]
    /// Date de lancement de chaque processus vise, relevee a la demande. Entre la
    /// demande et la confirmation, un processus peut quitter et son PID etre
    /// attribue a un autre : on verifie avant d'envoyer le signal.
    var startTimes: [pid_t: Int]

    var title: String {
        switch signal {
        case SIGKILL: "Force Quit"
        case SIGSTOP: "Suspend"
        case SIGCONT: "Resume"
        default: "Quit"
        }
    }
}

struct ProcessTableView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Binding var selection: Set<pid_t>
    @Binding var pendingSignal: PendingSignal?
    var searchText: String
    var onlyMine: Bool
    var treeMode: Bool

    @State private var sort = ProcessSort()
    /// Processus replies dans l'arborescence (tout est deplie par defaut).
    @State private var collapsed = Set<pid_t>()

    private func matches(_ process: ProcessSample) -> Bool {
        if onlyMine && process.uid != getuid() { return false }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return process.name.localizedCaseInsensitiveContains(query)
            || process.user.localizedCaseInsensitiveContains(query)
            || String(process.pid) == query
            || (process.path?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private var rows: [ProcessSample] {
        let processes = monitor.snapshot?.processes ?? []
        return treeMode ? treeRows(processes) : processes.filter(matches).sorted(using: sort.comparators)
    }

    /// Aplatit l'arbre parent/enfant en parcours en profondeur. Les freres sont
    /// tries selon les colonnes ; un filtre garde aussi les ancetres des
    /// processus retenus, pour qu'ils restent a leur place dans l'arbre.
    private func treeRows(_ processes: [ProcessSample]) -> [ProcessSample] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [pid_t: [ProcessSample]] = [:]
        var roots: [ProcessSample] = []
        for process in processes {
            // kernel_task (0) est son propre parent : il reste une racine.
            if process.parentPID != process.pid, byPID[process.parentPID] != nil, process.pid != 0 {
                children[process.parentPID, default: []].append(process)
            } else {
                roots.append(process)
            }
        }

        var kept = Set<pid_t>()
        for process in processes where matches(process) {
            var pid = process.pid
            while kept.insert(pid).inserted, let parent = byPID[pid]?.parentPID, parent != pid {
                pid = parent
            }
        }

        var result: [ProcessSample] = []
        result.reserveCapacity(kept.count)
        func visit(_ nodes: [ProcessSample], depth: Int) {
            for var node in nodes.filter({ kept.contains($0.pid) }).sorted(using: sort.comparators) {
                let descendants = (children[node.pid] ?? []).filter { kept.contains($0.pid) }
                node.treeDepth = depth
                node.hasChildren = !descendants.isEmpty
                result.append(node)
                if node.hasChildren && !collapsed.contains(node.pid) {
                    visit(descendants, depth: depth + 1)
                }
            }
        }
        visit(roots, depth: 0)
        return result
    }

    private func toggle(_ pid: pid_t, recursive: Bool) {
        let expand = collapsed.contains(pid)
        var targets: [pid_t] = [pid]
        if recursive {
            // Option-clic : applique le meme etat a toute la descendance, comme dans le Finder.
            let processes = monitor.snapshot?.processes ?? []
            var queue = [pid]
            while let current = queue.popLast() {
                let kids = processes.filter { $0.parentPID == current && $0.pid != current }.map(\.pid)
                targets += kids
                queue += kids
            }
        }
        for target in targets {
            if expand { collapsed.remove(target) } else { collapsed.insert(target) }
        }
    }

    var body: some View {
        ProcessTable(
            rows: rows, selection: $selection, sort: $sort, treeMode: treeMode, collapsed: collapsed,
            actions: ProcessTableActions(
                toggle: { toggle($0, recursive: $1) },
                signal: { pendingSignal = monitor.request($0, pids: $1) },
                expandAll: { collapsed.removeAll() },
                collapseAll: { collapsed = Set((monitor.snapshot?.processes ?? []).map(\.parentPID)) }))
    }
}

// MARK: - Inspecteur

struct ProcessInspector: View {
    @Environment(SystemMonitor.self) private var monitor
    var pid: pid_t?
    @Binding var pendingSignal: PendingSignal?
    var select: (pid_t) -> Void

    var body: some View {
        if let pid, let process = monitor.process(pid) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ProcessIcon(path: process.path).frame(width: 40, height: 40)
                        VStack(alignment: .leading) {
                            Text(process.name).font(.title3.weight(.semibold)).lineLimit(2)
                            Text("PID \(String(process.pid)) · \(process.user)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !process.restricted {
                        let history = monitor.processHistories[pid]
                        let cpu = history?.cpu.values ?? []
                        GraphSection(title: "CPU", value: String(format: "%.1f%%", process.cpu)) {
                            AreaGraph(values: cpu, capacity: 60, gradient: Palette.load,
                                      maximum: max(100, cpu.max() ?? 0))
                        }
                        GraphSection(title: "Memory", value: Format.bytes(process.memory)) {
                            AreaGraph(values: history?.memory.values ?? [], capacity: 60,
                                      gradient: Palette.memory, maximum: nil)
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        InfoRow("State", process.state)
                        InfoRow("Parent") {
                            if let parent = monitor.process(process.parentPID) {
                                Button("\(parent.name) (\(String(parent.pid)))") { select(parent.pid) }
                                    .buttonStyle(.link)
                            } else {
                                Text(String(process.parentPID))
                            }
                        }
                        InfoRow("Started", Format.dateTime(process.startDate))
                        InfoRow("Running time", Format.duration(since: process.startDate))
                        InfoRow("Priority (nice)", String(process.nice))
                        if !process.restricted {
                            InfoRow("Threads", String(process.threads))
                            InfoRow("Disk Reads", Format.rate(process.readRate))
                            InfoRow("Disk Writes", Format.rate(process.writeRate))
                        }
                    }
                    .font(.callout)

                    if let path = process.path {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Executable").font(.callout).foregroundStyle(.secondary)
                            Text(path).font(.caption).textSelection(.enabled)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider()
                    HStack {
                        Button("Quit") { pendingSignal = monitor.request(SIGTERM, pids: [pid]) }
                        Button("Force Quit") { pendingSignal = monitor.request(SIGKILL, pids: [pid]) }
                    }
                    Button(process.state == "Stopped" ? "Resume" : "Suspend") {
                        pendingSignal = monitor.request(process.state == "Stopped" ? SIGCONT : SIGSTOP, pids: [pid])
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No Process Selected", systemImage: "list.bullet.rectangle",
                                   description: Text("Select a process to see its details."))
        }
    }
}

private struct GraphSection<Graph: View>: View {
    var title: String
    var value: String
    @ViewBuilder var graph: Graph

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.callout)
            graph
                .frame(height: 60)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct InfoRow<Value: View>: View {
    var label: String
    var value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value
        }
    }
}

extension InfoRow where Value == Text {
    init(_ label: String, _ text: String) {
        self.init(label) { Text(text) }
    }
}
