import AppKit
import ContextCore

extension NSAttributedString.Key {
    static let transcriptTableStyle = NSAttributedString.Key("ContextDeskTableStyle")
}

/// Native text blocks keep cells selectable and links interactive in the same
/// text view as prose. No HTML parsing, attachment screenshots or web view.
@MainActor enum TranscriptTables {
    static func render(_ source: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in MarkdownTable.blocks(in: source) {
            switch block {
            case .text(let text): result.append(TranscriptLinks.render(text, attributes: attributes))
            case .table(let model):
                let table = NSTextTable()
                table.numberOfColumns = model.alignments.count
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                table.collapsesBorders = true
                table.hidesEmptyCells = false
                table.setContentWidth(100, type: .percentageValueType)
                for (rowIndex, row) in model.rows.enumerated() {
                    for (column, value) in row.enumerated() {
                        let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                                    startingColumn: column, columnSpan: 1)
                        cell.setContentWidth(100 / CGFloat(table.numberOfColumns), type: .percentageValueType)
                        cell.verticalAlignment = .topAlignment
                        cell.setWidth(8, type: .absoluteValueType, for: .padding)
                        if rowIndex < model.rows.count - 1 {
                            cell.setWidth(rowIndex == 0 ? 1 : 0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                            cell.setBorderColor(.separatorColor, for: .maxY)
                        }
                        let style = NSMutableParagraphStyle()
                        style.textBlocks = [cell]
                        style.lineSpacing = 3
                        style.lineBreakMode = .byWordWrapping
                        switch model.alignments[column] {
                        case .left: style.alignment = .left
                        case .center: style.alignment = .center
                        case .right: style.alignment = .right
                        }
                        var cellAttributes = attributes
                        cellAttributes[.font] = NSFont.systemFont(ofSize: 14, weight: rowIndex == 0 ? .semibold : .regular)
                        cellAttributes[.paragraphStyle] = style
                        cellAttributes[.transcriptTableStyle] = style
                        result.append(TranscriptLinks.render(value, attributes: cellAttributes))
                        result.append(NSAttributedString(string: "\n", attributes: cellAttributes))
                    }
                }
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    static func restoreStyles(in text: NSMutableAttributedString, range: NSRange) {
        text.enumerateAttribute(.transcriptTableStyle, in: range) { value, cellRange, _ in
            guard let style = value as? NSParagraphStyle else { return }
            text.addAttribute(.paragraphStyle, value: style, range: cellRange)
        }
    }
}
