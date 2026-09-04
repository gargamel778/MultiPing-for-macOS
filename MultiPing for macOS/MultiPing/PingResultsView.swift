import AppKit
import Combine
import SwiftUI

enum ResultStatusPalette {
    static let green = Color(red: 0.24, green: 0.56, blue: 0.38)
    static let red = Color(red: 0.72, green: 0.28, blue: 0.24)
    static let orange = Color(red: 0.72, green: 0.50, blue: 0.22)

    static let nsGreen = NSColor(calibratedRed: 0.24, green: 0.56, blue: 0.38, alpha: 1.0)
    static let nsRed = NSColor(calibratedRed: 0.72, green: 0.28, blue: 0.24, alpha: 1.0)
    static let nsOrange = NSColor(calibratedRed: 0.72, green: 0.50, blue: 0.22, alpha: 1.0)

    static func isInactive(_ responseTime: String) -> Bool {
        ["pending", "pinging...", "paused", "stopped", "cleared", "cancelled", "engine unavailable", "restarting engine..."].contains(responseTime.lowercased())
    }

    static func swiftColor(for result: PingResult) -> Color {
        isInactive(result.responseTime) ? orange : (result.isSuccessful ? green : red)
    }

    static func nsColor(for result: PingResult) -> NSColor {
        isInactive(result.responseTime) ? nsOrange : (result.isSuccessful ? nsGreen : nsRed)
    }
}

struct PingResultsContainerView: View {
    @ObservedObject var manager: PingManager
    @State private var viewMode: ResultsViewMode
    @State private var filterText: String = ""
    @State private var selectedResultIDs: Set<UUID> = []
    @AppStorage("EmbeddedGraphHeightV1") private var embeddedGraphHeight: Double = 250
    @AppStorage("LatencyGraphEmbeddedCollapsedV1") private var embeddedCollapsed: Bool = false
    @State private var dragStartHeight: Double? = nil

    init(manager: PingManager, initialMode: ResultsViewMode) {
        self.manager = manager
        self._viewMode = State(initialValue: initialMode)
    }

    /// The target whose graph the embedded quick-view shows: the primary (first)
    /// selection, or the first target as a sensible default.
    private var primarySelected: PingResult? {
        manager.results.first { selectedResultIDs.contains($0.id) } ?? manager.results.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if viewMode == .list {
                    PingResultsView(manager: manager, viewMode: $viewMode, filterText: $filterText, selectedResultIDs: $selectedResultIDs)
                } else {
                    GridPingResultsView(manager: manager, viewMode: $viewMode, filterText: $filterText, selectedResultIDs: $selectedResultIDs)
                }
            }

            if let selected = primarySelected {
                Divider()
                if !embeddedCollapsed { resizeHandle }
                EmbeddedLatencyGraphView(result: selected, graphBodyHeight: CGFloat(embeddedGraphHeight))
            }
        }
        .onAppear {
            if selectedResultIDs.isEmpty, let first = manager.results.first?.id {
                selectedResultIDs = [first]
            }
        }
        .onChange(of: manager.results.map(\.id)) { newIDs in
            let pruned = selectedResultIDs.intersection(Set(newIDs))
            if pruned.isEmpty {
                selectedResultIDs = newIDs.first.map { [$0] } ?? []
            } else if pruned != selectedResultIDs {
                selectedResultIDs = pruned
            }
        }
    }

    /// Draggable divider above the embedded graph so the pane can be resized.
    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.10))
            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.55)).frame(width: 46, height: 4)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = embeddedGraphHeight }
                    let proposed = (dragStartHeight ?? embeddedGraphHeight) - Double(value.translation.height)
                    embeddedGraphHeight = min(520, max(150, proposed))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
        .help("Drag to resize the graph")
    }
}

// List View - Refactored to use PingManager for logic
struct PingResultsView: View {
    // MARK: - Properties
    @ObservedObject var manager: PingManager
    @Binding var viewMode: ResultsViewMode
    @Binding var filterText: String
    @Binding var selectedResultIDs: Set<UUID>

    // MARK: - UI State
    @State private var sortColumn: SortColumn? = nil
    @State private var sortAscending: Bool = true
    @State private var listScale: CGFloat = 1.0
    private let minScale: CGFloat = 0.7
    private let maxScale: CGFloat = 1.5
    private let scaleStep: CGFloat = 0.1

    // MARK: - Sorting Enum
    enum SortColumn: String, CaseIterable, Equatable {
        case targetValue = "Target"
        case current = "Current"
        case average = "Average"
        case minimum = "Minimum"
        case maximum = "Maximum"
        case success = "Success"
        case failures = "Failures"
        case failRate = "Fail Rate"

        var tableKey: String {
            switch self {
            case .targetValue: return "target"
            case .current: return "current"
            case .average: return "average"
            case .minimum: return "minimum"
            case .maximum: return "maximum"
            case .success: return "success"
            case .failures: return "failures"
            case .failRate: return "failRate"
            }
        }

        init?(tableKey: String) {
            switch tableKey {
            case "target": self = .targetValue
            case "current": self = .current
            case "average": self = .average
            case "minimum": self = .minimum
            case "maximum": self = .maximum
            case "success": self = .success
            case "failures": self = .failures
            case "failRate": self = .failRate
            default: return nil
            }
        }
    }

    // MARK: - Computed Sorted Results
    var sortedResults: [PingResult] {
        sort(results: filteredResults, by: sortColumn, ascending: sortAscending)
    }

    private var filteredResults: [PingResult] {
        filter(results: manager.results, by: filterText)
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            ResultsFilterBar(filterText: $filterText, shownCount: sortedResults.count, totalCount: manager.results.count)

            if manager.results.isEmpty {
                Spacer()
                Text("No targets to display.")
                    .foregroundColor(.gray)
                Spacer()
            } else if sortedResults.isEmpty {
                Spacer()
                Text("No targets match the current filter.")
                    .foregroundColor(.gray)
                Spacer()
            } else {
                ListResultsTableView(
                    results: sortedResults,
                    manager: manager,
                    sortColumn: $sortColumn,
                    sortAscending: $sortAscending,
                    scale: listScale,
                    selectedResultIDs: $selectedResultIDs
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let engineError = manager.engineErrorMessage {
                Text(engineError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.08))
            }

            ResultsStatusBar(manager: manager)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                let isEffectivelyRunning = manager.pingStatus == "Pinging..." || manager.pingStatus == "Paused"

                Button {
                    if isEffectivelyRunning {
                        manager.stopPingTasks(clearResults: true)
                    } else {
                        manager.startPingTasks(timeout: manager.timeout, interval: manager.interval, size: manager.packetSize, dscp: manager.dscp)
                    }
                } label: {
                    Label(isEffectivelyRunning ? "Stop & Clear" : "Start Ping",
                          systemImage: isEffectivelyRunning ? "stop.circle.fill" : "play.circle.fill")
                }
                .help(isEffectivelyRunning ? "Stop & Clear" : "Start Ping")
                .tint(isEffectivelyRunning ? ResultStatusPalette.red : ResultStatusPalette.green)

                Button {
                    manager.togglePause()
                } label: {
                    Label(manager.isPaused ? "Resume" : "Pause",
                          systemImage: manager.isPaused ? "play.circle.fill" : "pause.circle.fill")
                }
                .help(manager.isPaused ? "Resume" : "Pause")
                .tint(ResultStatusPalette.orange)
                .disabled(!(manager.pingStatus == "Pinging..." || manager.pingStatus == "Paused"))

                Button {
                    viewMode = .grid
                } label: {
                    Label("Grid Layout", systemImage: "square.grid.2x2")
                }
                .help("Switch to Grid Layout")

                Button {
                    TargetsCollectorPresenter.shared.show(manager: manager)
                } label: {
                    Label("Edit Targets", systemImage: "square.and.pencil")
                }
                .help("Edit the target list")

                Button {
                    let selected = manager.results.filter { selectedResultIDs.contains($0.id) }
                    MultiLatencyGraphPresenter.shared.show(results: selected.isEmpty ? manager.results : selected)
                } label: {
                    Label("Multi-Host Graph", systemImage: "chart.line.uptrend.xyaxis")
                }
                .help("Graph selected hosts together (⌘-click rows to multi-select; all hosts if none selected)")
                .disabled(manager.results.isEmpty)

                Menu {
                    ForEach(PingResultsExportType.allCases) { type in
                        Button(type.menuTitle) {
                            PingResultsExporter.export(sortedResults, as: type)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .help("Export Ping Results")
                .disabled(manager.results.isEmpty)

                Button {
                    listScale = max(minScale, listScale - scaleStep)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom Out")
                .disabled(listScale <= minScale)

                Button {
                    listScale = min(maxScale, listScale + scaleStep)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom In")
                .disabled(listScale >= maxScale)

                Button {
                    showMultiPingAboutPanel()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
                .help("About MultiPing")
            }
        }
        .labelStyle(.iconOnly)
    }

    struct StatusTextView: View {
        let label: String
        let value: String
        var color: Color? = nil
        var weight: Font.Weight = .regular

        var body: some View {
            Text(label + " ") + Text(value).fontWeight(weight).foregroundColor(color)
        }
    }
}

struct ResultsFilterBar: View {
    @Binding var filterText: String
    let shownCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(.secondary)
            TextField("Filter targets, notes, or status", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Clear Filter")
            }
            Spacer()
            Text("\(shownCount)/\(totalCount)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The results-window status bar. Timeout / Interval / Size / DSCP are editable
/// inline and applied live to the running session (press Return) without losing
/// accumulated history.
struct ResultsStatusBar: View {
    @ObservedObject var manager: PingManager

    private var dscpName: String { DSCPMark.name(for: Int(manager.dscp) ?? 0) }

    var body: some View {
        HStack(spacing: 12) {
            settingField(label: "Timeout", value: $manager.timeout, unit: "ms", width: 48)
            settingField(label: "Interval", value: $manager.interval, unit: "ms", width: 48)
            settingField(label: "Size", value: $manager.packetSize, unit: "B", width: 42)
            settingField(label: "DSCP", value: $manager.dscp, unit: dscpName, width: 34)
            labelValue("Status:", manager.pingStatus, color: .blue, weight: .bold)
            Spacer()
            labelValue("Reachable:", "\(manager.reachableCount)", color: ResultStatusPalette.green, weight: .bold)
            labelValue("Failed:", "\(manager.failedCount)", color: ResultStatusPalette.red, weight: .bold)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func settingField(label: String, value: Binding<String>, unit: String, width: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundColor(.secondary)
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .onSubmit { manager.applyLiveSettings() }
                .help("Edit and press Return to apply to the running session (kept live, history preserved)")
            if !unit.isEmpty {
                Text(unit).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func labelValue(_ label: String, _ value: String, color: Color? = nil, weight: Font.Weight = .regular) -> some View {
        Text(label + " ") + Text(value).fontWeight(weight).foregroundColor(color)
    }
}

// MARK: - Native List Table
private struct ListResultsTableView: NSViewRepresentable {
    let results: [PingResult]
    let manager: PingManager
    @Binding var sortColumn: PingResultsView.SortColumn?
    @Binding var sortAscending: Bool
    let scale: CGFloat
    @Binding var selectedResultIDs: Set<UUID>

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = NSTableView()

        tableView.identifier = NSUserInterfaceItemIdentifier("PingResultsListTable")
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.autosaveName = "PingResultsListTableColumnsV3"
        tableView.autosaveTableColumns = true
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.openGraphForClickedRow)

        let rowMenu = NSMenu()
        rowMenu.delegate = context.coordinator
        tableView.menu = rowMenu

        for column in context.coordinator.orderedColumnDefinitions() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.maxWidth = column.maxWidth
            if let sortColumn = column.sortColumn {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                    key: sortColumn.tableKey,
                    ascending: sortColumn == .targetValue
                )
            }
            tableView.addTableColumn(tableColumn)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.tableView = tableView
        context.coordinator.reload(from: self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.reload(from: self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        struct ColumnDefinition {
            let id: String
            let title: String
            let width: CGFloat
            let minWidth: CGFloat
            let maxWidth: CGFloat
            let alignment: NSTextAlignment
            let sortColumn: PingResultsView.SortColumn?
        }

        var parent: ListResultsTableView
        var results: [PingResult]
        weak var tableView: NSTableView?
        private var cancellables: [AnyCancellable] = []
        private var subscribedIDs: [UUID] = []
        private let columnOrderDefaultsKey = "PingResultsListTableColumnOrderV3"

        let columnDefinitions: [ColumnDefinition] = [
            ColumnDefinition(id: "target", title: "Target", width: 190, minWidth: 120, maxWidth: 500, alignment: .left, sortColumn: .targetValue),
            ColumnDefinition(id: "note", title: "Note", width: 170, minWidth: 80, maxWidth: 500, alignment: .left, sortColumn: nil),
            ColumnDefinition(id: "success", title: "Success", width: 76, minWidth: 62, maxWidth: 120, alignment: .right, sortColumn: .success),
            ColumnDefinition(id: "failures", title: "Failures", width: 78, minWidth: 64, maxWidth: 120, alignment: .right, sortColumn: .failures),
            ColumnDefinition(id: "failRate", title: "Fail Rate", width: 82, minWidth: 68, maxWidth: 130, alignment: .right, sortColumn: .failRate),
            ColumnDefinition(id: "current", title: "Current", width: 95, minWidth: 76, maxWidth: 160, alignment: .right, sortColumn: .current),
            ColumnDefinition(id: "average", title: "Average", width: 95, minWidth: 76, maxWidth: 160, alignment: .right, sortColumn: .average),
            ColumnDefinition(id: "minimum", title: "Minimum", width: 95, minWidth: 76, maxWidth: 160, alignment: .right, sortColumn: .minimum),
            ColumnDefinition(id: "maximum", title: "Maximum", width: 95, minWidth: 76, maxWidth: 160, alignment: .right, sortColumn: .maximum)
        ]

        init(parent: ListResultsTableView) {
            self.parent = parent
            self.results = parent.results
            super.init()
        }

        func reload(from parent: ListResultsTableView) {
            self.parent = parent
            self.results = parent.results
            syncSubscriptions()

            guard let tableView = tableView else { return }
            tableView.rowHeight = max(22, 24 * parent.scale)
            applySortDescriptors(to: tableView)
            reloadPreservingSelection()
        }

        private var isSyncingSelection = false

        func tableViewSelectionDidChange(_ notification: Notification) {
            // Ignore selection changes we caused programmatically (during reloads).
            guard !isSyncingSelection, let tableView = tableView else { return }
            let rows = sortedResults
            let newIDs = Set(tableView.selectedRowIndexes.compactMap { index -> UUID? in
                (index >= 0 && index < rows.count) ? rows[index].id : nil
            })
            if parent.selectedResultIDs != newIDs {
                parent.selectedResultIDs = newIDs
            }
        }

        /// Reload table data while preserving the user's (possibly multi-row)
        /// selection. `reloadData()` runs every ping round and can transiently
        /// clear the selection — firing a spurious selection-change that would
        /// otherwise overwrite the binding with an empty set. Guarding the whole
        /// operation with `isSyncingSelection` makes that transient change a
        /// no-op, and we re-apply the selection from the binding afterwards.
        private func reloadPreservingSelection() {
            guard let tableView = tableView else { return }
            isSyncingSelection = true
            tableView.reloadData()
            let rows = sortedResults
            var target = IndexSet()
            for (index, result) in rows.enumerated() where parent.selectedResultIDs.contains(result.id) {
                target.insert(index)
            }
            if tableView.selectedRowIndexes != target {
                tableView.selectRowIndexes(target, byExtendingSelection: false)
            }
            isSyncingSelection = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            sortedResults.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < sortedResults.count, let tableColumn = tableColumn else { return nil }

            let columnID = tableColumn.identifier.rawValue
            let reuseID = NSUserInterfaceItemIdentifier("cell-\(columnID)")
            let cell = (tableView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView) ?? makeCell(identifier: reuseID)
            guard let textField = cell.textField else { return cell }

            let result = sortedResults[row]
            configure(textField: textField, columnID: columnID, result: result)
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = PingResultsView.SortColumn(tableKey: key) else {
                parent.sortColumn = nil
                tableView.reloadData()
                return
            }

            parent.sortColumn = column
            parent.sortAscending = descriptor.ascending
            tableView.reloadData()
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            saveColumnOrder()
        }

        @objc @MainActor func openGraphForClickedRow() {
            guard let tableView = tableView else { return }
            let row = tableView.clickedRow
            let rows = sortedResults
            guard row >= 0, row < rows.count else { return }
            LatencyGraphPresenter.shared.show(result: rows[row])
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView = tableView else { return }
            let row = tableView.clickedRow
            let rows = sortedResults
            guard row >= 0, row < rows.count else { return }
            populateHostMenu(menu, for: rows[row], manager: parent.manager)
        }

        func orderedColumnDefinitions() -> [ColumnDefinition] {
            let definitionsByID = Dictionary(uniqueKeysWithValues: columnDefinitions.map { ($0.id, $0) })
            let defaultIDs = columnDefinitions.map(\.id)

            guard let savedIDs = UserDefaults.standard.array(forKey: columnOrderDefaultsKey) as? [String] else {
                return columnDefinitions
            }

            let validSavedIDs = savedIDs.filter { definitionsByID[$0] != nil }
            guard Set(validSavedIDs) == Set(defaultIDs), validSavedIDs.count == defaultIDs.count else {
                return columnDefinitions
            }

            return validSavedIDs.compactMap { definitionsByID[$0] }
        }

        private var sortedResults: [PingResult] {
            sort(results: results, by: parent.sortColumn, ascending: parent.sortAscending)
        }

        private func syncSubscriptions() {
            let ids = results.map(\.id)
            guard ids != subscribedIDs else { return }

            subscribedIDs = ids
            cancellables = results.map { result in
                result.objectWillChange
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in
                        self?.reloadPreservingSelection()
                    }
            }
        }

        private func applySortDescriptors(to tableView: NSTableView) {
            guard let sortColumn = parent.sortColumn else {
                if !tableView.sortDescriptors.isEmpty {
                    tableView.sortDescriptors = []
                }
                return
            }

            let descriptors = [NSSortDescriptor(key: sortColumn.tableKey, ascending: parent.sortAscending)]
            if tableView.sortDescriptors != descriptors {
                tableView.sortDescriptors = descriptors
            }
        }

        private func saveColumnOrder() {
            guard let tableView = tableView else { return }
            let orderedIDs = tableView.tableColumns.map { $0.identifier.rawValue }
            UserDefaults.standard.set(orderedIDs, forKey: columnOrderDefaultsKey)
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }

        private func configure(textField: NSTextField, columnID: String, result: PingResult) {
            let baseFontSize = max(9, 12 * parent.scale)
            textField.font = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
            textField.alignment = columnDefinitions.first(where: { $0.id == columnID })?.alignment ?? .left
            textField.textColor = ResultStatusPalette.nsColor(for: result)

            switch columnID {
            case "target":
                textField.stringValue = result.displayName
            case "note":
                if let note = result.note, !note.isEmpty {
                    textField.stringValue = note
                } else if let resolved = result.resolvedName {
                    textField.stringValue = resolved
                    textField.textColor = .secondaryLabelColor   // auto-resolved, not a user note
                } else {
                    textField.stringValue = ""
                }
            case "current":
                textField.stringValue = result.currentLatencyMs.map { PingResult.formatLatency(milliseconds: $0) } ?? result.responseTime
            case "average":
                textField.stringValue = PingResult.latencyDisplay(result.averageLatencyMs)
            case "minimum":
                textField.stringValue = PingResult.latencyDisplay(result.minimumLatencyMs)
            case "maximum":
                textField.stringValue = PingResult.latencyDisplay(result.maximumLatencyMs)
            case "success":
                textField.stringValue = "\(result.successCount)"
            case "failures":
                textField.stringValue = "\(result.failureCount)"
            case "failRate":
                textField.stringValue = String(format: "%.1f%%", result.failureRate)
            default:
                textField.stringValue = ""
            }

            // Paused hosts read as struck-through and dimmed. The paragraph style
            // must carry the column alignment — an attributed string ignores the
            // text field's own `alignment`.
            if result.isPaused {
                let dimmed = (textField.textColor ?? .labelColor).withAlphaComponent(0.45)
                textField.textColor = dimmed
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = textField.alignment
                paragraph.lineBreakMode = .byTruncatingTail
                textField.attributedStringValue = NSAttributedString(
                    string: textField.stringValue,
                    attributes: [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: dimmed,
                        .foregroundColor: dimmed,
                        .font: textField.font as Any,
                        .paragraphStyle: paragraph
                    ]
                )
            }
        }
    }
}

// MARK: - Sorting Helpers
func filter(results: [PingResult], by filterText: String) -> [PingResult] {
    let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return results }

    return results.filter { result in
        result.displayName.lowercased().contains(query) ||
        (result.note?.lowercased().contains(query) ?? false) ||
        (result.resolvedName?.lowercased().contains(query) ?? false) ||
        result.responseTime.lowercased().contains(query) ||
        result.targetType.rawValue.lowercased().contains(query)
    }
}

private func sort(
    results: [PingResult],
    by sortColumn: PingResultsView.SortColumn?,
    ascending: Bool
) -> [PingResult] {
    guard let sortColumn = sortColumn else { return results }

    return results.sorted { result1, result2 in
        let comparisonResult: Bool
        switch sortColumn {
        case .targetValue:
            comparisonResult = compareTargets(result1.targetValue, result1.targetType, result2.targetValue, result2.targetType)
        case .current:
            comparisonResult = compareLatency(result1.currentLatencyMs, result2.currentLatencyMs)
        case .average:
            comparisonResult = compareLatency(result1.averageLatencyMs, result2.averageLatencyMs)
        case .minimum:
            comparisonResult = compareLatency(result1.minimumLatencyMs, result2.minimumLatencyMs)
        case .maximum:
            comparisonResult = compareLatency(result1.maximumLatencyMs, result2.maximumLatencyMs)
        case .success:
            comparisonResult = result1.successCount < result2.successCount
        case .failures:
            comparisonResult = result1.failureCount < result2.failureCount
        case .failRate:
            comparisonResult = result1.failureRate < result2.failureRate
        }
        return ascending ? comparisonResult : !comparisonResult
    }
}

private func compareLatency(_ latency1: Double?, _ latency2: Double?) -> Bool {
    (latency1 ?? Double.infinity) < (latency2 ?? Double.infinity)
}

private func compareTargets(_ t1Val: String, _ t1Type: TargetType, _ t2Val: String, _ t2Type: TargetType) -> Bool {
    if t1Type == .ipv4 && t2Type == .ipv4 {
        return compareIPAddresses(t1Val, t2Val)
    }
    return t1Val.localizedStandardCompare(t2Val) == .orderedAscending
}

private func compareIPAddresses(_ ip1: String, _ ip2: String) -> Bool {
    let p1 = ip1.split(separator: ".").compactMap { UInt32($0) }
    let p2 = ip2.split(separator: ".").compactMap { UInt32($0) }
    guard p1.count == 4, p2.count == 4 else {
        return ip1.localizedStandardCompare(ip2) == .orderedAscending
    }
    for i in 0..<4 {
        if p1[i] != p2[i] { return p1[i] < p2[i] }
    }
    return false
}
