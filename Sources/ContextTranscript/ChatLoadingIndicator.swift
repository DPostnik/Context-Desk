import ContextCore
import SwiftUI

/// Shared by the initial chat placeholder and the native transcript.
public struct ChatLoadingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * .pi * 2 / 1.6
            let pulse = reduceMotion ? 1 : (sin(phase) + 1) / 2
            Circle()
                .fill(Color.primary)
                .frame(width: 12, height: 12)
                .scaleEffect(0.75 + 0.25 * pulse)
                .opacity(0.55 + 0.45 * pulse)
                .frame(width: 20, height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Загрузка", "Loading"))
    }
}
