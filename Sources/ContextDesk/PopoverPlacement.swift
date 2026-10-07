import AppKit
import SwiftUI

/// Where a popover opens and how tall its scrolling part may be, chosen from the screen space
/// around its anchor. AppKit only fits a popover to the screen when it is shown; content that
/// grows afterwards (late data) extends past the screen edge instead of moving the popover.
struct PopoverPlacement: Equatable {
    var edge: Edge
    var listHeight: CGFloat

    static let fallback = PopoverPlacement(edge: .trailing, listHeight: PopoverPlacement.preferredListHeight)
    static let preferredListHeight: CGFloat = 340
    /// Everything in the limits popover except the bucket list, plus arrow and screen margin.
    static let chromeHeight: CGFloat = 300
    static let minimumListHeight: CGFloat = 120

    /// `anchor` and `visible` are screen rectangles (origin bottom-left).
    static func choose(anchor: CGRect, visible: CGRect) -> PopoverPlacement {
        let full = chromeHeight + preferredListHeight
        let below = anchor.midY - visible.minY
        let above = visible.maxY - anchor.midY
        // Beside the anchor the popover is centred on it and slid inside the screen when shown,
        // but later growth spreads both ways, so each half needs room.
        if below >= full / 2 && above >= full / 2 { return PopoverPlacement(edge: .trailing, listHeight: preferredListHeight) }
        let spaceAbove = visible.maxY - anchor.maxY
        let spaceBelow = anchor.minY - visible.minY
        if spaceAbove >= full || spaceAbove >= spaceBelow {
            return PopoverPlacement(edge: .top, listHeight: fitted(spaceAbove))
        }
        return PopoverPlacement(edge: .bottom, listHeight: fitted(spaceBelow))
    }

    private static func fitted(_ space: CGFloat) -> CGFloat {
        min(preferredListHeight, max(minimumListHeight, space - chromeHeight))
    }
}

/// Exposes the screen frame of the view it backs, for placing popovers attached to it.
final class ScreenFrameProbe {
    fileprivate weak var view: NSView?

    var placement: PopoverPlacement {
        guard let view, let window = view.window, let screen = window.screen ?? NSScreen.main else { return .fallback }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        return PopoverPlacement.choose(anchor: anchor, visible: screen.visibleFrame)
    }
}

struct ScreenFrameReader: NSViewRepresentable {
    let probe: ScreenFrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { probe.view = view }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
