import AppKit
import SwiftUI

extension View {
    func pointingHandCursor() -> some View {
        modifier(ControlPointerModifier())
    }
}

private struct ControlPointerModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            // Let SwiftUI own cursor priority and restoration alongside its controls.
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.overlay(ControlCursorRegion())
        }
    }
}

/// Apply the cursor only to the disclosure's clickable header, not its selectable text.
struct PointerDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    configuration.label
                }.contentShape(Rectangle())
            }.buttonStyle(PointerButtonStyle(base: .plain))
            if configuration.isExpanded { configuration.content }
        }
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
