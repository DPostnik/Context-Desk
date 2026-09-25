import AppKit
import SwiftUI

/// Shared neutral surfaces for the light SwiftUI shell and native transcript.
public enum DeskPalette {
    public static let canvas = Color.white
    public static let sidebar = Color(white: 0.975)
    public static let subtle = Color(white: 0.96)
    public static let selection = Color(white: 0.925)
    public static let border = Color(white: 0.89)
    public static let focusBorder = Color(white: 0.66)
    public static let ink = Color(white: 0.12)
    public static let outgoingBubble = NSColor(white: 0.95, alpha: 1)
}
