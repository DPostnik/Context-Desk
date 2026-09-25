import AppKit
import SwiftUI

extension View {
    func pointingHandCursor() -> some View {
        background(ControlCursorRegion())
    }
}

/// Preserve the native button behavior and appearance while adding its cursor region.
struct PointerButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let base: Base

    func makeBody(configuration: Configuration) -> some View {
        base.makeBody(configuration: configuration).pointingHandCursor()
    }
}

private struct ControlCursorRegion: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        guard view.isControlEnabled != isEnabled else { return }
        view.isControlEnabled = isEnabled
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var isControlEnabled = true

        // The region supplies a cursor only; clicks still reach the SwiftUI control.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            if isControlEnabled && !visibleRect.isEmpty {
                addCursorRect(visibleRect, cursor: .pointingHand)
            }
        }
    }
}
