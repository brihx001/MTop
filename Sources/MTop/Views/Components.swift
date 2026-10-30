import AppKit
import SwiftUI

/// Formatage en anglais, quelle que soit la langue du Mac : les formateurs de
/// Foundation suivent la langue du systeme (« Go », « 2j », virgule decimale).
enum Format {
    enum ByteStyle { case memory, file, decimal }

    private static let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]

    /// Comme ByteCountFormatter en anglais : « 812 KB », « 13.1 MB », « 2.94 GB ».
    /// La memoire compte en puissances de 1024, les disques et debits en 1000.
    static func bytes(_ value: some BinaryInteger, style: ByteStyle = .memory) -> String {
        let base = style == .memory ? 1024.0 : 1000.0
        var amount = Double(Int64(clamping: value))
        var unit = 0
        while abs(amount) >= base, unit < units.count - 1 {
            amount /= base
            unit += 1
        }
        switch unit {
        case 0: return "\(Int(amount)) bytes"
        case 1: return String(format: "%.0f %@", amount, units[unit])
        case 2: return String(format: "%.1f %@", amount, units[unit])
        default: return String(format: "%.2f %@", amount, units[unit])
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond.isFinite ? bytesPerSecond : 0), style: .decimal) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    /// « 2d 19h 11m », sans les unites de tete nulles.
    static func duration(since date: Date) -> String {
        let minutes = max(Int(Date().timeIntervalSince(date)) / 60, 0)
        let days = minutes / 1440, hours = minutes / 60 % 24, rest = minutes % 60
        if days > 0 { return "\(days)d \(hours)h \(rest)m" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return "\(rest)m"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// « Oct 30, 2026 at 8:44 AM ».
    static func dateTime(_ date: Date) -> String {
        dateFormatter.string(from: date)
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
        let image = rasterized(NSWorkspace.shared.icon(forFile: bundle))
        icons[bundle] = image
        return image
    }

    /// L'icone du Finder est rendue par IconServices a chaque affectation a une
    /// vue, avec acces disque. La table en change a chaque tri : on la fige une
    /// fois pour toutes en bitmap 16 pt (32 px pour les ecrans Retina).
    private static func rasterized(_ icon: NSImage) -> NSImage {
        let pixels = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Le contexte d'un bitmap travaille en pixels.
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
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
