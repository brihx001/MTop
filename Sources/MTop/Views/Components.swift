import AppKit
import SwiftUI

enum Format {
    private static func formatter(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        // Sinon 0 s'affiche « Zero ko ».
        formatter.allowsNonnumericFormatting = false
        return formatter
    }
    private static let memoryFormatter = formatter(.memory)
    private static let fileFormatter = formatter(.file)
    private static let decimalFormatter = formatter(.decimal)

    static func bytes(_ value: some BinaryInteger, style: ByteCountFormatter.CountStyle = .memory) -> String {
        let formatter = switch style {
        case .file: fileFormatter
        case .decimal: decimalFormatter
        default: memoryFormatter
        }
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        decimalFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f %%", fraction * 100)
    }

    static func duration(since date: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: date, to: Date()) ?? ""
    }
}

/// Degrade facon btop : vert au repos, jaune puis rouge en charge.
enum Palette {
    static let load = Gradient(colors: [.green, .yellow, .orange, .red])
    static let memory = Gradient(colors: [.teal, .blue, .purple])
    static let download = Gradient(colors: [.cyan.opacity(0.6), .blue])
    static let upload = Gradient(colors: [.pink.opacity(0.6), .purple])
    static let read = Gradient(colors: [.mint.opacity(0.6), .green])
    static let write = Gradient(colors: [.orange.opacity(0.6), .red])
    static let gpu = Gradient(colors: [.indigo.opacity(0.6), .purple, .pink])

    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.5: .green
        case ..<0.75: .yellow
        case ..<0.9: .orange
        default: .red
        }
    }
}

/// Courbe d'historique remplie d'un degre vertical, les valeurs recentes a droite.
struct AreaGraph: View {
    var values: [Double]
    var capacity: Int
    var gradient: Gradient
    /// Valeur du haut du graphe ; nil = mise a l'echelle automatique.
    var maximum: Double? = 1
    var inverted = false
    var showsGrid = true

    var body: some View {
        Canvas { context, size in
            if showsGrid {
                var grid = Path()
                for step in 1..<4 {
                    let y = size.height * CGFloat(step) / 4
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            }
            guard values.count > 1, capacity > 1 else { return }

            let top = max(maximum ?? (values.max() ?? 0) * 1.1, 1e-9)
            let step = size.width / CGFloat(capacity - 1)
            let start = CGFloat(capacity - values.count) * step
            func point(_ index: Int, _ value: Double) -> CGPoint {
                let ratio = CGFloat(min(max(value / top, 0), 1))
                let y = inverted ? size.height * ratio : size.height * (1 - ratio)
                return CGPoint(x: start + CGFloat(index) * step, y: y)
            }
            let baseline: CGFloat = inverted ? 0 : size.height

            var line = Path()
            for (index, value) in values.enumerated() {
                index == 0 ? line.move(to: point(index, value)) : line.addLine(to: point(index, value))
            }
            var area = line
            area.addLine(to: CGPoint(x: start + CGFloat(values.count - 1) * step, y: baseline))
            area.addLine(to: CGPoint(x: start, y: baseline))
            area.closeSubpath()

            let from = CGPoint(x: 0, y: baseline)
            let to = CGPoint(x: 0, y: inverted ? size.height : 0)
            context.fill(area, with: .linearGradient(gradient, startPoint: from, endPoint: to))
            context.opacity = 0.9
            context.stroke(line, with: .linearGradient(gradient, startPoint: from, endPoint: to), lineWidth: 1.2)
        }
        .drawingGroup()
    }
}

/// Barre horizontale de remplissage.
struct Meter: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(proxy.size.width * CGFloat(min(max(fraction, 0), 1)), 0))
            }
        }
        .frame(height: 6)
    }
}

/// Cadre d'un panneau du tableau de bord.
struct Panel<Content: View, Accessory: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer(minLength: 8)
                accessory
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}

/// Icones d'applications, mises en cache par chemin de bundle.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forExecutable path: String?) -> NSImage? {
        // Bundle le plus externe : les « Helper » imbriques n'ont souvent pas d'icone.
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        if let cached = icons[bundle] { return cached }
        let image = NSWorkspace.shared.icon(forFile: bundle)
        icons[bundle] = image
        return image
    }
}

struct ProcessIcon: View {
    var path: String?

    var body: some View {
        if let image = IconCache.icon(forExecutable: path) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "gearshape")
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(.secondary)
        }
    }
}
