import AppKit
import Testing
import ContextTranscript

@Test @MainActor func transcriptMarkdownLinksRenderTitlesAndPreserveCode() {
    let result = TranscriptLinks.render("[Сайт](https://example.com/a?q=a%26b)\n[Файл](</tmp/My File.swift:12>)\n`[код](https://example.com)`", attributes: [:])
    #expect(result.string == "Сайт\nФайл\n[код](https://example.com)")
    let site = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
    #expect(site?.absoluteString == "https://example.com/a?q=a%26b")
    let file = result.attribute(.link, at: 5, effectiveRange: nil) as? URL
    #expect(file?.path == "/tmp/My File.swift")
    #expect(result.attribute(.link, at: 10, effectiveRange: nil) == nil)
}

@Test @MainActor func transcriptLinkSchemesAndBareURLs() {
    for value in ["javascript:alert(1)", "data:text/html,hi", "contextdesk-action:injected", "ssh://host", "file://remote/tmp/file"] {
        #expect(TranscriptLinks.destination(value) == nil)
    }
    #expect(TranscriptLinks.destination("file:///tmp/test.txt")?.isFileURL == true)
    #expect(TranscriptLinks.destination("/tmp/test.swift:10:2")?.path == "/tmp/test.swift")
    let rendered = TranscriptLinks.render("Открой https://example.com", attributes: [:])
    #expect(rendered.attribute(.link, at: 7, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
}
