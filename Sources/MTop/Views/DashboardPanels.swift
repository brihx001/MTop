import SwiftUI

struct DashboardView: View {
    var body: some View {
        VStack(spacing: 10) {
            CPUPanel()
                .frame(minHeight: 170)
            HStack(spacing: 10) {
                MemoryPanel()
                NetworkPanel()
                DiskPanel()
            }
            .frame(minHeight: 250)
        }
        .padding(10)
    }
}

// MARK: - CPU

struct CPUPanel: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let cpu = monitor.snapshot?.cpu
        Panel(title: "CPU", systemImage: "cpu") {
            HStack(spacing: 14) {
                Text(HardwareSampler.chipName)
                if HardwareSampler.performanceCores > 0 {
                    Text("\(HardwareSampler.performanceCores)P + \(HardwareSampler.efficiencyCores)E")
                }
                if let load = cpu?.loadAverage {
                    Text(String(format: "Load %.2f  %.2f  %.2f", load.0, load.1, load.2))
                        .monospacedDigit()
                }
                if let boot = HardwareSampler.bootDate {
                    Label(Format.duration(since: boot), systemImage: "clock")
                }
                BatteryLabel(battery: monitor.snapshot?.battery)
            }
        } content: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Format.percent(cpu?.total ?? 0))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Palette.load(cpu?.total ?? 0))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("User \(Format.percent(cpu?.user ?? 0))")
                            Text("System \(Format.percent(cpu?.system ?? 0))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        Spacer()
                        if let gpu = monitor.snapshot?.gpu {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("GPU \(Format.percent(gpu))").font(.caption).monospacedDigit()
                                AreaGraph(values: monitor.gpuHistory.values, capacity: 60,
                                          gradient: Palette.gpu, showsGrid: false)
                                    .frame(width: 90, height: 22)
                            }
                        }
                    }
                    AreaGraph(values: monitor.cpuHistory.values, capacity: SystemMonitor.historyLength,
                              gradient: Palette.load)
                        .frame(minHeight: 80)
                }
                .frame(minWidth: 280, maxWidth: .infinity)

                CoreGrid(loads: cpu?.cores ?? [], histories: monitor.coreHistories)
                    .frame(minWidth: 280, maxWidth: .infinity)
            }
        }
    }
}

private struct CoreGrid: View {
    var loads: [Double]
    var histories: [History]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                ForEach(loads.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Text("C\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .leading)
                        AreaGraph(values: index < histories.count ? histories[index].values : [],
                                  capacity: 40, gradient: Palette.load, showsGrid: false)
                            .frame(height: 16)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
                        Text(Format.percent(loads[index]))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.load(loads[index]))
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }
}

private struct BatteryLabel: View {
    var battery: BatterySample?

    var body: some View {
        if let battery {
            let level = Int((battery.percent * 100).rounded())
            let symbol = battery.isCharging ? "battery.100percent.bolt"
                : level > 75 ? "battery.100percent" : level > 50 ? "battery.75percent"
                : level > 25 ? "battery.50percent" : level > 10 ? "battery.25percent" : "battery.0percent"
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text("\(level)%").monospacedDigit()
                if let minutes = battery.minutesRemaining {
                    Text(String(format: "%dh%02d", minutes / 60, minutes % 60)).monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Memoire

struct MemoryPanel: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let memory = monitor.snapshot?.memory
        Panel(title: "Memory", systemImage: "memorychip") {
            if let memory { PressureBadge(level: memory.pressureLevel) }
        } content: {
            if let memory {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Format.bytes(memory.used))
                            .font(.title2.weight(.semibold))
                        Text("of \(Format.bytes(memory.total))").foregroundStyle(.secondary)
                    }
                    AreaGraph(values: monitor.memoryHistory.values, capacity: SystemMonitor.historyLength,
                              gradient: Palette.memory)
                        .frame(minHeight: 24, maxHeight: 60)
                    MemoryRow(label: "App Memory", value: memory.app, total: memory.total, color: .blue)
                    MemoryRow(label: "Wired", value: memory.wired, total: memory.total, color: .orange)
                    MemoryRow(label: "Compressed", value: memory.compressed, total: memory.total, color: .purple)
                    MemoryRow(label: "Cached", value: memory.cached, total: memory.total, color: .teal)
                    MemoryRow(label: "Free", value: memory.free, total: memory.total, color: .green)
                    if memory.swapTotal > 0 {
                        MemoryRow(label: "Swap", value: memory.swapUsed, total: memory.swapTotal, color: .red)
                    }
                }
            }
        }
    }
}

private struct MemoryRow: View {
    var label: String
    var value: UInt64
    var total: UInt64
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 92, alignment: .leading)
            Meter(fraction: total > 0 ? Double(value) / Double(total) : 0, color: color)
            Text(Format.bytes(value))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .font(.callout)
    }
}

private struct PressureBadge: View {
    var level: Int32

    var body: some View {
        let (text, color): (String, Color) = switch level {
        case 4: ("Critical pressure", .red)
        case 2: ("High pressure", .orange)
        default: ("Normal pressure", .green)
        }
        Label(text, systemImage: "circle.fill")
            .labelStyle(PressureLabelStyle(color: color))
    }

    private struct PressureLabelStyle: LabelStyle {
        var color: Color
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.foregroundStyle(color).font(.system(size: 7))
                configuration.title
            }
        }
    }
}

// MARK: - Reseau

struct NetworkPanel: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        let interface = monitor.activeInterface
        Panel(title: "Network", systemImage: "network") {
            Picker("Interface", selection: $monitor.selectedInterface) {
                Text("Automatic").tag(String?.none)
                Divider()
                ForEach(monitor.snapshot?.interfaces ?? []) { interface in
                    Text(interface.name).tag(String?.some(interface.name))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                RateHeader(symbol: "arrow.down", color: .blue, title: "Receive",
                           rate: interface?.receiveRate ?? 0, peak: monitor.receiveHistory.peak,
                           total: interface?.totalReceived ?? 0)
                AreaGraph(values: monitor.receiveHistory.values, capacity: SystemMonitor.historyLength,
                          gradient: Palette.download, maximum: nil)
                AreaGraph(values: monitor.sendHistory.values, capacity: SystemMonitor.historyLength,
                          gradient: Palette.upload, maximum: nil, inverted: true)
                RateHeader(symbol: "arrow.up", color: .purple, title: "Send",
                           rate: interface?.sendRate ?? 0, peak: monitor.sendHistory.peak,
                           total: interface?.totalSent ?? 0)
            }
        }
    }
}

private struct RateHeader: View {
    var symbol: String
    var color: Color
    var title: String
    var rate: Double
    var peak: Double
    var total: UInt64

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).fontWeight(.bold)
            Text(Format.rate(rate)).fontWeight(.semibold).monospacedDigit()
            Spacer()
            Text("max \(Format.rate(peak))  ·  total \(Format.bytes(total, style: .decimal))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .help(title)
    }
}

// MARK: - Disques

struct DiskPanel: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let disk = monitor.snapshot?.disk
        Panel(title: "Disks", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    IOGraph(symbol: "arrow.down.doc", title: "Read", rate: disk?.readRate ?? 0,
                            values: monitor.readHistory.values, gradient: Palette.read)
                    IOGraph(symbol: "square.and.pencil", title: "Write", rate: disk?.writeRate ?? 0,
                            values: monitor.writeHistory.values, gradient: Palette.write)
                }
                .frame(minHeight: 50, maxHeight: 70)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(disk?.volumes ?? []) { volume in
                            VolumeRow(volume: volume)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

private struct IOGraph: View {
    var symbol: String
    var title: String
    var rate: Double
    var values: [Double]
    var gradient: Gradient

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(Format.rate(rate)).monospacedDigit()
            }
            .font(.callout)
            .help(title)
            AreaGraph(values: values, capacity: 60, gradient: gradient, maximum: nil)
        }
    }
}

private struct VolumeRow: View {
    var volume: VolumeSample

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: volume.url.path == "/" ? "internaldrive.fill" : "externaldrive")
                    .foregroundStyle(.secondary)
                Text(volume.name).lineLimit(1)
                Spacer()
                Text("\(Format.bytes(volume.available, style: .file)) available")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            VolumeMeter(volume: volume)
                .help(details)
        }
    }
}

extension VolumeRow {
    fileprivate var details: String {
        var lines = ["\(Format.bytes(volume.used, style: .file)) used of \(Format.bytes(volume.total, style: .file))",
                     "\(Format.bytes(volume.free, style: .file)) free"]
        if volume.purgeable > 0 {
            lines.append("\(Format.bytes(volume.purgeable, style: .file)) purgeable (freed by macOS when needed)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Barre d'occupation : utilise en couleur, purgeable en teinte claire.
private struct VolumeMeter: View {
    var volume: VolumeSample

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let used = width * CGFloat(min(max(volume.fraction, 0), 1))
            let purgeable = width * CGFloat(min(max(volume.purgeableFraction, 0), 1 - volume.fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: used + purgeable)
                Capsule()
                    .fill(Palette.load(volume.fraction).gradient)
                    .frame(width: used)
            }
        }
        .frame(height: 6)
    }
}
