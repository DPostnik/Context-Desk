import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ContextCore
@testable import ContextDesk

struct PopoverPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func staysBesideAnchorWithRoomAboveAndBelow() {
        let placement = PopoverPlacement.choose(anchor: CGRect(x: 20, y: 430, width: 240, height: 30), visible: screen)
        #expect(placement == PopoverPlacement(edge: .trailing, listHeight: PopoverPlacement.preferredListHeight))
    }

    @Test func opensAboveAnchorNearScreenBottom() {
        let placement = PopoverPlacement.choose(anchor: CGRect(x: 20, y: 90, width: 240, height: 30), visible: screen)
        #expect(placement == PopoverPlacement(edge: .top, listHeight: PopoverPlacement.preferredListHeight))
    }

    @Test func opensBelowAnchorNearScreenTop() {
        let placement = PopoverPlacement.choose(anchor: CGRect(x: 20, y: 800, width: 240, height: 30), visible: screen)
        #expect(placement == PopoverPlacement(edge: .bottom, listHeight: PopoverPlacement.preferredListHeight))
    }

    @Test func shrinksListOnShortScreen() {
        let short = CGRect(x: 0, y: 0, width: 1280, height: 560)
        let placement = PopoverPlacement.choose(anchor: CGRect(x: 20, y: 60, width: 240, height: 30), visible: short)
        #expect(placement.edge == .top)
        #expect(placement.listHeight == 560 - 90 - PopoverPlacement.chromeHeight)
    }
}

/// The limits popover keeps one height in every state, within the space `PopoverPlacement` reserves.
@Test @MainActor func limitsPopoverHeightIsStableAndFitsReservedSpace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    func height(_ list: CGFloat) -> CGFloat {
        NSHostingView(rootView: AccountLimitsView(model: model, maxListHeight: list)).fittingSize.height
    }
    let full = height(PopoverPlacement.preferredListHeight)
    #expect(full - PopoverPlacement.preferredListHeight <= PopoverPlacement.chromeHeight)
    let short = height(PopoverPlacement.minimumListHeight)
    #expect(full - short == PopoverPlacement.preferredListHeight - PopoverPlacement.minimumListHeight)
}
