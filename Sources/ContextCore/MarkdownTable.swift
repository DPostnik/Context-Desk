import Foundation

/// Pipe tables are recognized only after a matching delimiter row. Incomplete
/// streaming prefixes and ordinary prose remain text until that row arrives.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case left, center, right }
    public enum Block: Equatable, Sendable {
        case text(String)
        case table(MarkdownTable)
    }
    public let rows: [[String]]
    public let alignments: [Alignment]

    public static func blocks(in source: String) -> [Block] {
        let lines = source.components(separatedBy: "\n")
        var result: [Block] = [], pending: [String] = []
        var index = 0
        var fence: (character: Character, count: Int)?
        func flush() {
            if !pending.isEmpty { result.append(.text(pending.joined(separator: "\n"))); pending = [] }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "~" || first == "`" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if let current = fence {
                        if first == current.character, count >= current.count,
                           trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else { fence = (first, count) }
                    pending.append(line); index += 1; continue
                }
            }
            guard fence == nil, index + 1 < lines.count,
                  let header = cells(line), let delimiters = cells(lines[index + 1]),
                  header.count == delimiters.count,
                  delimiters.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else {
                pending.append(line); index += 1; continue
            }
            // Retain the newline before a table so the preceding text has its own paragraph.
            if !pending.isEmpty { pending.append("") }
            flush()
            let alignments: [Alignment] = delimiters.map {
                $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .right) : .left
            }
            var rows = [header]
            index += 2
            while index < lines.count, let row = cells(lines[index]),
                  !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                rows.append(Array((row + Array(repeating: "", count: header.count)).prefix(header.count)))
                index += 1
            }
            result.append(.table(MarkdownTable(rows: rows, alignments: alignments)))
        }
        flush()
        return result
    }

    private static func cells(_ line: String) -> [String]? {
        guard !line.hasPrefix("    "), !line.hasPrefix("\t") else { return nil }
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var cells: [String] = [], cell = "", index = 0, hasPipe = false
        var codeRun = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                cell.append(character); cell.append(characters[index + 1]); index += 2; continue
            }
            if character == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let count = index - start
                if codeRun == count { codeRun = 0 }
                else if codeRun == 0,
                        String(characters[index...]).contains(String(repeating: "`", count: count)) { codeRun = count }
                cell += String(repeating: "`", count: count)
                continue
            }
            if character == "|", codeRun == 0 {
                cells.append(cell); cell = ""; hasPipe = true
            } else { cell.append(character) }
            index += 1
        }
        guard hasPipe else { return nil }
        cells.append(cell)
        if characters.first == "|" { cells.removeFirst() }
        if cells.last == "", characters.last == "|" { cells.removeLast() }
        return cells.isEmpty ? nil : cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
