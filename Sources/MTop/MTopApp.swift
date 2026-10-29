import AppKit
import SwiftUI

@main
struct MTopApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var monitor = SystemMonitor()
    @AppStorage("treeMode") private var treeMode = false

    var body: some Scene {
        Window("MTop", id: "main") {
            ContentView()
                .environment(monitor)
                .frame(minWidth: 900, minHeight: 700)
                .task { monitor.start() }
        }
        .defaultSize(width: 1280, height: 900)
        .commands {
            CommandMenu("Affichage") {
                Toggle("Arborescence des processus", isOn: $treeMode)
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button(monitor.isPaused ? "Reprendre les mesures" : "Suspendre les mesures") {
                    monitor.isPaused.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Picker("Intervalle", selection: $monitor.interval) {
                    ForEach(SystemMonitor.intervals, id: \.self) { value in
                        Text(ContentView.intervalLabel(value)).tag(value)
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var selection = Set<pid_t>()
    @State private var searchText = ""
    @AppStorage("onlyMine") private var onlyMine = false
    @AppStorage("treeMode") private var treeMode = false
    @AppStorage("showInspector") private var showInspector = true
    @State private var pendingSignal: PendingSignal?
    @State private var errorMessage: String?

    static func intervalLabel(_ value: Double) -> String {
        value < 1 ? "\(Int(value * 1000)) ms" : "\(Int(value)) s"
    }

    var body: some View {
        @Bindable var monitor = monitor
        VSplitView {
            DashboardView()
                .frame(minHeight: 450, idealHeight: 500)
            ProcessTableView(selection: $selection, pendingSignal: $pendingSignal,
                             searchText: searchText, onlyMine: onlyMine, treeMode: treeMode)
                .frame(minHeight: 180)
        }
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Nom, PID, utilisateur")
        .inspector(isPresented: $showInspector) {
            ProcessInspector(pid: selection.count == 1 ? selection.first : nil,
                             pendingSignal: $pendingSignal,
                             select: { selection = [$0] })
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $treeMode) {
                    Label("Arborescence", systemImage: "list.bullet.indent")
                }
                .help("Afficher les processus en arborescence (⌥⌘T)")

                Toggle(isOn: $onlyMine) {
                    Label("Mes processus", systemImage: "person")
                }
                .help("N'afficher que mes processus")

                Button {
                    pendingSignal = PendingSignal(signal: SIGTERM, pids: Array(selection))
                } label: {
                    Label("Terminer", systemImage: "xmark.octagon")
                }
                .help("Terminer les processus sélectionnés")
                .disabled(selection.isEmpty)

                Picker("Intervalle", selection: $monitor.interval) {
                    ForEach(SystemMonitor.intervals, id: \.self) { value in
                        Text(Self.intervalLabel(value)).tag(value)
                    }
                }
                .help("Intervalle de mesure")

                Button {
                    monitor.isPaused.toggle()
                } label: {
                    Label(monitor.isPaused ? "Reprendre" : "Pause",
                          systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .help(monitor.isPaused ? "Reprendre les mesures" : "Suspendre les mesures")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Détails", systemImage: "sidebar.trailing")
                }
                .help("Afficher les détails du processus")
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } }
        ), presenting: pendingSignal) { pending in
            Button(pending.title, role: pending.signal == SIGCONT ? nil : .destructive) {
                errorMessage = monitor.send(pending.signal, to: pending.pids)
            }
            Button("Annuler", role: .cancel) {}
        } message: { pending in
            Text(pending.pids.compactMap { monitor.process($0)?.name }.joined(separator: ", "))
        }
        .alert("Action impossible", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var confirmationTitle: String {
        guard let pending = pendingSignal else { return "" }
        let count = pending.pids.count
        return count == 1 ? "\(pending.title) ce processus ?" : "\(pending.title) \(count) processus ?"
    }

    private var subtitle: String {
        guard let processes = monitor.snapshot?.processes else { return "" }
        let threads = processes.reduce(0) { $0 + Int($1.threads) }
        let paused = monitor.isPaused ? "En pause · " : ""
        return "\(paused)\(processes.count) processus · \(threads) threads"
    }
}
