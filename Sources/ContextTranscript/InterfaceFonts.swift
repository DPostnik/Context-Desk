import AppKit
import ContextCore
import SwiftUI

public extension Font {
    /// A text style sized by the interface zoom. At actual size it is exactly the system style.
    @MainActor static func ui(_ style: Font.TextStyle, design: Font.Design? = nil) -> Font {
        let scale = InterfaceZoom.shared.scale
        if scale == 1 { return design.map { .system(style, design: $0) } ?? .system(style) }
        let base = NSFont.preferredFont(forTextStyle: style.appKit).pointSize
        return .system(size: (base * scale).rounded(), weight: style == .headline ? .bold : .regular, design: design ?? .default)
    }

    /// A fixed point size multiplied by the interface zoom.
    @MainActor static func ui(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: InterfaceZoom.shared.scaled(size), weight: weight, design: design)
    }
}

public extension CGFloat {
    /// A layout length (padding, row height, icon frame, column width) scaled with the interface zoom,
    /// so spacing grows together with `Font.ui` text instead of squeezing it.
    @MainActor static func ui(_ value: CGFloat) -> CGFloat { InterfaceZoom.shared.scaled(value) }
}

public extension View {
    /// A small spinner (16 pt at actual size) that grows with the interface zoom; control sizes jump 16 → 32 pt.
    @MainActor func uiSmallSpinner() -> some View {
        let scale = InterfaceZoom.shared.scale
        return controlSize(.small).scaleEffect(scale).frame(width: .ui(16), height: .ui(16))
    }
}

private extension Font.TextStyle {
    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
