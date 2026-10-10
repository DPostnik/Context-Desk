import AppKit
import Foundation

extension NSAttributedString.Key {
    /// Rounded background behind inline code and link chips; value is `TranscriptLinks.Chip`.
    static let inlineChip = NSAttributedString.Key("ContextDeskInlineChip")
}

/// Link parsing produces data only; opening is handled exclusively by a user click.
@MainActor public enum TranscriptLinks {
    enum Chip: Int { case code, file, web }

    /// How agent text is decorated in the transcript. Defaults keep the literal text.
    public struct Options {
        /// File links get an icon and a compact name; long bare URLs are shortened to their host.
        public var chips = false
        /// Relative paths in prose and inline code resolve against this directory.
        public var baseDirectory: URL?
        public var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        public init(chips: Bool = false, baseDirectory: URL? = nil) { self.chips = chips; self.baseDirectory = baseDirectory }
    }

    public static func destination(_ value: String) -> URL? {
        if value.hasPrefix("/") {
            // Source references may include a line and optional column suffix.
            let path = value.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
            return URL(fileURLWithPath: path)
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url
        case "file": return url.host == nil || url.host == "" || url.host == "localhost" ? url : nil
        default: return nil
        }
    }

    /// `:line` or `:line:column` of a source reference, if present.
    static func lineSuffix(_ value: String) -> String? {
        value.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression).map { String(value[$0]) }
    }

    /// An existing file named by an absolute or project-relative path, with an optional `:line` suffix.
    static func fileReference(_ text: String, options: Options) -> (url: URL, line: String?)? {
        var path = text.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains(" ") || path.hasPrefix("/"), !path.contains("://") else { return nil }
        let line = lineSuffix(path)
        if let line { path.removeLast(line.count) }
        if path.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst(1) }
        let url: URL
        if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else if let base = options.baseDirectory, path.contains("/") || line != nil {
            url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        } else { return nil }
        guard url.path.count > 1, options.fileExists(url.path) else { return nil }
        return (url, line)
    }

    public static func render(_ text: String, attributes: [NSAttributedString.Key: Any], options: Options = Options()) -> NSAttributedString {
        guard let markdown = try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )) else { return NSAttributedString(string: text, attributes: attributes) }
        let result = NSMutableAttributedString()
        let baseFont = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        for run in markdown.runs {
            let content = String(markdown[run.range].characters)
            var style = attributes
            let intent = run.inlinePresentationIntent ?? []
            let isCode = intent.contains(.code)
            var font = baseFont
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            style[.font] = font
            if intent.contains(.strikethrough) { style[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if isCode {
                style[.font] = NSFont.monospacedSystemFont(ofSize: max(10, baseFont.pointSize - 1.5), weight: .regular)
                if options.chips { style[.inlineChip] = Chip.code.rawValue }
            }
            if !isCode, let target = run.link {
                let raw = target.scheme == nil ? (target.relativeString.removingPercentEncoding ?? target.relativeString) : target.absoluteString
                let file = options.chips && target.scheme == nil ? fileReference(raw, options: options) : nil
                if let url = file?.url ?? destination(raw) {
                    result.append(link(content, url: url, line: file?.line ?? lineSuffix(raw), style: style, options: options))
                    continue
                }
            }
            if isCode, options.chips, let file = fileReference(content, options: options) {
                // Paths in inline code are the most common way agents cite files.
                result.append(link(content, url: file.url, line: nil, style: style, options: options, keepText: true))
                continue
            }
            let chunk = NSMutableAttributedString(string: content, attributes: style)
            if !isCode, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let range = NSRange(location: 0, length: chunk.length)
                for match in detector.matches(in: content, range: range).reversed() {
                    guard let target = match.url, let url = destination(target.absoluteString) else { continue }
                    let shown = (content as NSString).substring(with: match.range)
                    chunk.replaceCharacters(in: match.range, with: link(shown, url: url, line: nil, style: style, options: options))
                }
                if options.chips { linkPlainPaths(in: chunk, options: options) }
                decorate(chunk)
            }
            result.append(chunk)
        }
        return result
    }

    private static func link(_ text: String, url: URL, line: String?, style: [NSAttributedString.Key: Any],
                             options: Options, keepText: Bool = false) -> NSAttributedString {
        var style = style
        style[.link] = url
        style[.toolTip] = url.isFileURL ? url.path + (line ?? "") : url.absoluteString
        style[.foregroundColor] = NSColor.linkColor
        guard options.chips else {
            style[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return NSAttributedString(string: text, attributes: style)
        }
        let result = NSMutableAttributedString()
        if url.isFileURL {
            style[.inlineChip] = Chip.file.rawValue
            let attachment = NSTextAttachment()
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 14, height: 14)
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -2.5, width: 14, height: 14)
            result.append(NSAttributedString(attachment: attachment))
            // A full path as the visible text is shortened to the file name; written titles stay.
            var title = text
            if !keepText, text.hasPrefix("/") || text == url.path || text.hasSuffix(url.lastPathComponent + (line ?? "")) && text.contains("/") {
                title = url.lastPathComponent
            }
            if let line, !title.hasSuffix(line) { title += line }
            result.append(NSAttributedString(string: "\u{2009}" + title, attributes: style))
            result.addAttributes(style, range: NSRange(location: 0, length: 1))
        } else {
            style[.underlineStyle] = NSUnderlineStyle.single.rawValue
            style[.underlineColor] = NSColor.linkColor.withAlphaComponent(0.35)
            var title = text
            if text == url.absoluteString, text.count > 48, let host = url.host {
                let path = url.path.split(separator: "/").prefix(2).joined(separator: "/")
                title = host.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
                    + (path.isEmpty ? "" : "/" + path) + "/…"
            }
            result.append(NSAttributedString(string: title, attributes: style))
        }
        return result
    }

    /// Plain-text paths such as `Sources/App/View.swift:42` become file links when the file exists.
    private static func linkPlainPaths(in chunk: NSMutableAttributedString, options: Options) {
        let pattern = #"(?<![\w/.@:-])(?:~?/)?(?:[\w.@-]+/)+[\w@-][\w.@-]*\.[A-Za-z0-9]{1,10}(?::\d+(?::\d+)?)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let string = chunk.string
        for match in expression.matches(in: string, range: NSRange(location: 0, length: chunk.length)).reversed() {
            guard chunk.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let text = (string as NSString).substring(with: match.range)
            guard let file = fileReference(text, options: options) else { continue }
            let style = chunk.attributes(at: match.range.location, effectiveRange: nil)
            chunk.replaceCharacters(in: match.range, with: link(text, url: file.url, line: nil, style: style, options: options, keepText: true))
        }
    }

    /// `==highlight==` and footnote references `[^1]`, outside code and links.
    private static func decorate(_ chunk: NSMutableAttributedString) {
        let highlight = try? NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#)
        for match in highlight?.matches(in: chunk.string, range: NSRange(location: 0, length: chunk.length)).reversed() ?? [] {
            guard chunk.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let inner = chunk.attributedSubstring(from: match.range(at: 1)).mutableCopy() as! NSMutableAttributedString
            inner.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.32), range: NSRange(location: 0, length: inner.length))
            chunk.replaceCharacters(in: match.range, with: inner)
        }
        let footnote = try? NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
        for match in footnote?.matches(in: chunk.string, range: NSRange(location: 0, length: chunk.length)).reversed() ?? [] {
            guard chunk.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            var style = chunk.attributes(at: match.range.location, effectiveRange: nil)
            style[.font] = NSFont.systemFont(ofSize: 10, weight: .semibold)
            style[.baselineOffset] = 5
            style[.foregroundColor] = NSColor.controlAccentColor
            chunk.replaceCharacters(in: match.range, with: NSAttributedString(string: (chunk.string as NSString).substring(with: match.range(at: 1)), attributes: style))
        }
    }
}
