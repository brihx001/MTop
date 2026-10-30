import AppKit
import Combine
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
            CommandGroup(replacing: .appInfo) {
                Button("About MTop") { AboutPanel.show() }
            }
            // Dans le menu View standard de macOS, apres les commandes de la barre d'outils.
            CommandGroup(after: .toolbar) {
                Divider()
                Toggle("Process Tree", isOn: $treeMode)
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button(monitor.isPaused ? "Resume Sampling" : "Pause Sampling") {
                    monitor.isPaused.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Picker("Interval", selection: $monitor.interval) {
                    ForEach(SystemMonitor.intervals, id: \.self) { value in
                        Text(ContentView.intervalLabel(value)).tag(value)
                    }
                }
                Divider()
                Picker("Dock Icon", selection: $monitor.dockIconMode) {
                    ForEach(DockIconMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                        if mode == .application { Divider() }
                    }
                }
            }
        }
    }
}

/// Panneau « A propos » standard, complete par l'auteur, la date de
/// construction (cle MTopBuildDate, inscrite par build.sh) et la page du projet.
enum AboutPanel {
    static let author = "brihx001"
    static let authorURL = URL(string: "https://github.com/brihx001")!
    static let projectURL = URL(string: "https://github.com/brihx001/MTop")!

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        func link(_ text: String, _ url: URL) -> NSAttributedString {
            var attributes = base
            attributes[.link] = url
            return NSAttributedString(string: text, attributes: attributes)
        }

        let credits = NSMutableAttributedString(string: "By ", attributes: base)
        credits.append(link(author, authorURL))
        if let built = buildDate {
            credits.append(NSAttributedString(string: "\nBuilt \(Format.dateTime(built))",
                                              attributes: base))
        }
        credits.append(NSAttributedString(string: "\n", attributes: base))
        credits.append(link(projectURL.absoluteString.replacingOccurrences(of: "https://", with: ""), projectURL))

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var buildDate: Date? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MTopBuildDate") as? String else { return nil }
        return ISO8601DateFormatter().date(from: raw)
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
        .background(WindowSubtitle())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            monitor.isWindowVisible = NSApp.windows.contains {
                $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible)
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Name, PID, user")
        .inspector(isPresented: $showInspector) {
            ProcessInspector(pid: selection.count == 1 ? selection.first : nil,
                             pendingSignal: $pendingSignal,
                             select: { selection = [$0] })
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $treeMode) {
                    Label("Tree", systemImage: "list.bullet.indent")
                }
                .help("Show processes as a tree (⌥⌘T)")

                Toggle(isOn: $onlyMine) {
                    Label("My Processes", systemImage: "person")
                }
                .help("Show only my processes")

                Button {
                    pendingSignal = monitor.request(SIGTERM, pids: Array(selection))
                } label: {
                    Label("Quit", systemImage: "xmark.octagon")
                }
                .help("Quit the selected processes")
                .disabled(selection.isEmpty)

                Picker("Interval", selection: $monitor.interval) {
                    ForEach(SystemMonitor.intervals, id: \.self) { value in
                        Text(Self.intervalLabel(value)).tag(value)
                    }
                }
                .help("Sampling interval")

                Button {
                    monitor.isPaused.toggle()
                } label: {
                    Label(monitor.isPaused ? "Resume" : "Pause",
                          systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .help(monitor.isPaused ? "Resume Sampling" : "Pause Sampling")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show process details")
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } }
        ), presenting: pendingSignal) { pending in
            Button(pending.title, role: pending.signal == SIGCONT ? nil : .destructive) {
                errorMessage = monitor.send(pending)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.pids.compactMap { monitor.process($0)?.name }.joined(separator: ", "))
        }
        .alert("Couldn't Send the Signal", isPresented: Binding(
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
        return count == 1 ? "\(pending.title) this process?" : "\(pending.title) \(count) processes?"
    }

}

/// Sous-titre de la fenetre. Isole dans sa propre vue : lu dans ContentView, il
/// ferait reevaluer toute la fenetre, barre d'outils comprise, a chaque mesure.
private struct WindowSubtitle: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        Color.clear.navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let processes = monitor.snapshot?.processes else { return "" }
        let threads = processes.reduce(0) { $0 + Int($1.threads) }
        let paused = monitor.isPaused ? "Paused · " : ""
        return "\(paused)\(processes.count) processes · \(threads) threads"
    }
}
