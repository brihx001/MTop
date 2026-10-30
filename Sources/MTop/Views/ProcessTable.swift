import AppKit
import SwiftUI

/// Colonnes de la table des processus.
enum ProcessColumn: String, CaseIterable {
    case name, pid, user, cpu, memory, threads, disk, state

    var title: String {
        switch self {
        case .name: "Process"
        case .pid: "PID"
        case .user: "User"
        case .cpu: "CPU %"
        case .memory: "Memory"
        case .threads: "Threads"
        case .disk: "Disk I/O"
        case .state: "State"
        }
    }

    var widths: (min: CGFloat, ideal: CGFloat) {
        switch self {
        case .name: (160, 240)
        case .pid: (50, 60)
        case .user: (70, 100)
        case .cpu: (80, 100)
        case .memory: (70, 90)
        case .threads: (50, 60)
        case .disk: (70, 90)
        case .state: (60, 70)
        }
    }

    var isNumeric: Bool { [.pid, .cpu, .memory, .threads, .disk].contains(self) }

    /// Premier clic sur l'en-tete : texte en ordre alphabetique, mesures du plus grand au plus petit.
    var defaultAscending: Bool { [.name, .pid, .user, .state].contains(self) }

    func comparator(ascending: Bool) -> KeyPathComparator<ProcessSample> {
        let order: SortOrder = ascending ? .forward : .reverse
        return switch self {
        case .name: KeyPathComparator(\.name, order: order)
        case .pid: KeyPathComparator(\.pid, order: order)
        case .user: KeyPathComparator(\.user, order: order)
        case .cpu: KeyPathComparator(\.cpu, order: order)
        case .memory: KeyPathComparator(\.memory, order: order)
        case .threads: KeyPathComparator(\.threads, order: order)
        case .disk: KeyPathComparator(\.diskRate, order: order)
        case .state: KeyPathComparator(\.state, order: order)
        }
    }
}

struct ProcessSort: Equatable {
    var column: ProcessColumn = .cpu
    var ascending = false

    /// Departage par PID : a valeurs egales, l'ordre reste le meme d'une mesure a l'autre.
    var comparators: [KeyPathComparator<ProcessSample>] {
        [column.comparator(ascending: ascending), KeyPathComparator(\.pid)]
    }
}

/// Actions declenchees depuis la table, traitees par la vue SwiftUI.
struct ProcessTableActions {
    var toggle: (_ pid: pid_t, _ recursive: Bool) -> Void
    var signal: (_ signal: Int32, _ pids: [pid_t]) -> Void
    var expandAll: () -> Void
    var collapseAll: () -> Void
}

/// Table des processus en NSTableView native.
///
/// La Table de SwiftUI compare toutes les lignes a chaque mesure, anime les
/// deplacements et recalcule la hauteur de chaque ligne deplacee : pres de 10 %
/// d'un coeur pour 750 processus. Ici, chaque mesure recharge seulement les
/// lignes visibles, de hauteur fixe et sans animation.
struct ProcessTable: NSViewRepresentable {
    var rows: [ProcessSample]
    @Binding var selection: Set<pid_t>
    @Binding var sort: ProcessSort
    var treeMode: Bool
    var collapsed: Set<pid_t>
    var actions: ProcessTableActions

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyHandlingTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for column in ProcessColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.minWidth = column.widths.min
            tableColumn.width = column.widths.ideal
            tableColumn.resizingMask = .userResizingMask
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue,
                                                                   ascending: column.defaultAscending)
            if column.isNumeric { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        // Largeurs et ordre des colonnes memorises entre deux lancements.
        table.autosaveName = "ProcessTable"
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.onDelete = { [weak coordinator] in coordinator?.deleteSelection() }
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        coordinator.update(self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    /// La table prend l'espace propose. Sans cela, SwiftUI mesure la taille ideale
    /// de la vue AppKit a chaque mise a jour, ce qui force la mise en page de la table.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 600, height: 300))
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ProcessTable
        weak var table: NSTableView?
        private var rows: [ProcessSample] = []
        /// Vrai pendant les modifications faites par le code, pour ne pas les
        /// renvoyer a SwiftUI comme si l'utilisateur les avait faites.
        private var isSyncing = false

        init(_ parent: ProcessTable) { self.parent = parent }

        func update(_ parent: ProcessTable) {
            self.parent = parent
            guard let table else { return }
            isSyncing = true
            defer { isSyncing = false }

            let descriptors = [NSSortDescriptor(key: parent.sort.column.rawValue, ascending: parent.sort.ascending)]
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }

            // Les cellules ne dependent que de rows[ligne] : plutot que de recharger
            // la table (qui reconstruit chaque ligne visible), on reconfigure sur
            // place les cellules existantes. NSTableView ne demande de nouvelles
            // vues que pour les lignes ajoutees.
            let countChanged = rows.count != parent.rows.count
            rows = parent.rows
            if countChanged { table.noteNumberOfRowsChanged() }
            table.enumerateAvailableRowViews { rowView, row in
                guard row < rows.count else { return }
                for index in 0..<rowView.numberOfColumns {
                    if let cell = rowView.view(atColumn: index) as? NSView,
                       index < table.tableColumns.count {
                        configure(cell, column: table.tableColumns[index], row: row)
                    }
                }
            }

            var indexes = IndexSet()
            for (row, process) in rows.enumerated() where parent.selection.contains(process.pid) {
                indexes.insert(row)
            }
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
        }

        // MARK: Source de donnees

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count,
                  let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell: NSView = switch column {
            case .name: reuse(tableView, column, NameCell.init)
            case .cpu: reuse(tableView, column, CPUCell.init)
            default: reuse(tableView, column) { TextCell(alignment: column.isNumeric ? .right : .left) }
            }
            configure(cell, column: tableColumn, row: row)
            return cell
        }

        private func configure(_ cell: NSView, column tableColumn: NSTableColumn, row: Int) {
            guard let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue) else { return }
            let process = rows[row]
            switch cell {
            case let cell as NameCell:
                cell.configure(process, treeMode: parent.treeMode,
                               isCollapsed: parent.collapsed.contains(process.pid),
                               target: self, action: #selector(toggleDisclosure(_:)), row: row)
            case let cell as CPUCell:
                cell.configure(process)
            case let cell as TextCell:
                cell.configure(process, column: column)
            default:
                break
            }
        }

        private func reuse<Cell: NSView>(_ tableView: NSTableView, _ column: ProcessColumn,
                                         _ make: () -> Cell) -> Cell {
            let identifier = NSUserInterfaceItemIdentifier("cell." + column.rawValue)
            if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell { return cell }
            let cell = make()
            cell.identifier = identifier
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            row < rows.count ? rows[row].name : nil
        }

        // MARK: Interactions

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].pid : nil })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncing, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let column = ProcessColumn(rawValue: key) else { return }
            parent.sort = ProcessSort(column: column, ascending: descriptor.ascending)
        }

        @objc func toggleDisclosure(_ sender: NSButton) {
            guard sender.tag < rows.count else { return }
            parent.actions.toggle(rows[sender.tag].pid, NSEvent.modifierFlags.contains(.option))
        }

        func deleteSelection() {
            let pids = selectedPIDs()
            if !pids.isEmpty { parent.actions.signal(SIGTERM, pids) }
        }

        private func selectedPIDs() -> [pid_t] {
            table?.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].pid : nil } ?? []
        }

        /// Comme le Finder : un clic droit hors de la selection vise la seule ligne cliquee.
        private func menuTargets() -> [ProcessSample] {
            guard let table else { return [] }
            let clicked = table.clickedRow
            let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked)
                ? IndexSet(integer: clicked) : table.selectedRowIndexes
            return indexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let targets = menuTargets()
            guard !targets.isEmpty else { return }
            let pids = targets.map(\.pid)
            let actions = parent.actions

            menu.addItem(ClosureMenuItem("Quit") { actions.signal(SIGTERM, pids) })
            menu.addItem(ClosureMenuItem("Force Quit") { actions.signal(SIGKILL, pids) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Suspend") { actions.signal(SIGSTOP, pids) })
            menu.addItem(ClosureMenuItem("Resume") { actions.signal(SIGCONT, pids) })
            menu.addItem(.separator())
            let urls = targets.compactMap { $0.path.map(URL.init(fileURLWithPath:)) }
            let reveal = ClosureMenuItem("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            reveal.isEnabled = !urls.isEmpty
            menu.addItem(reveal)
            if parent.treeMode {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Expand All", action: actions.expandAll))
                menu.addItem(ClosureMenuItem("Collapse All", action: actions.collapseAll))
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pids.sorted().map(String.init).joined(separator: " "),
                                               forType: .string)
            })
        }
    }
}

// MARK: - Table et menus

/// Suppr (ou ⌘Suppr) demande de terminer la selection, comme onDeleteCommand.
final class KeyHandlingTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        if key == NSDeleteCharacter || key == NSBackspaceCharacter || key == NSDeleteFunctionKey {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

// MARK: - Cellules

/// Les cellules sont reconfigurees a chaque mesure : on ne touche une propriete
/// que si elle change, pour ne pas provoquer de redessin inutile.
private extension NSTextField {
    func setText(_ text: String) { if stringValue != text { stringValue = text } }
    func setColor(_ color: NSColor) { if textColor != color { textColor = color } }
}

private extension NSView {
    func setToolTip(_ text: String?) { if toolTip != text { toolTip = text } }
}


private enum CellStyle {
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let text = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let restrictedHelp = "Another user's process: only an administrator can read its usage"
    static let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    static let chevronRight = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
    static let chevronDown = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))

    static func label(alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    /// Centre verticalement une ligne de texte dans la cellule.
    static func textFrame(_ label: NSTextField, x: CGFloat, width: CGFloat, in bounds: NSRect) -> NSRect {
        let height = ceil(label.intrinsicContentSize.height)
        return NSRect(x: x, y: floor((bounds.height - height) / 2), width: max(width, 0), height: height)
    }
}

/// Nom du processus, avec indentation et triangle en arborescence.
private final class NameCell: NSTableCellView {
    private let disclosure = NSButton()
    private let icon = NSImageView()
    private let label = CellStyle.label(alignment: .left)
    private var depth = 0
    private var treeMode = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.toolTip = "Option-click: all descendants"
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = CellStyle.text
        [disclosure, icon, label].forEach(addSubview)
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ process: ProcessSample, treeMode: Bool, isCollapsed: Bool,
                   target: AnyObject, action: Selector, row: Int) {
        if treeMode != self.treeMode || process.treeDepth != depth { needsLayout = true }
        self.treeMode = treeMode
        depth = process.treeDepth
        disclosure.isHidden = !(treeMode && process.hasChildren)
        disclosure.image = isCollapsed ? CellStyle.chevronRight : CellStyle.chevronDown
        disclosure.target = target
        disclosure.action = action
        disclosure.tag = row

        // Reassigner la meme image relance son rendu par IconServices (avec acces
        // disque) : on ne la change que si le processus de la ligne a change.
        let image = IconCache.icon(forExecutable: process.path) ?? CellStyle.gear
        if icon.image !== image {
            icon.image = image
            icon.contentTintColor = image === CellStyle.gear ? .secondaryLabelColor : nil
        }
        label.setText(process.name)
        setToolTip(process.path ?? process.name)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 2
        if treeMode {
            x += CGFloat(depth) * 14
            disclosure.frame = NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14)
            x += 16
        }
        icon.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
        x += 22
        label.frame = CellStyle.textFrame(label, x: x, width: bounds.width - x - 2, in: bounds)
    }
}

/// Valeur textuelle ou numerique.
private final class TextCell: NSTableCellView {
    private let label: NSTextField

    init(alignment: NSTextAlignment) {
        label = CellStyle.label(alignment: alignment)
        super.init(frame: .zero)
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ process: ProcessSample, column: ProcessColumn) {
        let font = column.isNumeric ? CellStyle.digits : CellStyle.text
        if label.font != font { label.font = font }
        if process.restricted && [.memory, .threads, .disk].contains(column) {
            label.setText("–")
            label.setColor(.tertiaryLabelColor)
            setToolTip(CellStyle.restrictedHelp)
            return
        }
        setToolTip(nil)
        var color = NSColor.labelColor
        switch column {
        case .pid: label.setText(String(process.pid))
        case .user: label.setText(process.user)
        case .memory: label.setText(Format.bytes(process.memory))
        case .threads: label.setText(String(process.threads))
        case .disk:
            label.setText(process.diskRate > 0 ? Format.rate(process.diskRate) : "0")
            if process.diskRate == 0 { color = .secondaryLabelColor }
        case .state: label.setText(process.state)
        default: label.setText("")
        }
        label.setColor(color)
    }

    override func layout() {
        super.layout()
        label.frame = CellStyle.textFrame(label, x: 2, width: bounds.width - 4, in: bounds)
    }
}

/// Pourcentage CPU precede d'une jauge.
private final class CPUCell: NSTableCellView {
    private let meter = MeterView()
    private let label = CellStyle.label(alignment: .right)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = CellStyle.digits
        addSubview(meter)
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ process: ProcessSample) {
        meter.isHidden = process.restricted
        if process.restricted {
            label.setText("–")
            label.setColor(.tertiaryLabelColor)
            setToolTip(CellStyle.restrictedHelp)
        } else {
            label.setText(String(format: "%.1f", process.cpu))
            label.setColor(.labelColor)
            setToolTip(nil)
            meter.fraction = process.cpu / 100
        }
    }

    override func layout() {
        super.layout()
        meter.frame = NSRect(x: 2, y: (bounds.height - 6) / 2, width: 34, height: 6)
        label.frame = CellStyle.textFrame(label, x: 40, width: bounds.width - 42, in: bounds)
    }
}

private final class MeterView: NSView {
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.width * clamped, bounds.height)
        NSColor(Palette.load(clamped)).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
