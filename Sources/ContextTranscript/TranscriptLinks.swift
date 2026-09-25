import AppKit
import Foundation

/// Link parsing produces data only; opening is handled exclusively by a user click.
@MainActor public enum TranscriptLinks {
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

    public static func render(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard let markdown = try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )) else { return NSAttributedString(string: text, attributes: attributes) }
        let result = NSMutableAttributedString()
        for run in markdown.runs {
            let content = String(markdown[run.range].characters)
            var style = attributes
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            if isCode { style[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }
            if !isCode, let target = run.link, let url = destination(target.scheme == nil ? (target.relativeString.removingPercentEncoding ?? target.relativeString) : target.absoluteString) {
                style[.link] = url
                style[.foregroundColor] = NSColor.linkColor
                style[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let chunk = NSMutableAttributedString(string: content, attributes: style)
            if !isCode, style[.link] == nil,
               let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let range = NSRange(location: 0, length: chunk.length)
                for match in detector.matches(in: content, range: range) {
                    guard let target = match.url, let url = destination(target.absoluteString) else { continue }
                    chunk.addAttributes([.link: url, .foregroundColor: NSColor.linkColor,
                                         .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
                }
            }
            result.append(chunk)
        }
        return result
    }
}
