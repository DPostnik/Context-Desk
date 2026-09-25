import AppKit
import SwiftUI
import ContextCore

/// A bounded AppKit viewport owns text layout. No SwiftUI lazy-stack sizing or
/// scrollTo transaction participates in streaming updates.
public struct NativeTranscript: NSViewRepresentable {
    let items: [TranscriptItem]
    let conversationID: String?
    let followOutput: Bool
    let isWorking: Bool
    let unreadCompletionID: String?
    let unreadResponseItemID: String?
    let onReadToEnd: ((String, String) -> Void)?
    public init(items: [TranscriptItem], conversationID: String?, followOutput: Bool, isWorking: Bool = false,
                unreadCompletionID: String? = nil, unreadResponseItemID: String? = nil, onReadToEnd: ((String, String) -> Void)? = nil) {
        self.unreadCompletionID = unreadCompletionID; self.onReadToEnd = onReadToEnd
        self.unreadResponseItemID = unreadResponseItemID
        self.isWorking = isWorking
        self.items = items; self.conversationID = conversationID; self.followOutput = followOutput
    }
    public func makeNSView(context: Context) -> TranscriptScrollView { TranscriptScrollView() }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
    public func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.onReadToEnd = onReadToEnd
        view.update(items: items, conversationID: conversationID, followOutput: followOutput,
                    isWorking: isWorking, unreadCompletionID: unreadCompletionID, unreadResponseItemID: unreadResponseItemID)
    }
}

@MainActor public final class TranscriptScrollView: WidthBoundTextScrollView, NSTextViewDelegate {
    public let transcript: NSTextView
    private let pasteboard: NSPasteboard
    private var previous: [TranscriptItem] = []
    private var ranges: [NSRange] = []
    private var conversationID: String?
    private var followed = false
    private var wasWorking = false
    private var expandedActions: Set<String> = []
    private var expandedMetrics: Set<String> = []
    private var needsEndScroll = false
    private var unreadCompletionID: String?
    private var unreadResponseItemID: String?
    private var readCheckScheduled = false
    public var onReadToEnd: ((String, String) -> Void)?
    private var styledWidth: CGFloat = 0
    public private(set) var editCount = 0
    public let workingIndicator = NSHostingView(rootView: ChatLoadingIndicator())

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        // TextKit 1's non-contiguous layout avoids laying out an entire long
        // transcript to display a small viewport.
        let storage = NSTextStorage(), manager = BubbleLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        manager.allowsNonContiguousLayout = true
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        transcript = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1), textContainer: container)
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = true
        transcript.isEditable = false; transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.isRichText = true; transcript.importsGraphics = false
        transcript.isAutomaticLinkDetectionEnabled = false
        transcript.linkTextAttributes = [:]
        transcript.minSize = NSSize(width: 0, height: 0)
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainerInset = NSSize(width: 24, height: 24)
        container.widthTracksTextView = true; container.heightTracksTextView = false
        transcript.delegate = self
        transcript.setAccessibilityLabel(L10n.text("История разговора", "Conversation history"))
        documentView = transcript
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReadCheck),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReadCheck),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReadCheck),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        workingIndicator.isHidden = true
        workingIndicator.setAccessibilityLabel(L10n.text("Codex работает", "Codex is working"))
        transcript.addSubview(workingIndicator)
        (transcript as? TranscriptTextView)?.didDrawText = { [weak self] in self?.positionWorkingIndicator() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func update(items: [TranscriptItem], conversationID: String?, followOutput: Bool, isWorking: Bool = false,
                       unreadCompletionID: String? = nil, unreadResponseItemID: String? = nil) {
        self.unreadResponseItemID = unreadResponseItemID
        self.unreadCompletionID = unreadCompletionID
        defer { scheduleReadCheck() }
        var items = Self.groupActivities(items, isWorking: isWorking)
        if isWorking {
            items.append(TranscriptItem(id: "local-working", kind: "loading", text: ""))
            workingIndicator.isHidden = false
        } else { workingIndicator.isHidden = true }
        let finished = wasWorking && !isWorking
        wasWorking = isWorking
        let switched = self.conversationID != conversationID
        if switched || finished { expandedActions.removeAll() }
        if switched { expandedMetrics.removeAll() }
        let resumeFollowing = followOutput && !followed
        followed = followOutput
        guard switched || finished || items != previous else {
            if resumeFollowing { scrollToEnd() }
            return
        }
        let wasAtEnd = followOutput && !switched && isAtTranscriptEnd
        guard let storage = transcript.textStorage else { return }
        let oldOrigin = contentView.bounds.origin
        var common = 0
        if !switched && !finished {
            while common < min(previous.count, items.count), previous[common] == items[common] { common += 1 }
        }
        let start = common < ranges.count ? ranges[common].location : storage.length
        storage.beginEditing()
        storage.deleteCharacters(in: NSRange(location: start, length: storage.length - start))
        ranges = Array(ranges.prefix(common))
        for item in items.dropFirst(common) {
            let rendered = render(item, expanded: expandedActions.contains(item.id))
            ranges.append(NSRange(location: storage.length, length: rendered.length))
            storage.append(rendered)
        }
        storage.endEditing()
        previous = items; self.conversationID = conversationID; editCount += 1
        needsLayout = true
        if switched {
            needsEndScroll = false
            if unreadCompletionID == nil { scrollToEnd() }
            else { contentView.scroll(to: .zero); reflectScrolledClipView(contentView) }
        } else if followOutput && (wasAtEnd || resumeFollowing) { scrollToEnd() }
        else { contentView.scroll(to: oldOrigin); reflectScrolledClipView(contentView) }
    }

    private func scrollToEnd() {
        needsEndScroll = true
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let width = transcript.textContainer?.containerSize.width ?? 0
        if width > 0, abs(width - styledWidth) > 0.5 {
            styledWidth = width
            if let storage = transcript.textStorage {
                storage.beginEditing()
                for (item, range) in zip(previous, ranges) {
                    applyMessageStyle(item, to: storage, range: range)
                }
                storage.endEditing()
            }
        }
        positionWorkingIndicator()
        defer { scheduleReadCheck() }
        guard needsEndScroll, contentSize.width > 0, contentSize.height > 0 else { return }
        needsEndScroll = false
        transcript.scrollRangeToVisible(NSRange(location: transcript.textStorage?.length ?? 0, length: 0))
    }

    /// Non-contiguous TextKit layout can place the final glyph at an estimated
    /// position. Lay out the container before deciding that the end is visible.
    public var isAtTranscriptEnd: Bool {
        guard contentSize.width > 0, contentSize.height > 0,
              let storage = transcript.textStorage, storage.length > 0,
              let manager = transcript.layoutManager, let container = transcript.textContainer else { return false }
        let lastCharacter = NSRange(location: storage.length - 1, length: 1)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: lastCharacter, actualCharacterRange: nil)
        let end = manager.boundingRect(forGlyphRange: glyphs, in: container).maxY + transcript.textContainerOrigin.y
        let visible = transcript.visibleRect
        return visible.height > 0 && visible.maxY >= end - 2
    }

    /// A later running turn must not prevent acknowledgement of a completed answer.
    public var isUnreadResponseVisible: Bool {
        guard let itemID = unreadResponseItemID else { return !wasWorking && isAtTranscriptEnd }
        guard let index = previous.firstIndex(where: { $0.id == itemID }), ranges.indices.contains(index),
              let storage = transcript.textStorage, let manager = transcript.layoutManager,
              let container = transcript.textContainer, contentSize.height > 0 else { return false }
        let range = ranges[index]
        let text = storage.string as NSString
        // Copy controls and trailing blank paragraphs are not part of the answer to read.
        var bodyRange = range
        storage.enumerateAttribute(.messageCopy, in: range) { value, copyRange, _ in
            if value != nil { bodyRange.length = min(bodyRange.length, copyRange.location - range.location) }
        }
        let lastContent = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted,
                                               options: .backwards, range: bodyRange)
        guard lastContent.location != NSNotFound else { return false }
        let end = NSMaxRange(lastContent)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: end - 1, length: 1), actualCharacterRange: nil)
        let bottom = manager.boundingRect(forGlyphRange: glyphs, in: container).maxY + transcript.textContainerOrigin.y
        let visible = transcript.visibleRect
        return visible.height > 0 && visible.maxY >= bottom - 2
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleReadCheck()
    }

    @objc private func scheduleReadCheck() {
        guard unreadCompletionID != nil, !readCheckScheduled else { return }
        readCheckScheduled = true
        // Never publish SwiftUI state from updateNSView or AppKit layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readCheckScheduled = false
            guard let completionID = self.unreadCompletionID, let threadID = self.conversationID,
                  let window = self.window, window.isKeyWindow, window.isVisible, !window.isMiniaturized,
                  NSApplication.shared.isActive, !self.isHiddenOrHasHiddenAncestor,
                  !self.needsEndScroll, self.isUnreadResponseVisible else { return }
            self.onReadToEnd?(threadID, completionID)
        }
    }

    private func positionWorkingIndicator() {
        if wasWorking, let range = ranges.last, let manager = transcript.layoutManager, let container = transcript.textContainer {
            manager.ensureLayout(forCharacterRange: range)
            let glyph = manager.glyphIndexForCharacter(at: range.location + 6)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            workingIndicator.frame = NSRect(x: transcript.textContainerOrigin.x + container.lineFragmentPadding,
                                            y: transcript.textContainerOrigin.y + rect.midY - 10, width: 20, height: 20)
        }
    }

    // Each user message starts a new activity group. Assistant commentary stays
    // visible; all tool entries for that request share one disclosure row.
    private static func groupActivities(_ items: [TranscriptItem], isWorking: Bool) -> [TranscriptItem] {
        var result: [TranscriptItem] = []
        var segment: [TranscriptItem] = []
        func appendSegment(active: Bool) {
            let actions = segment.filter { $0.kind == "activity" }
            var inserted = false
            var showedAuthor = false
            for var item in segment {
                if item.kind == "assistant" {
                    item.showsAuthor = !showedAuthor
                    showedAuthor = true
                }
                guard item.kind == "activity" else { result.append(item); continue }
                guard !inserted, let first = actions.first, let last = actions.last else { continue }
                inserted = true
                let summary = active
                    ? L10n.text("Сейчас: ", "Now: ") + String(last.text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                    : L10n.text("Действия Codex · \(actions.count)", "Codex actions · \(actions.count)")
                result.append(TranscriptItem(id: first.id, kind: "activity", text: actions.enumerated().map {
                    "\($0.offset + 1). \($0.element.text)"
                }.joined(separator: "\n"), phase: summary))
            }
            segment.removeAll()
        }
        for item in items {
            if item.kind == "user" { appendSegment(active: false) }
            segment.append(item)
        }
        appendSegment(active: isWorking)
        return result
    }

    private func render(_ item: TranscriptItem, expanded: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = item.kind == "activity" ? 1 : 4; paragraph.paragraphSpacing = item.kind == "activity" ? 2 : 0
        paragraph.lineBreakMode = .byWordWrapping
        if item.kind == "loading" {
            return NSAttributedString(string: "      " + item.text + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
        if item.kind == "activity" {
            let title = item.phase ?? L10n.text("Действия Codex", "Codex actions")
            result.append(NSAttributedString(string: (expanded ? "▾ " : "▸ ") + title + (expanded ? "\n" : "\n\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .link: "contextdesk-action:" + item.id,
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
            ]))
            if !expanded { return result }
        } else {
            if item.kind == "user" || item.showsAuthor {
                let title = item.kind == "user" ? L10n.text("Ты", "You") + (item.phase.map { " · " + $0 } ?? "") : "Codex"
                result.append(NSAttributedString(string: title + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
                    .responseHeader: true
                ]))
            }
            if let timing = item.timing {
                let open = expandedMetrics.contains(item.id)
                result.append(NSAttributedString(string: (open ? "▾ " : "▸ ") + timing.label() + " · " + L10n.date(timing.completedAt) + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                    .link: "contextdesk-metrics:" + item.id, .responseHeader: true, .responseSeparator: true
                ]))
                if open {
                    let detail = timing.tokens?.detail() ?? L10n.text("Данные о токенах для этого запроса недоступны.", "Token data is unavailable for this request.")
                    result.append(NSAttributedString(string: detail + "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
            }
        }
        for (index, block) in item.text.components(separatedBy: "```").enumerated() {
            let isCode = index % 2 == 1 || item.kind == "activity"
            let font = isCode ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: item.kind == "activity" ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            // Code and tool output stay literal, including link-like text.
            result.append(isCode ? NSAttributedString(string: block, attributes: attributes)
                          : TranscriptLinks.render(block, attributes: attributes))
        }
        if (item.kind == "user" || item.kind == "assistant"), !item.text.isEmpty {
            if !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n")) }
            let description = L10n.text("Скопировать полный текст сообщения", "Copy the full message text")
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)
                    .applying(.init(paletteColors: [.secondaryLabelColor])))
            attachment.bounds = NSRect(x: 0, y: -3, width: 18, height: 18)
            let icon = NSMutableAttributedString(attachment: attachment)
            icon.addAttributes([
                .link: "contextdesk-copy:" + item.id, .toolTip: description, .messageCopy: true
            ], range: NSRange(location: 0, length: icon.length))
            result.append(icon)
        }
        result.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        applyMessageStyle(item, to: result, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func applyMessageStyle(_ item: TranscriptItem, to text: NSMutableAttributedString, range: NSRange) {
        guard item.kind == "user" || item.kind == "assistant", range.length > 2 else { return }
        let width = max(1, transcript.textContainer?.containerSize.width ?? 600)
        let outgoing = item.kind == "user"
        let inset = width * 0.22
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = outgoing ? inset + 16 : 0
        paragraph.headIndent = paragraph.firstLineHeadIndent
        paragraph.tailIndent = outgoing ? -16 : -4
        paragraph.lineSpacing = 4
        // Markdown already carries blank lines; do not add spacing to every newline.
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        text.enumerateAttribute(.responseHeader, in: range) { value, headerRange, _ in
            guard value != nil else { return }
            let header = paragraph.mutableCopy() as! NSMutableParagraphStyle
            header.paragraphSpacingBefore = 8
            header.minimumLineHeight = 24
            header.paragraphSpacing = outgoing ? 6 : 16
            text.addAttribute(.paragraphStyle, value: header, range: headerRange)
        }
        text.enumerateAttribute(.messageCopy, in: range) { value, copyRange, _ in
            guard value != nil else { return }
            let footer = paragraph.mutableCopy() as! NSMutableParagraphStyle
            footer.lineSpacing = 0
            footer.paragraphSpacingBefore = 4
            text.addAttribute(.paragraphStyle, value: footer, range: copyRange)
        }
        // Leave the final empty paragraph outside the bubble as inter-message spacing.
        text.addAttribute(.messageBubble, value: item.id, range: NSRange(location: range.location, length: range.length - 1))
        text.addAttribute(.outgoingBubble, value: outgoing, range: NSRange(location: range.location, length: range.length - 1))
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let value = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if value.hasPrefix("contextdesk-copy:") {
            let id = String(value.dropFirst("contextdesk-copy:".count))
            guard let item = previous.first(where: { $0.id == id && ($0.kind == "user" || $0.kind == "assistant") }),
                  !item.text.isEmpty else { return true }
            // Copy the source body only, never rendered headers, disclosures or adjacent messages.
            pasteboard.clearContents()
            pasteboard.setString(item.text, forType: .string)
            return true
        }
        if value.hasPrefix("contextdesk-metrics:") {
            let id = String(value.dropFirst("contextdesk-metrics:".count))
            guard let index = previous.firstIndex(where: { $0.id == id && $0.timing != nil }),
                  ranges.indices.contains(index), let storage = transcript.textStorage else { return true }
            if expandedMetrics.contains(id) { expandedMetrics.remove(id) } else { expandedMetrics.insert(id) }
            let rendered = render(previous[index], expanded: expandedActions.contains(id))
            let oldRange = ranges[index], delta = rendered.length - oldRange.length
            storage.replaceCharacters(in: oldRange, with: rendered)
            ranges[index].length = rendered.length
            for next in (index + 1)..<ranges.count { ranges[next].location += delta }
            editCount += 1
            needsLayout = true
            return true
        }
        if value.hasPrefix("contextdesk-action:") {
            let id = String(value.dropFirst("contextdesk-action:".count))
            guard let index = previous.firstIndex(where: { $0.id == id && $0.kind == "activity" }),
                  ranges.indices.contains(index), let storage = transcript.textStorage else { return true }
            if expandedActions.contains(id) { expandedActions.remove(id) } else { expandedActions.insert(id) }
            let rendered = render(previous[index], expanded: expandedActions.contains(id))
            let oldRange = ranges[index], delta = rendered.length - oldRange.length
            storage.replaceCharacters(in: oldRange, with: rendered)
            ranges[index].length = rendered.length
            for next in (index + 1)..<ranges.count { ranges[next].location += delta }
            editCount += 1
            needsLayout = true
            return true
        }
        guard let url = TranscriptLinks.destination(value) else { return true }
        NSWorkspace.shared.open(url); return true
    }
}

private final class TranscriptTextView: NSTextView {
    var didDrawText: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        didDrawText?()
    }
}

private extension NSAttributedString.Key {
    static let messageCopy = NSAttributedString.Key("ContextDeskMessageCopy")
    static let responseHeader = NSAttributedString.Key("ContextDeskResponseHeader")
    static let responseSeparator = NSAttributedString.Key("ContextDeskResponseSeparator")
    static let messageBubble = NSAttributedString.Key("ContextDeskMessageBubble")
    static let outgoingBubble = NSAttributedString.Key("ContextDeskOutgoingBubble")
}

/// Paint only visible message fragments; keep native selection and TextKit's bounded layout.
private final class BubbleLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, glyphsToShow.length > 0,
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil) else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.responseSeparator, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            NSColor.separatorColor.setFill()
            NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y + bounds.maxY + 6,
                   width: max(1, container.containerSize.width - 2 * container.lineFragmentPadding), height: 1).fill()
        }
        storage.enumerateAttribute(.messageBubble, in: characters) { value, range, _ in
            guard value != nil else { return }
            let outgoing = storage.attribute(.outgoingBubble, at: range.location, effectiveRange: nil) as? Bool ?? false
            guard outgoing else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            let width = container.containerSize.width
            let top = max(0, bounds.minY - 7)
            let rect = NSRect(x: origin.x + (outgoing ? width * 0.22 : 0) + 2,
                              y: origin.y + top,
                              width: max(1, width * 0.78 - 4), height: bounds.maxY + 7 - top)
            DeskPalette.outgoingBubble.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
