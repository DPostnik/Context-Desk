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
    let workingStatus: String?
    let workingSince: Date?
    let unreadCompletionID: String?
    let unreadResponseItemID: String?
    let onReadToEnd: ((String, String) -> Void)?
    public init(items: [TranscriptItem], conversationID: String?, followOutput: Bool, isWorking: Bool = false, workingStatus: String? = nil,
                workingSince: Date? = nil, unreadCompletionID: String? = nil, unreadResponseItemID: String? = nil, onReadToEnd: ((String, String) -> Void)? = nil) {
        self.unreadCompletionID = unreadCompletionID; self.onReadToEnd = onReadToEnd
        self.unreadResponseItemID = unreadResponseItemID
        self.isWorking = isWorking; self.workingStatus = workingStatus; self.workingSince = workingSince
        self.items = items; self.conversationID = conversationID; self.followOutput = followOutput
    }
    public func makeNSView(context: Context) -> TranscriptScrollView { TranscriptScrollView(positions: .session) }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
    public func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.onReadToEnd = onReadToEnd
        view.update(items: items, conversationID: conversationID, followOutput: followOutput,
                    isWorking: isWorking, workingStatus: workingStatus, workingSince: workingSince, unreadCompletionID: unreadCompletionID, unreadResponseItemID: unreadResponseItemID)
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
    private var copyFeedback: (id: String, succeeded: Bool, block: Int?)?
    private var copyFeedbackTask: Task<Void, Never>?
    private var needsEndScroll = false
    private let positions: TranscriptReadingPositions
    private var pendingPosition: TranscriptReadingPositions.Position?
    private var changingLayout = false
    private var unreadCompletionID: String?
    private var unreadResponseItemID: String?
    private var readCheckScheduled = false
    public var onReadToEnd: ((String, String) -> Void)?
    private var styledWidth: CGFloat = 0
    public private(set) var editCount = 0
    public let workingIndicator = WorkingIndicatorView()
    private var workingStatus: String?
    private var workingSince: Date?
    private var workingTimer: Timer?
    /// Message whose copy control is shown; controls of other messages stay hidden until hovered.
    public private(set) var hoveredItemID: String?
    /// Transcript text keeps a readable column; wider windows add margins instead of longer lines.
    public static let readableWidth: CGFloat = 760

    public init(pasteboard: NSPasteboard = .general, positions: TranscriptReadingPositions = TranscriptReadingPositions()) {
        self.positions = positions
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
        // Keep our link styling, but explicitly retain the hand cursor for links
        // and linked attachments such as the message-copy icon.
        transcript.linkTextAttributes = [.cursor: NSCursor.pointingHand]
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
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReadCheck),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReadCheck),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        workingIndicator.isHidden = true
        workingIndicator.setAccessibilityLabel(L10n.text("Агент работает", "Agent is working"))
        transcript.addSubview(workingIndicator)
        (transcript as? TranscriptTextView)?.didDrawText = { [weak self] in self?.positionWorkingIndicator() }
        (transcript as? TranscriptTextView)?.hoverChanged = { [weak self] point in self?.updateHover(at: point) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func update(items: [TranscriptItem], conversationID: String?, followOutput: Bool, isWorking: Bool = false, workingStatus: String? = nil,
                       workingSince: Date? = nil, unreadCompletionID: String? = nil, unreadResponseItemID: String? = nil) {
        self.unreadResponseItemID = unreadResponseItemID
        self.unreadCompletionID = unreadCompletionID
        let workingStatus = isWorking ? Self.currentActivity(items).map { Self.activityHeadline($0.text) } ?? workingStatus : workingStatus
        var items = Self.groupActivities(items, isWorking: isWorking)
        if isWorking {
            items.append(Self.workingRow(status: workingStatus, since: workingSince))
        }
        self.workingStatus = workingStatus; self.workingSince = isWorking ? workingSince : nil
        updateWorkingTimer()
        if workingIndicator.isHidden == isWorking { workingIndicator.isHidden = !isWorking }
        workingIndicator.isWorking = isWorking
        let finished = wasWorking && !isWorking
        wasWorking = isWorking
        let switched = self.conversationID != conversationID
        if switched || finished { expandedActions.removeAll() }
        if switched { expandedMetrics.removeAll() }
        if let feedback = copyFeedback,
           switched || previous.first(where: { $0.id == feedback.id })?.text != items.first(where: { $0.id == feedback.id })?.text {
            copyFeedbackTask?.cancel()
            copyFeedback = nil
        }
        let resumeFollowing = followOutput && !followed
        followed = followOutput
        guard switched || finished || items != previous else {
            if resumeFollowing { scrollToEnd() }
            scheduleReadCheck()
            return
        }
        let savedPosition = pendingPosition ?? capturePosition()
        if let id = self.conversationID, let savedPosition { positions.values[id] = savedPosition }
        changingLayout = true
        defer { changingLayout = false; scheduleReadCheck() }
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
            pendingPosition = conversationID.flatMap { positions.values[$0] }
            if pendingPosition == nil { scrollToEnd() }
        } else if followOutput && (wasAtEnd || resumeFollowing) { scrollToEnd() }
        else {
            if case .anchor = savedPosition { pendingPosition = savedPosition }
            contentView.scroll(to: oldOrigin); reflectScrolledClipView(contentView)
        }
    }

    private func scrollToEnd() {
        pendingPosition = nil
        needsEndScroll = true
        needsLayout = true
    }

    public override func layout() {
        changingLayout = true
        defer { changingLayout = false; rememberPosition() }
        let margin = max(24, ((contentSize.width - Self.readableWidth) / 2).rounded(.down))
        if abs(transcript.textContainerInset.width - margin) > 0.5 {
            transcript.textContainerInset = NSSize(width: margin, height: 24)
        }
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
        guard contentSize.width > 0, contentSize.height > 0, !previous.isEmpty else { return }
        if let position = pendingPosition {
            pendingPosition = nil
            restorePosition(position)
        } else if needsEndScroll {
            needsEndScroll = false
            if let container = transcript.textContainer { transcript.layoutManager?.ensureLayout(for: container) }
            transcript.scrollRangeToVisible(NSRange(location: transcript.textStorage?.length ?? 0, length: 0))
        }
    }

    @objc private func viewportChanged() {
        workingIndicator.refreshAnimation()
        rememberPosition()
        scheduleReadCheck()
    }

    private func rememberPosition() {
        guard !changingLayout, pendingPosition == nil, !needsEndScroll,
              let id = conversationID, let position = capturePosition() else { return }
        positions.values[id] = position
    }

    private func capturePosition() -> TranscriptReadingPositions.Position? {
        guard !previous.isEmpty, contentSize.width > 0, contentSize.height > 0,
              let manager = transcript.layoutManager, let container = transcript.textContainer,
              let storage = transcript.textStorage, storage.length > 0 else { return nil }
        if needsEndScroll || isAtTranscriptEnd { return .end }
        let origin = contentView.bounds.origin
        let point = NSPoint(x: container.lineFragmentPadding,
                            y: max(0, origin.y - transcript.textContainerOrigin.y))
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let character = manager.characterIndexForGlyph(at: glyph)
        guard let index = ranges.firstIndex(where: { NSLocationInRange(character, $0) }) else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return .anchor(itemID: previous[index].id, character: character - ranges[index].location,
                       offset: origin.y - (line.minY + transcript.textContainerOrigin.y), fallbackY: origin.y)
    }

    private func restorePosition(_ position: TranscriptReadingPositions.Position) {
        guard let manager = transcript.layoutManager, let container = transcript.textContainer else { return }
        manager.ensureLayout(for: container)
        switch position {
        case .end:
            transcript.scrollRangeToVisible(NSRange(location: transcript.textStorage?.length ?? 0, length: 0))
        case let .anchor(itemID, character, offset, fallbackY):
            var y = fallbackY
            if let index = previous.firstIndex(where: { $0.id == itemID }), ranges[index].length > 0 {
                let location = ranges[index].location + min(character, ranges[index].length - 1)
                let glyph = manager.glyphIndexForCharacter(at: location)
                y = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    + transcript.textContainerOrigin.y + offset
            }
            contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            reflectScrolledClipView(contentView)
        }
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
                  !self.needsEndScroll, self.pendingPosition == nil, self.isUnreadResponseVisible else { return }
            self.onReadToEnd?(threadID, completionID)
        }
    }

    /// The live row: the agent's latest status plus elapsed turn time (kept in `phase`).
    public static func workingRow(status: String?, since: Date?, now: Date = Date()) -> TranscriptItem {
        let elapsed = since.map { max(0, now.timeIntervalSince($0)) }.flatMap { $0.isFinite && $0 < 1e9 ? Int($0) : nil }
        return TranscriptItem(id: "local-working", kind: "loading", text: status ?? "",
                              phase: elapsed.map { ResponseTiming.duration($0) })
    }

    private func updateWorkingTimer() {
        guard wasWorking, workingSince != nil else { workingTimer?.invalidate(); workingTimer = nil; return }
        guard workingTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.refreshWorkingRow() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        workingTimer = timer
    }

    /// Replaces only the trailing working row, so ticking never re-renders the transcript.
    private func refreshWorkingRow() {
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor,
              let last = previous.last, last.kind == "loading", let range = ranges.last, let storage = transcript.textStorage,
              NSMaxRange(range) == storage.length else { return }
        let row = Self.workingRow(status: workingStatus, since: workingSince)
        guard row != last else { return }
        let wasAtEnd = followed && isAtTranscriptEnd
        let rendered = render(row, expanded: false)
        changingLayout = true
        defer { changingLayout = false }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: rendered)
        storage.endEditing()
        previous[previous.count - 1] = row
        ranges[ranges.count - 1] = NSRange(location: range.location, length: rendered.length)
        if wasAtEnd { scrollToEnd() }
    }

    private func positionWorkingIndicator() {
        if wasWorking, let range = ranges.last, let manager = transcript.layoutManager, let container = transcript.textContainer {
            manager.ensureLayout(forCharacterRange: range)
            let glyph = manager.glyphIndexForCharacter(at: range.location + 6)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let frame = NSRect(x: transcript.textContainerOrigin.x + container.lineFragmentPadding,
                               y: transcript.textContainerOrigin.y + rect.midY - 10, width: 20, height: 20)
            if workingIndicator.frame != frame { workingIndicator.frame = frame }
            workingIndicator.refreshAnimation()
        }
    }

    /// The tool call the agent is running now: the latest activity of the current request,
    /// unless the agent has already moved on to writing text.
    static func currentActivity(_ items: [TranscriptItem]) -> TranscriptItem? {
        guard let last = items.last(where: { $0.kind != "loading" }), last.kind == "activity" else { return nil }
        return last
    }

    private func updateHover(at point: NSPoint?) {
        var id: String?
        if let point, let manager = transcript.layoutManager, let container = transcript.textContainer,
           let storage = transcript.textStorage, storage.length > 0 {
            let local = NSPoint(x: point.x - transcript.textContainerOrigin.x, y: point.y - transcript.textContainerOrigin.y)
            var fraction: CGFloat = 0
            let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if line.minY - 8 <= local.y, local.y <= line.maxY + 8 {
                let character = manager.characterIndexForGlyph(at: glyph)
                if let index = ranges.firstIndex(where: { NSLocationInRange(character, $0) }), previous[index].showsCopyControl {
                    id = previous[index].id
                }
            }
        }
        guard id != hoveredItemID else { return }
        hoveredItemID = id
        transcript.setNeedsDisplay(transcript.visibleRect)
    }

    // Each user message starts a new activity group. Assistant commentary stays
    // visible; all tool entries for that request share one disclosure row.
    /// One readable line for the running action. A Claude tool call arrives as its name
    /// and JSON input; show the name and its most telling field instead of raw JSON.
    nonisolated public static func activityHeadline(_ text: String, limit: Int = 120) -> String {
        var line = text
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        if parts.count == 2, !parts[0].contains(" "),
           let data = parts[1].data(using: .utf8),
           let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !input.isEmpty {
            let keys = ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt", "expression"]
            let value = keys.lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
            line = value.map { parts[0] + " · " + $0 } ?? parts[0]
        }
        line = line.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private static func groupActivities(_ items: [TranscriptItem], isWorking: Bool) -> [TranscriptItem] {
        var result: [TranscriptItem] = []
        var segment: [TranscriptItem] = []
        func appendSegment(active: Bool) {
            let actions = segment.filter { $0.kind == "activity" }
            // Show one copy control only after the response finishes. Older history
            // may omit phase, so fall back to its last non-commentary assistant item.
            let finalAnswer = active ? nil : (segment.last { $0.kind == "assistant" && $0.phase == "final_answer" && !$0.text.isEmpty }
                ?? segment.last { $0.kind == "assistant" && $0.phase != "commentary" && !$0.text.isEmpty })
            let responseTiming = segment.last(where: { $0.kind == "assistant" && $0.timing != nil })?.timing
            var inserted = false
            var showedAuthor = false
            for var item in segment {
                if item.kind == "compaction", item.phase == "inProgress", !active {
                    item.phase = "unconfirmed"
                    item.text = L10n.text("Сжатие контекста: завершение не подтверждено", "Context compaction: completion unconfirmed")
                }
                if item.kind == "assistant" {
                    item.timing = showedAuthor ? nil : responseTiming
                    item.showsAuthor = !showedAuthor
                    item.showsCopyControl = item.id == finalAnswer?.id
                    showedAuthor = true
                }
                guard item.kind == "activity" else { result.append(item); continue }
                guard !inserted, let first = actions.first else { continue }
                inserted = true
                let summary = L10n.text("Действия \(first.agentName ?? "Codex") · \(actions.count)", "\(first.agentName ?? "Codex") actions · \(actions.count)")
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
        if item.kind == "compaction" {
            let active = item.phase == "inProgress"
            let color = active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            let symbol = active ? "arrow.triangle.2.circlepath" : item.phase == "completed" ? "checkmark.circle" : "minus.circle"
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)
                    .applying(.init(paletteColors: [color])))
            attachment.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
            let spacer = NSMutableParagraphStyle()
            spacer.maximumLineHeight = 8
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 6), .paragraphStyle: spacer
            ]))
            let badgeStart = result.length
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  " + item.text))
            paragraph.firstLineHeadIndent = 12
            paragraph.headIndent = 12
            paragraph.tailIndent = -12
            paragraph.paragraphSpacingBefore = 8
            paragraph.paragraphSpacing = 12
            paragraph.lineSpacing = 2
            result.addAttributes([
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color, .paragraphStyle: paragraph,
                .compactionBadge: item.id, .compactionActive: active
            ], range: NSRange(location: badgeStart, length: result.length - badgeStart))
            // Keep paragraph terminators outside the badge so it hugs its content.
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph,
                .font: NSFont.systemFont(ofSize: 12)]))
            return result
        }
        if item.kind == "loading" {
            let font = NSFont.systemFont(ofSize: 12)
            result.append(NSAttributedString(string: "      " + item.text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            if let elapsed = item.phase {
                result.append(NSAttributedString(string: (item.text.isEmpty ? "" : "  ") + elapsed, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor
                ]))
            }
            result.append(NSAttributedString(string: "\n\n", attributes: [.font: font]))
            return result
        }
        if item.kind == "activity" {
            let title = item.phase ?? L10n.text("Действия \(item.agentName ?? "Codex")", "\(item.agentName ?? "Codex") actions")
            result.append(NSAttributedString(string: (expanded ? "▾ " : "▸ ") + title + (expanded ? "\n" : "\n\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .link: "contextdesk-action:" + item.id,
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
            ]))
            if !expanded { return result }
        } else {
            if (item.kind == "user" && item.phase != nil) || (item.kind != "user" && item.showsAuthor) {
                let title = item.kind == "user" ? item.phase ?? "" : (item.agentName ?? "Codex")
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
        var quoteIndex = 0
        for (index, block) in item.text.components(separatedBy: "```").enumerated() {
            let isCode = index % 2 == 1 || item.kind == "activity"
            let font = isCode ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: item.kind == "activity" ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            // Code and tool output stay literal, including link-like text.
            if !isCode && item.kind == "assistant" {
                appendQuotedText(block, item: item, quoteIndex: &quoteIndex, to: result, attributes: attributes)
            } else {
                result.append(isCode ? NSAttributedString(string: block, attributes: attributes)
                              : TranscriptLinks.render(block, attributes: attributes))
            }
        }
        if (item.kind == "user" || item.kind == "assistant"), item.showsCopyControl, !item.text.isEmpty {
            if !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n")) }
            let feedback = copyFeedback.flatMap { $0.id == item.id && $0.block == nil ? $0.succeeded : nil }
            result.append(copyControl(feedback: feedback,
                                      description: L10n.text("Скопировать полный текст сообщения", "Copy the full message text"),
                                      hoverItemID: item.id,
                                      attributes: [.link: "contextdesk-copy:" + item.id, .messageCopy: true]))
        }
        result.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        applyMessageStyle(item, to: result, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func copyControl(feedback: Bool?, description: String, hoverItemID: String? = nil,
                             attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let feedbackText = feedback.map { $0 ? L10n.text("Скопировано", "Copied") : L10n.text("Не удалось скопировать", "Could not copy") }
        let description = feedbackText ?? description
        let color: NSColor = feedback.map { $0 ? .systemGreen : .systemRed } ?? .secondaryLabelColor
        let symbol = feedback.map { $0 ? "checkmark" : "exclamationmark.circle" } ?? "doc.on.doc"
        let attachment = NSTextAttachment()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [color])))
        if let itemID = hoverItemID, feedback == nil {
            // Message copy controls appear while the pointer is over their message.
            let cell = HoverAttachmentCell(imageCell: image ?? NSImage())
            cell.isVisible = { [weak self] in self?.hoveredItemID == itemID }
            attachment.attachmentCell = cell
        } else {
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -3, width: 18, height: 18)
        }
        let result = NSMutableAttributedString(attachment: attachment)
        if let feedbackText {
            result.append(NSAttributedString(string: " " + feedbackText, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: color
            ]))
        }
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        result.addAttribute(.toolTip, value: description, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Only explicit Markdown quotes become cards. Prose and tool output are never guessed to be drafts.
    private func appendQuotedText(_ source: String, item: TranscriptItem, quoteIndex: inout Int,
                                  to result: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any]) {
        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard Self.quoteBody(lines[index]) != nil else {
                let start = index
                repeat { index += 1 } while index < lines.count && Self.quoteBody(lines[index]) == nil
                var text = lines[start..<index].joined(separator: "\n")
                if index < lines.count { text += "\n" }
                result.append(TranscriptTables.render(text, attributes: attributes))
                continue
            }
            var quoted: [String] = []
            while index < lines.count, let body = Self.quoteBody(lines[index]) {
                quoted.append(body)
                index += 1
            }
            let body = TranscriptLinks.render(quoted.joined(separator: "\n"), attributes: attributes)
            let start = result.length
            let feedback = copyFeedback.flatMap { $0.id == item.id && $0.block == quoteIndex ? $0.succeeded : nil }
            let controlAttributes: [NSAttributedString.Key: Any] = [
                .link: "contextdesk-quote-copy", .quoteCopy: body.string, .quoteIndex: quoteIndex
            ]
            result.append(copyControl(feedback: feedback,
                                      description: L10n.text("Скопировать текст блока", "Copy the block text"),
                                      attributes: controlAttributes))
            // Keep the control paragraph aligned as one unit, including its newline.
            result.append(NSAttributedString(string: "\n", attributes: controlAttributes))
            result.append(body)
            result.append(NSAttributedString(string: "\n", attributes: attributes))
            result.addAttribute(.quoteCard, value: quoteIndex, range: NSRange(location: start, length: result.length - start))
            result.append(NSAttributedString(string: "\n", attributes: attributes))
            quoteIndex += 1
        }
    }

    private static func quoteBody(_ line: String) -> String? {
        let prefix = line.prefix(while: { $0 == " " })
        guard prefix.count <= 3 else { return nil }
        let trimmed = line.dropFirst(prefix.count)
        guard trimmed.first == ">" else { return nil }
        var body = trimmed.dropFirst()
        if body.first == " " || body.first == "\t" { body = body.dropFirst() }
        return String(body)
    }

    private func applyMessageStyle(_ item: TranscriptItem, to text: NSMutableAttributedString, range: NSRange) {
        guard item.kind == "user" || item.kind == "assistant", range.length > 2 else { return }
        let width = max(1, transcript.textContainer?.containerSize.width ?? 600)
        let outgoing = item.kind == "user"
        let inset = outgoing ? Self.outgoingInset(item, width: width) : 0
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
            footer.paragraphSpacingBefore = outgoing ? 12 : 4
            // A user's copy control sits under the bubble's trailing edge.
            if outgoing { footer.alignment = .right; footer.tailIndent = -6 }
            text.addAttribute(.paragraphStyle, value: footer, range: copyRange)
        }
        text.enumerateAttribute(.quoteCard, in: range) { value, cardRange, _ in
            guard value != nil else { return }
            let card = paragraph.mutableCopy() as! NSMutableParagraphStyle
            card.firstLineHeadIndent = 16; card.headIndent = 16; card.tailIndent = -16
            card.paragraphSpacing = 4
            text.addAttribute(.paragraphStyle, value: card, range: cardRange)
        }
        text.enumerateAttribute(.quoteCopy, in: range) { value, controlRange, _ in
            guard value != nil else { return }
            let control = paragraph.mutableCopy() as! NSMutableParagraphStyle
            control.alignment = .right; control.tailIndent = -16
            control.paragraphSpacingBefore = 12; control.paragraphSpacing = 12
            text.addAttribute(.paragraphStyle, value: control, range: controlRange)
        }
        TranscriptTables.restoreStyles(in: text, range: range)
        // Leave the final empty paragraph, and a user's copy control, outside the bubble.
        var bubble = NSRange(location: range.location, length: range.length - 1)
        if outgoing {
            text.enumerateAttribute(.messageCopy, in: range) { value, copyRange, stop in
                guard value != nil else { return }
                bubble.length = max(0, copyRange.location - 1 - range.location); stop.pointee = true
            }
        }
        text.addAttribute(.messageBubble, value: item.id, range: bubble)
        if outgoing { text.addAttribute(.outgoingBubble, value: inset, range: bubble) }
    }

    /// Left edge of a user bubble that hugs its text, up to 78% of the column.
    static func outgoingInset(_ item: TranscriptItem, width: CGFloat) -> CGFloat {
        let maxText = max(80, width * 0.78 - 32)
        let body = NSAttributedString(string: item.text.isEmpty ? " " : item.text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        var textWidth = body.boundingRect(with: NSSize(width: maxText, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        if let phase = item.phase {
            let header = NSAttributedString(string: phase, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            textWidth = max(textWidth, header.size().width)
        }
        // Line fragment padding and rounding must not wrap the last word of a hugging bubble.
        textWidth = min(maxText, max(40, textWidth.rounded(.up) + 12))
        return max(0, width - textWidth - 32)
    }

    private func rerenderItem(id: String) {
        guard let index = previous.firstIndex(where: { $0.id == id }), ranges.indices.contains(index),
              let storage = transcript.textStorage else { return }
        let origin = contentView.bounds.origin
        let rendered = render(previous[index], expanded: expandedActions.contains(id))
        let oldRange = ranges[index], delta = rendered.length - oldRange.length
        storage.replaceCharacters(in: oldRange, with: rendered)
        ranges[index].length = rendered.length
        for next in (index + 1)..<ranges.count { ranges[next].location += delta }
        editCount += 1
        needsLayout = true
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func showCopyFeedback(id: String, succeeded: Bool, block: Int?) {
        let previousID = copyFeedback?.id
        copyFeedbackTask?.cancel()
        copyFeedback = (id, succeeded, block)
        if let previousID, previousID != id { rerenderItem(id: previousID) }
        rerenderItem(id: id)
        copyFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            self.copyFeedback = nil
            self.rerenderItem(id: id)
        }
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let value = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if value == "contextdesk-quote-copy" {
            guard let storage = transcript.textStorage, charIndex >= 0, charIndex < storage.length,
                  let body = storage.attribute(.quoteCopy, at: charIndex, effectiveRange: nil) as? String,
                  let block = storage.attribute(.quoteIndex, at: charIndex, effectiveRange: nil) as? Int,
                  let index = ranges.firstIndex(where: { NSLocationInRange(charIndex, $0) }) else { return true }
            let id = previous[index].id
            pasteboard.clearContents()
            showCopyFeedback(id: id, succeeded: pasteboard.setString(body, forType: .string), block: block)
            return true
        }
        if value.hasPrefix("contextdesk-copy:") {
            let id = String(value.dropFirst("contextdesk-copy:".count))
            guard let item = previous.first(where: { $0.id == id && ($0.kind == "user" || $0.kind == "assistant") }),
                  item.showsCopyControl, !item.text.isEmpty else { return true }
            // Copy the source body only, never rendered headers, disclosures or adjacent messages.
            pasteboard.clearContents()
            let succeeded = pasteboard.setString(item.text, forType: .string)
            showCopyFeedback(id: id, succeeded: succeeded, block: nil)
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
    var hoverChanged: ((NSPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        didDrawText?()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverChanged?(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverChanged?(nil)
    }
}

/// Keeps its place in the layout and stays clickable, but draws only while `isVisible`.
private final class HoverAttachmentCell: NSTextAttachmentCell {
    var isVisible: () -> Bool = { true }
    override func cellSize() -> NSSize { NSSize(width: 18, height: 18) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard isVisible(), let image else { return }
        let size = image.size
        let rect = NSRect(x: cellFrame.midX - size.width / 2, y: cellFrame.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

private extension NSAttributedString.Key {
    static let compactionBadge = NSAttributedString.Key("ContextDeskCompactionBadge")
    static let compactionActive = NSAttributedString.Key("ContextDeskCompactionActive")
    static let quoteCard = NSAttributedString.Key("ContextDeskQuoteCard")
    static let quoteCopy = NSAttributedString.Key("ContextDeskQuoteCopy")
    static let quoteIndex = NSAttributedString.Key("ContextDeskQuoteIndex")
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
        storage.enumerateAttribute(.compactionBadge, in: characters) { value, range, _ in
            guard value != nil else { return }
            var fullRange = NSRange()
            _ = storage.attribute(.compactionBadge, at: range.location, longestEffectiveRange: &fullRange,
                                  in: NSRange(location: 0, length: storage.length))
            let glyphs = glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            let rect = bounds.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -10, dy: -6)
            let active = storage.attribute(.compactionActive, at: range.location, effectiveRange: nil) as? Bool ?? false
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            (active ? NSColor.controlAccentColor.withAlphaComponent(0.08)
                    : NSColor.quaternaryLabelColor.withAlphaComponent(0.07)).setFill()
            path.fill()
            (active ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                    : NSColor.separatorColor.withAlphaComponent(0.35)).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
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
            guard let inset = storage.attribute(.outgoingBubble, at: range.location, effectiveRange: nil) as? CGFloat else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            let width = container.containerSize.width
            let top = bounds.minY - 10
            let rect = NSRect(x: origin.x + inset + 2, y: origin.y + top,
                              width: max(1, width - inset - 4), height: bounds.maxY + 10 - top)
            DeskPalette.outgoingBubble.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
        }
        storage.enumerateAttribute(.quoteCard, in: characters) { value, range, _ in
            guard value != nil else { return }
            var fullRange = NSRange()
            _ = storage.attribute(.quoteCard, at: range.location, longestEffectiveRange: &fullRange,
                                  in: NSRange(location: 0, length: storage.length))
            let glyphs = glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            let rect = NSRect(x: origin.x + 2, y: origin.y + bounds.minY - 4,
                              width: max(1, container.containerSize.width - 4), height: bounds.height + 8)
            let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
            NSColor.controlBackgroundColor.setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
