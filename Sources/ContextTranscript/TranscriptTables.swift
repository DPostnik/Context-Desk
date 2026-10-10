import AppKit
import ContextCore

extension NSAttributedString.Key {
    static let transcriptTableStyle = NSAttributedString.Key("ContextDeskTableStyle")
}

/// Native text blocks keep cells selectable and links interactive in the same
/// text view as prose. No HTML parsing, attachment screenshots or web view.
@MainActor enum TranscriptTables {
    static func render(_ model: MarkdownTable, attributes: [NSAttributedString.Key: Any],
                       options: TranscriptLinks.Options = TranscriptLinks.Options()) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = model.alignments.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        let alignments = model.displayAlignments
        // Table borders ignore dynamic separator transparency; a translucent gray works in both appearances.
        let border = NSColor(calibratedWhite: 0.5, alpha: 1)
        for (rowIndex, row) in model.rows.enumerated() {
            for (column, value) in row.enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                            startingColumn: column, columnSpan: 1)
                cell.setContentWidth(100 / CGFloat(table.numberOfColumns), type: .percentageValueType)
                cell.verticalAlignment = .topAlignment
                cell.setWidth(8, type: .absoluteValueType, for: .padding)
                cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                // A hairline frame around the table, a firmer line under the header, quiet row lines.
                // Outer frame and row lines only; columns are separated by padding.
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(border.withAlphaComponent(0.35))
                if column > 0 { cell.setWidth(0, type: .absoluteValueType, for: .border, edge: .minX) }
                if column < row.count - 1 { cell.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxX) }
                if rowIndex == 0 {
                    cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    cell.setBorderColor(border.withAlphaComponent(0.55), for: .maxY)
                    cell.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
                } else if rowIndex % 2 == 0 {
                    cell.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.035)
                }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                style.lineSpacing = 3
                style.lineBreakMode = .byWordWrapping
                switch alignments[column] {
                case .left: style.alignment = .left
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                }
                var cellAttributes = attributes
                cellAttributes[.font] = NSFont.systemFont(ofSize: rowIndex == 0 ? 13 : 13.5, weight: rowIndex == 0 ? .semibold : .regular)
                if alignments[column] == .right, rowIndex > 0 {
                    cellAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .regular)
                }
                cellAttributes[.paragraphStyle] = style
                cellAttributes[.transcriptTableStyle] = style
                result.append(TranscriptLinks.render(value, attributes: cellAttributes, options: options))
                result.append(NSAttributedString(string: "\n", attributes: cellAttributes))
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
