import AppKit
import SwiftUI
import Testing
@testable import ContextDesk

@MainActor private final class TrackingProjectHeader: ProjectHeaderView {
    var dragStarts = 0
    override func startDrag(with event: NSEvent) { dragStarts += 1 }
}

@Test @MainActor func projectHeaderOwnsMouseTrackingOverItsHostedLabel() throws {
    let view = TrackingProjectHeader(frame: NSRect(x: 0, y: 0, width: 260, height: 64))
    let label = NSHostingView(rootView: Button("Project") {})
    label.frame = view.bounds
    view.addSubview(label)
    #expect(view.hitTest(NSPoint(x: 30, y: 30)) === view)
    var clicks = 0
    view.activate = { clicks += 1 }
    func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 30) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown, x: 30))
    view.mouseDragged(with: try event(.leftMouseDragged, x: 32))
    view.mouseUp(with: try event(.leftMouseUp, x: 32))
    #expect(clicks == 1)
    #expect(view.dragStarts == 0)
    view.mouseDown(with: try event(.leftMouseDown, x: 30))
    view.mouseDragged(with: try event(.leftMouseDragged, x: 36))
    view.mouseDragged(with: try event(.leftMouseDragged, x: 60))
    view.mouseUp(with: try event(.leftMouseUp, x: 60))
    #expect(view.dragStarts == 1)
    #expect(clicks == 1) // Dragging must not select/collapse the project.
    view.mouseDown(with: try event(.leftMouseDown, x: 30))
    view.mouseUp(with: try event(.leftMouseUp, x: 300))
    #expect(clicks == 1)
    #expect(view.accessibilityPerformPress())
    #expect(clicks == 2)
}

@Test @MainActor func projectHeaderAcceptsOnlyMatchingLocalProjectDrags() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let source = ProjectHeaderView(frame: NSRect(x: 0, y: 0, width: 260, height: 64))
    let target = ProjectHeaderView(frame: NSRect(x: 0, y: 70, width: 260, height: 64))
    window.contentView?.addSubview(source)
    window.contentView?.addSubview(target)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally(); window.orderOut(nil) }
    pasteboard.setString(source.projectID.uuidString, forType: ProjectHeaderView.pasteboardType)
    #expect(target.registeredDraggedTypes.contains(ProjectHeaderView.pasteboardType))
    #expect(target.sourceID(source, pasteboard: pasteboard) == source.projectID)
    #expect(source.sourceID(source, pasteboard: pasteboard) == nil)
    #expect(target.sourceID(nil, pasteboard: pasteboard) == nil)
    pasteboard.clearContents()
    pasteboard.setString(UUID().uuidString, forType: ProjectHeaderView.pasteboardType)
    #expect(target.sourceID(source, pasteboard: pasteboard) == nil)
    pasteboard.clearContents()
    pasteboard.setString(source.projectID.uuidString, forType: .string)
    #expect(target.sourceID(source, pasteboard: pasteboard) == nil)
    pasteboard.clearContents()
    pasteboard.setString(source.projectID.uuidString, forType: ProjectHeaderView.pasteboardType)
    source.removeFromSuperview()
    #expect(target.sourceID(source, pasteboard: pasteboard) == nil)
}

@MainActor private final class ProjectDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight = .none
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@Test @MainActor func projectHeaderDropRoutesMoveAndClearsHighlight() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let source = ProjectHeaderView(), target = ProjectHeaderView()
    window.contentView?.addSubview(source)
    window.contentView?.addSubview(target)
    let info = ProjectDragInfo()
    info.draggingSource = source
    info.draggingDestinationWindow = window
    info.draggingPasteboard.setString(source.projectID.uuidString, forType: ProjectHeaderView.pasteboardType)
    defer { info.draggingPasteboard.releaseGlobally(); window.orderOut(nil) }
    var highlighted = false
    var moved: [UUID] = []
    target.targeted = { highlighted = $0 }
    target.move = { moved.append($0); return true }
    #expect(target.draggingEntered(info) == .move)
    #expect(highlighted)
    #expect(moved.isEmpty)
    #expect(target.prepareForDragOperation(info))
    #expect(target.performDragOperation(info))
    #expect(moved == [source.projectID])
    #expect(!highlighted)
    _ = target.draggingEntered(info)
    target.draggingExited(info)
    #expect(!highlighted)
    #expect(moved.count == 1)
    info.draggingSource = nil
    #expect(target.draggingEntered(info).isEmpty)
    #expect(!target.prepareForDragOperation(info))
    #expect(!target.performDragOperation(info))
    #expect(moved.count == 1)
}
