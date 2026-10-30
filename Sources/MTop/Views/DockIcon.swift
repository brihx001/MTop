import AppKit

/// Contenu de l'icone du Dock, comme le menu Presentation > Icone du Dock du
/// Moniteur d'activite.
enum DockIconMode: String, CaseIterable, Identifiable {
    case application, cpu, gpu, memory, network, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: "Application Icon"
        case .cpu: "CPU Usage"
        case .gpu: "GPU Usage"
        case .memory: "Memory"
        case .network: "Network Activity"
        case .disk: "Disk Activity"
        }
    }
}

/// Ce que l'icone du Dock affiche pour une mesure.
struct DockIconContent {
    enum Graph {
        /// Une barre verticale par coeur, 0...1.
        case bars([Double])
        /// Historique 0...1.
        case history([Double], NSGradient)
        /// Deux historiques en miroir (reception en haut, envoi en bas), mis a l'echelle ensemble.
        case mirrored(up: [Double], down: [Double], upColor: NSColor, downColor: NSColor)
    }

    var graph: Graph
}

/// Met a jour l'icone du Dock. Elle reste animee fenetre masquee : c'est son
/// interet, comme pour le Moniteur d'activite.
@MainActor
final class DockIconController {
    private let view = DockIconView()

    var mode: DockIconMode = .application {
        didSet {
            guard mode != oldValue else { return }
            NSApp.dockTile.contentView = mode == .application ? nil : view
            NSApp.dockTile.display()
        }
    }

    func update(_ content: DockIconContent?) {
        guard mode != .application, let content else { return }
        view.content = content
        NSApp.dockTile.display()
    }
}

private enum DockColors {
    static let load = NSGradient(colors: [.systemGreen, .systemYellow, .systemOrange, .systemRed])!
    static let gpu = NSGradient(colors: [.systemIndigo, .systemPurple, .systemPink])!
    static let memory = NSGradient(colors: [.systemTeal, .systemBlue, .systemPurple])!
    static let pressureWarning = NSGradient(colors: [.systemYellow, .systemOrange])!
    static let pressureCritical = NSGradient(colors: [.systemOrange, .systemRed])!
}

private final class DockIconView: NSView {
    var content: DockIconContent?

    override func draw(_ dirtyRect: NSRect) {
        // Meme gabarit que l'icone de l'application : carre arrondi sombre de 80 %.
        let side = min(bounds.width, bounds.height)
        let tile = NSRect(x: bounds.midX - side * 0.4, y: bounds.midY - side * 0.4,
                          width: side * 0.8, height: side * 0.8)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: side * 0.18, yRadius: side * 0.18)
        NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.2, blue: 0.24, alpha: 1),
                   ending: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1))!
            .draw(in: tilePath, angle: -90)
        guard let content else { return }

        // Pas de legende : a la taille du Dock, le texte serait illisible.
        let inset = side * 0.08
        let graph = tile.insetBy(dx: inset, dy: inset)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: graph).addClip()
        switch content.graph {
        case .bars(let loads): drawBars(loads, in: graph)
        case .history(let values, let gradient): drawHistory(values, in: graph, gradient: gradient)
        case .mirrored(let up, let down, let upColor, let downColor):
            drawMirrored(up: up, down: down, upColor: upColor, downColor: downColor, in: graph)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBars(_ loads: [Double], in rect: NSRect) {
        guard !loads.isEmpty else { return }
        let gap = loads.count > 8 ? rect.width * 0.015 : rect.width * 0.03
        let width = (rect.width - gap * CGFloat(loads.count - 1)) / CGFloat(loads.count)
        for (index, load) in loads.enumerated() {
            let x = rect.minX + CGFloat(index) * (width + gap)
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(rect: NSRect(x: x, y: rect.minY, width: width, height: rect.height)).fill()
            let height = rect.height * CGFloat(min(max(load, 0), 1))
            guard height > 0 else { continue }
            // Le degrade couvre toute la hauteur : une barre basse reste verte.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: x, y: rect.minY, width: width, height: height)).addClip()
            DockColors.load.draw(in: NSRect(x: x, y: rect.minY, width: width, height: rect.height), angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func areaPath(_ values: [Double], in rect: NSRect, scale: Double, downward: Bool) -> NSBezierPath? {
        guard values.count > 1 else { return nil }
        let step = rect.width / CGFloat(values.count - 1)
        let baseline = downward ? rect.maxY : rect.minY
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: baseline))
        for (index, value) in values.enumerated() {
            let ratio = CGFloat(min(max(value / max(scale, 1e-9), 0), 1))
            let y = downward ? rect.maxY - rect.height * ratio : rect.minY + rect.height * ratio
            path.line(to: NSPoint(x: rect.minX + CGFloat(index) * step, y: y))
        }
        path.line(to: NSPoint(x: rect.maxX, y: baseline))
        path.close()
        return path
    }

    private func drawHistory(_ values: [Double], in rect: NSRect, gradient: NSGradient) {
        guard let path = areaPath(values, in: rect, scale: 1, downward: false) else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        gradient.draw(in: rect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMirrored(up: [Double], down: [Double], upColor: NSColor, downColor: NSColor,
                              in rect: NSRect) {
        let scale = max(up.max() ?? 0, down.max() ?? 0) * 1.1
        let half = rect.height / 2
        let top = NSRect(x: rect.minX, y: rect.minY + half, width: rect.width, height: half)
        let bottom = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: half)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)).fill()
        guard scale > 0 else { return }
        upColor.setFill()
        areaPath(up, in: top, scale: scale, downward: false)?.fill()
        downColor.setFill()
        areaPath(down, in: bottom, scale: scale, downward: true)?.fill()
    }
}

extension DockIconContent {
    /// Construit l'icone a partir de la derniere mesure et des historiques.
    static func make(_ mode: DockIconMode, snapshot: Snapshot, histories: SystemHistories) -> DockIconContent? {
        switch mode {
        case .application:
            return nil
        case .cpu:
            return DockIconContent(graph: .bars(snapshot.cpu.cores))
        case .gpu:
            return DockIconContent(graph: .history(histories.gpu.values, DockColors.gpu))
        case .memory:
            // Sans legende, la pression memoire se lit a la couleur de la courbe.
            let gradient: NSGradient = switch snapshot.memory.pressureLevel {
            case 4: DockColors.pressureCritical
            case 2: DockColors.pressureWarning
            default: DockColors.memory
            }
            return DockIconContent(graph: .history(histories.memory.values, gradient))
        case .network:
            return DockIconContent(graph: .mirrored(up: histories.receive.values, down: histories.send.values,
                                                    upColor: .systemBlue, downColor: .systemPurple))
        case .disk:
            return DockIconContent(graph: .mirrored(up: histories.read.values, down: histories.write.values,
                                                    upColor: .systemGreen, downColor: .systemRed))
        }
    }
}
