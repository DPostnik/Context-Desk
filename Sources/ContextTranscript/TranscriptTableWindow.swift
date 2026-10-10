import AppKit
import ContextCore

/// A wide table from an answer in its own window: native columns with horizontal
/// scrolling and resizable widths. Cells show text only; links stay in the chat.
@MainActor final class TranscriptTableWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static var open: [TranscriptTableWindow] = []
    private let table: MarkdownTable
    private let rows: [[String]]
    private var window: NSWindow?

    static func show(_ table: MarkdownTable, relativeTo parent: NSWindow?) {
        let controller = TranscriptTableWindow(table)
        open.append(controller)
        controller.present(relativeTo: parent)
    }

    init(_ table: MarkdownTable) {
        self.table = table
        // Reuse the spreadsheet text: Markdown marks and link targets removed.
        rows = table.tabSeparated.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
    }

    private func present(relativeTo parent: NSWindow?) {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        tableView.style = .fullWidth
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.usesAutomaticRowHeights = true
        let header = rows.first ?? []
        let alignments = table.displayAlignments
        for (index, title) in header.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            column.title = title
            let longest = rows.map { index < $0.count ? $0[index].count : 0 }.max() ?? 0
            column.width = min(420, max(80, CGFloat(longest) * 7.5 + 16))
            column.minWidth = 40
            if alignments.indices.contains(index), alignments[index] == .right { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let width = min(1200, max(480, tableView.tableColumns.reduce(0) { $0 + $1.width } + 40))
        let height = min(720, max(240, CGFloat(rows.count) * 26 + 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.text("Таблица · \(max(0, rows.count - 1)) \(Self.russianRows(max(0, rows.count - 1)))",
                                 "Table · \(max(0, rows.count - 1)) \(rows.count - 1 == 1 ? "row" : "rows")")
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2))
        } else { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { max(0, rows.count - 1) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let values = rows[row + 1]
        let field = NSTextField(wrappingLabelWithString: column < values.count ? values[column] : "")
        field.isSelectable = true
        field.font = .systemFont(ofSize: 13)
        let alignments = table.displayAlignments
        if alignments.indices.contains(column) {
            switch alignments[column] {
            case .left: field.alignment = .left
            case .center: field.alignment = .center
            case .right: field.alignment = .right; field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            }
        }
        return field
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    static func russianRows(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        if (11...14).contains(tens) { return "строк" }
        if ones == 1 { return "строка" }
        if (2...4).contains(ones) { return "строки" }
        return "строк"
    }
}
