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

    var title: String {
        switch signal {
        case SIGKILL: "Forcer à quitter"
        case SIGSTOP: "Suspendre"
        case SIGCONT: "Reprendre"
        default: "Terminer"
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

    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpu, order: .reverse)]
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
        return treeMode ? treeRows(processes) : processes.filter(matches).sorted(using: sortOrder)
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
            for var node in nodes.filter({ kept.contains($0.pid) }).sorted(using: sortOrder) {
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
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Processus", value: \.name) { process in
                HStack(spacing: 6) {
                    if treeMode {
                        TreeDisclosure(process: process, isCollapsed: collapsed.contains(process.pid)) {
                            toggle(process.pid, recursive: NSEvent.modifierFlags.contains(.option))
                        }
                    }
                    ProcessIcon(path: process.path).frame(width: 16, height: 16)
                    Text(process.name).lineLimit(1)
                }
                .help(process.path ?? process.name)
            }
            .width(min: 160, ideal: 240)

            TableColumn("PID", value: \.pid) { process in
                Text(String(process.pid)).monospacedDigit()
            }
            .width(min: 50, ideal: 60)

            TableColumn("Utilisateur", value: \.user)
                .width(min: 70, ideal: 100)

            TableColumn("CPU %", value: \.cpu) { process in
                if process.restricted {
                    RestrictedValue()
                } else {
                    HStack(spacing: 6) {
                        Meter(fraction: process.cpu / 100, color: Palette.load(process.cpu / 100))
                            .frame(width: 34)
                        Text(String(format: "%.1f", process.cpu))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn("Mémoire", value: \.memory) { process in
                if process.restricted { RestrictedValue() } else {
                    Text(Format.bytes(process.memory))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn("Threads", value: \.threads) { process in
                if process.restricted { RestrictedValue() } else {
                    Text(String(process.threads))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 50, ideal: 60)

            TableColumn("E/S disque", value: \.diskRate) { process in
                if process.restricted { RestrictedValue() } else {
                    Text(process.diskRate > 0 ? Format.rate(process.diskRate) : "0")
                        .monospacedDigit()
                        .foregroundStyle(process.diskRate > 0 ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn("État", value: \.state)
                .width(min: 60, ideal: 70)
        }
        .contextMenu(forSelectionType: pid_t.self) { pids in
            if !pids.isEmpty {
                Button("Terminer") { pendingSignal = PendingSignal(signal: SIGTERM, pids: Array(pids)) }
                Button("Forcer à quitter") { pendingSignal = PendingSignal(signal: SIGKILL, pids: Array(pids)) }
                Divider()
                Button("Suspendre") { pendingSignal = PendingSignal(signal: SIGSTOP, pids: Array(pids)) }
                Button("Reprendre") { pendingSignal = PendingSignal(signal: SIGCONT, pids: Array(pids)) }
                Divider()
                let paths = pids.compactMap { monitor.process($0)?.path }
                Button("Afficher dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
                }
                .disabled(paths.isEmpty)
                if treeMode {
                    Divider()
                    Button("Tout développer") { collapsed.removeAll() }
                    Button("Tout réduire") {
                        collapsed = Set((monitor.snapshot?.processes ?? []).map(\.parentPID))
                    }
                }
                Divider()
                Button("Copier le PID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pids.map(String.init).sorted().joined(separator: " "),
                                                   forType: .string)
                }
            }
        }
        .onDeleteCommand {
            if !selection.isEmpty { pendingSignal = PendingSignal(signal: SIGTERM, pids: Array(selection)) }
        }
    }
}

/// Indentation et triangle de l'arborescence.
private struct TreeDisclosure: View {
    var process: ProcessSample
    var isCollapsed: Bool
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(process.treeDepth) * 14)
            if process.hasChildren {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Option-clic : toute la descendance")
            } else {
                Color.clear.frame(width: 14)
            }
        }
    }
}

private struct RestrictedValue: View {
    var body: some View {
        Text("–")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help("Processus d'un autre utilisateur : mesure réservée à l'administrateur")
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
                        let cpu = monitor.processCPUHistory[pid]?.values ?? []
                        GraphSection(title: "CPU", value: String(format: "%.1f %%", process.cpu)) {
                            AreaGraph(values: cpu, capacity: 60, gradient: Palette.load,
                                      maximum: max(100, cpu.max() ?? 0))
                        }
                        GraphSection(title: "Mémoire", value: Format.bytes(process.memory)) {
                            AreaGraph(values: monitor.processMemoryHistory[pid]?.values ?? [], capacity: 60,
                                      gradient: Palette.memory, maximum: nil)
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        InfoRow("État", process.state)
                        InfoRow("Parent") {
                            if let parent = monitor.process(process.parentPID) {
                                Button("\(parent.name) (\(String(parent.pid)))") { select(parent.pid) }
                                    .buttonStyle(.link)
                            } else {
                                Text(String(process.parentPID))
                            }
                        }
                        InfoRow("Lancé", process.startDate.formatted(date: .abbreviated, time: .shortened))
                        InfoRow("Durée", Format.duration(since: process.startDate))
                        InfoRow("Priorité (nice)", String(process.nice))
                        if !process.restricted {
                            InfoRow("Threads", String(process.threads))
                            InfoRow("Lecture disque", Format.rate(process.readRate))
                            InfoRow("Écriture disque", Format.rate(process.writeRate))
                        }
                    }
                    .font(.callout)

                    if let path = process.path {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exécutable").font(.callout).foregroundStyle(.secondary)
                            Text(path).font(.caption).textSelection(.enabled)
                            Button("Afficher dans le Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider()
                    HStack {
                        Button("Terminer") { pendingSignal = PendingSignal(signal: SIGTERM, pids: [pid]) }
                        Button("Forcer à quitter") { pendingSignal = PendingSignal(signal: SIGKILL, pids: [pid]) }
                    }
                    Button(process.state == "Suspendu" ? "Reprendre" : "Suspendre") {
                        pendingSignal = PendingSignal(
                            signal: process.state == "Suspendu" ? SIGCONT : SIGSTOP, pids: [pid])
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("Aucun processus", systemImage: "list.bullet.rectangle",
                                   description: Text("Sélectionnez un processus pour voir ses détails."))
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
