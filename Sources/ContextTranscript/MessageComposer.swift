import ContextCore
import AppKit
import SwiftUI

public struct MessageComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let onSubmit: () -> Void
    public init(text: Binding<String>, focused: Binding<Bool>, onSubmit: @escaping () -> Void) {
        _text = text; _focused = focused; self.onSubmit = onSubmit
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // The viewport follows SwiftUI's proposal, never the document's text size.
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 0, height: 84))
    }
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = WidthBoundTextScrollView()
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 84))
        editor.minSize = NSSize(width: 0, height: 84)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.setAccessibilityLabel(L10n.text("Сообщение", "Message"))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.onSubmit = onSubmit
        if editor.string != text { editor.string = text }
    }
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposer
        init(_ parent: MessageComposer) { self.parent = parent }
        public func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
        public func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        public func textDidEndEditing(_ notification: Notification) { parent.focused = false }
    }
}

/// Autoresizing alone can preserve an oversized document after SwiftUI resizes
/// its viewport. Constrain TextKit to the actual clip width on every layout.
@MainActor public class WidthBoundTextScrollView: NSScrollView {
    public override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView, contentSize.width > 0 else { return }
        let width = contentSize.width
        if abs(editor.frame.width - width) > 0.5 {
            editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        }
        if contentView.bounds.origin.x != 0 {
            contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
    }
}

public final class ComposerTextView: NSTextView {
    public var onSubmit: (() -> Void)?
    public override func keyDown(with event: NSEvent) {
        // Let the input method confirm marked text before interpreting Return.
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
            else if !event.isARepeat { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }
}
