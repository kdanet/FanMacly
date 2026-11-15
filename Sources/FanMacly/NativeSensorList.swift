import AppKit
import FanMaclyCore

@MainActor final class NativeSensorList: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private var allSensors = [TemperatureSensor]()
    private var filtered = [TemperatureSensor]()
    private var snapshotDate: Date?
    private var guides = [String: SensorGuide]()
    private let empty = NativeUI.label("Датчики не найдены.", size: 12, secondary: true)
    private let detailTitle = NativeUI.label("Выберите датчик", size: 11, weight: .medium)
    private let detailText = NativeUI.label("Описание и область измерения появятся здесь. Не все коды SMC имеют достоверную расшифровку.", size: 11, secondary: true)
    private lazy var sourceButton = NSButton(title: "Источник", target: self, action: #selector(openSource))
    private var sourceURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        search.placeholderString = "Поиск датчиков"
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.delegate = self
        search.setAccessibilityLabel("Поиск датчиков")
        search.controlSize = .regular
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Датчик"
        name.width = 240
        name.minWidth = 100
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        value.title = "°C"
        value.width = 55
        value.minWidth = 55
        value.maxWidth = 70
        value.headerCell.alignment = .right
        table.addTableColumn(name); table.addTableColumn(value)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowHeight = 23
        table.intercellSpacing = NSSize(width: 10, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .controlBackgroundColor
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("Температурные датчики")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        let list = NSView()
        NativeUI.fill(scroll, in: list)
        empty.alignment = .center
        empty.isHidden = true
        list.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor)
        ])
        detailText.maximumNumberOfLines = 5
        detailText.usesSingleLineMode = false
        detailText.lineBreakMode = .byWordWrapping
        detailText.cell?.wraps = true
        detailText.preferredMaxLayoutWidth = 322
        detailText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceButton.isBordered = false
        sourceButton.font = .systemFont(ofSize: 10)
        sourceButton.isEnabled = false
        sourceButton.setAccessibilityLabel("Открыть источник описания датчика")
        let detailHeader = NativeUI.stack(.horizontal, spacing: 6, views: [detailTitle, NativeUI.spacer(), sourceButton])
        let detail = NativeUI.stack(.vertical, spacing: 4, views: [detailHeader, detailText])
        NativeUI.size(detail, height: 96)
        let stack = NativeUI.stack(.vertical, spacing: 8, views: [search, list, detail])
        stack.alignment = .leading
        NativeUI.fill(stack, in: self)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func guide(for key: String) -> SensorGuide {
        if let cached = guides[key] { return cached }
        let value = SensorGuide.describe(key)
        guides[key] = value
        return value
    }
    func update(_ snapshot: HardwareSnapshot) {
        guard snapshotDate != snapshot.date else { return }
        snapshotDate = snapshot.date
        allSensors = snapshot.sensors.sorted {
            let a = guide(for: $0.id), b = guide(for: $1.id)
            return a.priority != b.priority ? a.priority < b.priority : $0.id < $1.id
        }
        applyFilter()
    }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = allSensors.filter {
            let guide = guide(for: $0.id)
            return query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) ||
                guide.title.localizedCaseInsensitiveContains(query) || guide.details.localizedCaseInsensitiveContains(query)
        }
        let oldIDs = filtered.map(\.id)
        let selected = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil
        filtered = next
        empty.isHidden = !filtered.isEmpty
        if oldIDs == next.map(\.id) {
            // Names/row identity stay stable during telemetry updates. Refresh
            // only values; AppKit virtualizes the visible table cells.
            if !filtered.isEmpty { table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<filtered.count), columnIndexes: IndexSet(integer: 1)) }
        } else {
            table.reloadData()
            if let selected, let index = filtered.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        updateDetails()
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetails() }
    private func updateDetails() {
        guard filtered.indices.contains(table.selectedRow) else {
            NativeUI.text(detailTitle, "Выберите датчик")
            NativeUI.text(detailText, "Описание и область измерения появятся здесь. Не все коды SMC имеют достоверную расшифровку.")
            detailText.toolTip = nil
            sourceURL = nil; sourceButton.isEnabled = false
            return
        }
        let sensor = filtered[table.selectedRow], guide = guide(for: filtered[table.selectedRow].id)
        NativeUI.text(detailTitle, "\(sensor.id) · \(guide.confidence.rawValue)")
        NativeUI.text(detailText, guide.details)
        detailText.toolTip = guide.details
        sourceURL = guide.source.flatMap(URL.init(string:))
        sourceButton.isEnabled = sourceURL != nil
    }
    @objc private func openSource() {
        if let sourceURL { NSWorkspace.shared.open(sourceURL) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row), let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NativeUI.label("", size: 12, numeric: identifier.rawValue == "value")
            label.alignment = identifier.rawValue == "value" ? .right : .left
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let sensor = filtered[row]
        let guide = guide(for: sensor.id)
        cell.textField?.stringValue = identifier.rawValue == "value" ? String(format: "%.1f", locale: Locale.current, sensor.celsius) : guide.title
        cell.toolTip = "\(guide.title) · \(sensor.id)\n\(guide.confidence.rawValue)\n\(guide.details)"
        return cell
    }
}
