import Foundation
import Testing
import ContextCore

@Test func markdownBlocksRecognizeStructure() {
    let source = """
    # Заголовок
    Текст абзаца
    продолжение.

    ## Second
    - один
    - [x] готово
      - вложенный
    1. первый
    10) десятый

    ---
    > [!WARNING] Осторожно
    > Тело
    > ещё

    > Цитата

    ![Схема](docs/a.png "title")
    [^1]: Сноска
    <details><summary>Ещё</summary>
    Скрытый текст
    </details>
    Underlined
    ===
    """
    let blocks = MarkdownBlocks.parse(source)
    #expect(blocks == [
        .heading(level: 1, text: "Заголовок"),
        .paragraph("Текст абзаца\nпродолжение."),
        .heading(level: 2, text: "Second"),
        .listItem(MarkdownListItem(depth: 0, marker: .bullet, text: "один")),
        .listItem(MarkdownListItem(depth: 0, marker: .bullet, checked: true, text: "готово")),
        .listItem(MarkdownListItem(depth: 1, marker: .bullet, text: "вложенный")),
        .listItem(MarkdownListItem(depth: 0, marker: .ordered(1), text: "первый")),
        .listItem(MarkdownListItem(depth: 0, marker: .ordered(10), text: "десятый")),
        .rule,
        .callout(MarkdownCallout(kind: .warning, title: "Осторожно", body: "Тело\nещё")),
        .quote("Цитата"),
        .image(alt: "Схема", source: "docs/a.png"),
        .footnote(label: "1", text: "Сноска"),
        .details(summary: "Ещё", body: "Скрытый текст"),
        .heading(level: 1, text: "Underlined"),
    ])
}

@Test func markdownCodeFencesStayLiteralAndStreamWhileOpen() {
    let blocks = MarkdownBlocks.parse("Before\n```swift title\n# not heading\n- not list\n```\n~~~\nopen fence\n| a | b |\n| --- | --- |")
    #expect(blocks == [
        .paragraph("Before"),
        .code(MarkdownCode(language: "swift", text: "# not heading\n- not list")),
        .code(MarkdownCode(language: nil, text: "open fence\n| a | b |\n| --- | --- |", closed: false)),
    ])
    // Indented fences inside list items lose the item indentation.
    #expect(MarkdownBlocks.parse("- step\n  ```sh\n  ls\n  ```") == [
        .listItem(MarkdownListItem(depth: 0, marker: .bullet, text: "step")),
        .code(MarkdownCode(language: "sh", text: "ls")),
    ])
    // A list item continues over lazy lines and an indented paragraph after a blank line.
    #expect(MarkdownBlocks.parse("- one\ncontinued\n\n  second paragraph\n\nAfter") == [
        .listItem(MarkdownListItem(depth: 0, marker: .bullet, text: "one\ncontinued\n\nsecond paragraph")),
        .paragraph("After"),
    ])
    // Not blocks: hashtags, bold text, a dash range.
    #expect(MarkdownBlocks.parse("#hashtag\n**bold**\n-1 to 1") == [.paragraph("#hashtag\n**bold**\n-1 to 1")])
}

@Test func markdownTableBlockAndSectionSource() {
    let source = "# A\nintro\n| x | y |\n| --- | ---: |\n| 1 | 2 |\n## B\nb text\n# C\nc"
    let nodes = MarkdownBlocks.nodes(source)
    guard case .table(let table) = nodes[2].block else { Issue.record("Missing table"); return }
    #expect(table.rows == [["x", "y"], ["1", "2"]])
    #expect(MarkdownBlocks.section(of: nodes, at: 0, source: source) == "# A\nintro\n| x | y |\n| --- | ---: |\n| 1 | 2 |\n## B\nb text")
    #expect(MarkdownBlocks.section(of: nodes, at: 3, source: source) == "## B\nb text")
    #expect(MarkdownBlocks.section(of: nodes, at: 1, source: source) == "")
}

@Test func codeCopyDropsShellPromptsAndOutput() {
    #expect(MarkdownCode(language: "console", text: "$ swift build\nCompiling…\n$ swift test\nok").copyText == "swift build\nswift test")
    #expect(MarkdownCode(language: "bash", text: "# install\nbrew install jq").copyText == "# install\nbrew install jq")
    #expect(MarkdownCode(language: "swift", text: "$ literal").copyText == "$ literal")
}

@Test func tableSerializesForMarkdownAndSpreadsheets() {
    let table = MarkdownTable(rows: [["Name", "Total"], ["**A** \\| B", "1 200"], ["[Docs](https://x.y)", "-3.5%"]],
                              alignments: [.left, .left])
    #expect(table.markdown == "| Name | Total |\n| --- | --- |\n| **A** \\| B | 1 200 |\n| [Docs](https://x.y) | -3.5% |")
    #expect(table.tabSeparated == "Name\tTotal\nA | B\t1 200\nDocs\t-3.5%")
    #expect(table.displayAlignments == [.left, .right])
}

@Test func syntaxHighlighterFindsTokensWithoutRunningCode() {
    let code = "let name = \"x\" // note\nstruct View: Body { var n = 42 }"
    let tokens = SyntaxHighlighter.tokens(in: code, language: "swift")
    func text(_ token: SyntaxHighlighter.Token) -> String { (code as NSString).substring(with: token.range) }
    let byKind = Dictionary(grouping: tokens, by: \.kind).mapValues { $0.map(text) }
    #expect(byKind[.keyword] == ["let", "struct", "var"])
    #expect(byKind[.string] == ["\"x\""])
    #expect(byKind[.comment] == ["// note"])
    #expect(byKind[.number] == ["42"])
    #expect(byKind[.type] == ["View", "Body"])
    let json = "{\"key\": \"value\", \"n\": 1}"
    let jsonTokens = SyntaxHighlighter.tokens(in: json, language: "json").map { (($0.kind), (json as NSString).substring(with: $0.range)) }
    #expect(jsonTokens.map(\.0) == [.key, .string, .key, .number])
    let shell = "echo \"$HOME\" # comment\nexport PATH=${PATH}:x"
    let shellKinds = SyntaxHighlighter.tokens(in: shell, language: "zsh").map(\.kind)
    #expect(shellKinds == [.keyword, .string, .comment, .keyword, .variable])
    #expect(SyntaxHighlighter.tokens(in: "anything", language: "brainfuck").isEmpty)
    #expect(SyntaxHighlighter.tokens(in: "key: value\n- item: 1", language: "yaml").map(\.kind) == [.key, .key, .number])
}
