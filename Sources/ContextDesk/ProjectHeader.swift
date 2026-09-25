import AppKit
import SwiftUI
import ContextCore

/// Own mouse tracking instead of attaching a drag recognizer to a SwiftUI Button.
struct ProjectHeader<Content: View>: NSViewRepresentable {
    let project: Project
    let expanded: Bool
    let activate: () -> Void
    let move: (UUID) -> Bool
    let targeted: (Bool) -> Void
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> ProjectHeaderView {
        let view = ProjectHeaderView()
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    func updateNSView(_ view: ProjectHeaderView, context: Context) {
        (view.subviews.first as? NSHostingView<Content>)?.rootView = content
        view.projectID = project.id
        view.title = project.name
        view.toolTip = project.path
        view.activate = activate
        view.move = move
        view.targeted = targeted
        view.moveUp = moveUp
        view.moveDown = moveDown
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(project.name)
        view.setAccessibilityValue(expanded ? L10n.text("Развёрнуто", "Expanded") : L10n.text("Свёрнуто", "Collapsed"))
    }
}

class ProjectHeaderView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("com.contextdesk.project-order")
    var projectID = UUID()
    var title = ""
    var activate: () -> Void = {}
    var move: (UUID) -> Bool = { _ in false }
    var targeted: (Bool) -> Void = { _ in }
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    private var pressedEvent: NSEvent?
    private var startedDrag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.pasteboardType])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The label is display-only: mouse events must reach this tracking view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .openHand) }
    override func accessibilityPerformPress() -> Bool { activate(); return true }

    override func mouseDown(with event: NSEvent) {
        pressedEvent = event
        startedDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressedEvent, !startedDrag else { return }
        let delta = NSPoint(x: event.locationInWindow.x - pressedEvent.locationInWindow.x,
                            y: event.locationInWindow.y - pressedEvent.locationInWindow.y)
        guard hypot(delta.x, delta.y) >= 4 else { return }
        startedDrag = true
        startDrag(with: pressedEvent)
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressedEvent = nil; startedDrag = false }
        guard pressedEvent != nil, !startedDrag,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }
    func startDrag(with event: NSEvent) {
        let payload = NSPasteboardItem()
        payload.setString(projectID.uuidString, forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: payload)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        (title as NSString).draw(at: NSPoint(x: 12, y: max(0, bounds.midY - 8)),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        image.unlockFocus()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pressedEvent = nil
        startedDrag = false
        targeted(false)
    }

    func sourceID(_ source: Any?, pasteboard: NSPasteboard) -> UUID? {
        guard let source = source as? ProjectHeaderView, let window, source.window === window,
              source.projectID != projectID,
              pasteboard.pasteboardItems?.count == 1,
              let value = pasteboard.string(forType: Self.pasteboardType),
              let id = UUID(uuidString: value), id == source.projectID else { return nil }
        return id
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let valid = sourceID(sender.draggingSource, pasteboard: sender.draggingPasteboard) != nil
        targeted(valid)
        return valid ? .move : []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted(false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        sourceID(sender.draggingSource, pasteboard: sender.draggingPasteboard) != nil
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        targeted(false)
        guard let id = sourceID(sender.draggingSource, pasteboard: sender.draggingPasteboard) else { return false }
        return move(id)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { targeted(false) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let up = menu.addItem(withTitle: L10n.text("Переместить выше", "Move up"), action: #selector(performMoveUp), keyEquivalent: "")
        up.target = self; up.isEnabled = moveUp != nil
        let down = menu.addItem(withTitle: L10n.text("Переместить ниже", "Move down"), action: #selector(performMoveDown), keyEquivalent: "")
        down.target = self; down.isEnabled = moveDown != nil
        return menu
    }
    @objc private func performMoveUp() { moveUp?() }
    @objc private func performMoveDown() { moveDown?() }
}
