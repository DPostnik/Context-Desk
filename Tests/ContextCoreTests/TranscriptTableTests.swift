import AppKit
import Testing
import ContextCore
import ContextTranscript

@Test func markdownTablesRequireDelimiterAndPreserveSurroundingText() {
    let source = "Before\n\n| Task | Result |\n| :--- | ---: |\n| Linux | VPS |\n| Mac | Dedicated host |\n\nAfter"
    let blocks = MarkdownTable.blocks(in: source)
    #expect(blocks.count == 3)
    #expect(blocks.first == .text("Before\n\n"))
    #expect(blocks.last == .text("\nAfter"))
    guard case .table(let table) = blocks[1] else { Issue.record("Missing table"); return }
    #expect(table.rows == [["Task", "Result"], ["Linux", "VPS"], ["Mac", "Dedicated host"]])
    #expect(table.alignments == [.left, .right])
    for literal in ["a | b", "| a | b |\n| --- |", "| a | b |\n| --- | --", "~~~md\n| a | b |\n| --- | --- |\n~~~", "    | a | b |\n    | --- | --- |"] {
        #expect(MarkdownTable.blocks(in: literal) == [.text(literal)])
    }
}

@Test func markdownTableEscapesInlineCodeAndRaggedRows() {
    let blocks = MarkdownTable.blocks(in: "Name | Value | Extra\n--- | :---: | ---:\nA \\| B | `x|y` | z\nshort | row\n1 | 2 | 3 | ignored")
    guard case .table(let table) = blocks.first else { Issue.record("Missing table"); return }
    #expect(table.rows[1] == ["A \\| B", "`x|y`", "z"])
    #expect(table.rows[2] == ["short", "row", ""])
    #expect(table.rows[3] == ["1", "2", "3"])
    #expect(table.alignments == [.left, .center, .right])
}

@Test @MainActor func nativeTablesWrapResizeStreamAndKeepLinksAndSourceCopy() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let view = TranscriptScrollView(pasteboard: pasteboard)
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 650)
    let source = "Возможности / Capabilities\n\n| Задача / Task | Где выполнять / Host |\n| :--- | --- |\n| Работа с кодом и Linux-совместимые сборки | Подходит обычный VPS |\n| Локальные приложения и Keychain | Нужен Mac и текущая сессия пользователя |\n| [Документация](https://example.com) | `swift build` |\n\nПосле таблицы / After the table"
    var item = TranscriptItem(id: "table", kind: "assistant", text: "| A | B |\n| ---")
    view.update(items: [item], conversationID: "table", followOutput: false)
    #expect(view.transcript.string.contains("| ---"))
    item.text = source
    view.update(items: [item], conversationID: "table", followOutput: false)
    let storage = try #require(view.transcript.textStorage)
    #expect(!storage.string.contains("| :---"))
    #expect(storage.string.contains("После таблицы"))
    let linkIndex = (storage.string as NSString).range(of: "Документация").location
    #expect(storage.attribute(.link, at: linkIndex, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    let headerIndex = (storage.string as NSString).range(of: "Задача").location
    for width: CGFloat in [760, 360, 920, 440] {
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.transcript.layoutManager)
        let container = try #require(view.transcript.textContainer)
        manager.ensureLayout(for: container)
        let style = try #require(storage.attribute(.paragraphStyle, at: headerIndex, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try #require(style.textBlocks.first as? NSTextTableBlock)
        #expect(cell.table.numberOfColumns == 2)
        #expect(manager.usedRect(for: container).maxX + view.transcript.textContainerOrigin.x <= view.contentSize.width + 1)
        let after = (storage.string as NSString).range(of: "После таблицы").location
        let lastCell = (storage.string as NSString).range(of: "swift build").location
        let afterRect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: NSRange(location: after, length: 1), actualCharacterRange: nil), in: container)
        let cellRect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: NSRange(location: lastCell, length: 1), actualCharacterRange: nil), in: container)
        #expect(afterRect.minY > cellRect.maxY)
        if let directory = ProcessInfo.processInfo.environment["CONTEXTDESK_TABLE_RENDER_DIR"] {
            view.drawsBackground = true
            view.backgroundColor = .textBackgroundColor
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("table-\(Int(width)).png"))
        }
    }
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:table", at: 0)
    #expect(pasteboard.string(forType: .string) == source)
    item.text = "```markdown\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```"
    view.update(items: [item], conversationID: "table", followOutput: false)
    #expect(view.transcript.string.contains("| --- | --- |"))
    #expect(!view.transcript.string.contains("Задача"))
}

@Test @MainActor func nativeWideTableRemainsInsideNarrowViewport() throws {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 360, height: 550)
    let source = "| A | B | C | D | E | F |\n| --- | --- | --- | --- | --- | --- |\n| "
        + Array(repeating: String(repeating: "x", count: 120), count: 6).joined(separator: " | ") + " |"
    view.update(items: [TranscriptItem(id: "wide", kind: "assistant", text: source)], conversationID: "wide", followOutput: false)
    view.layoutSubtreeIfNeeded()
    let manager = try #require(view.transcript.layoutManager)
    let container = try #require(view.transcript.textContainer)
    manager.ensureLayout(for: container)
    #expect(manager.usedRect(for: container).maxX + view.transcript.textContainerOrigin.x <= view.contentSize.width + 1)
}
