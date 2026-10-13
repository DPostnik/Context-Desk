import ContextCore
import ContextTranscript
import SwiftUI

/// Applies the interface zoom to text that has no explicit style and to standard controls.
struct InterfaceZoomed: ViewModifier {
    func body(content: Content) -> some View {
        let scale = InterfaceZoom.shared.scale
        content.font(.ui(.body)).controlSize(scale >= 1.25 ? .large : .regular)
    }
}

/// View menu commands, as in Safari and Xcode: ⌘= zooms in, ⌘− zooms out, ⌘0 returns to actual size.
struct InterfaceZoomMenu: View {
    private let zoom = InterfaceZoom.shared
    var body: some View {
        Button(L10n.text("Увеличить", "Zoom In")) { zoom.zoomIn() }
            .keyboardShortcut("=", modifiers: .command).disabled(!zoom.canZoomIn)
        Button(L10n.text("Уменьшить", "Zoom Out")) { zoom.zoomOut() }
            .keyboardShortcut("-", modifiers: .command).disabled(!zoom.canZoomOut)
        Button(L10n.text("Фактический размер (\(zoom.percent)%)", "Actual Size (\(zoom.percent)%)")) { zoom.reset() }
            .keyboardShortcut("0", modifiers: .command).disabled(zoom.isActualSize)
    }
}

/// Settings row for the same zoom; changes apply immediately.
struct InterfaceZoomSettings: View {
    private let zoom = InterfaceZoom.shared
    var body: some View {
        Section(L10n.text("Масштаб интерфейса", "Interface scale")) {
            Picker(L10n.text("Размер текста и интерфейса", "Text and interface size"),
                   selection: Binding(get: { zoom.scale }, set: { zoom.set($0) })) {
                ForEach(InterfaceZoom.steps, id: \.self) { step in
                    Text(step == 1 ? L10n.text("100% (стандарт)", "100% (default)") : "\(Int((step * 100).rounded()))%").tag(step)
                }
            }
            .pointingHandCursor()
            Text(L10n.text("Для 4K-монитора 24–27″ обычно подходит 125–160%. Горячие клавиши: ⌘= увеличить, ⌘− уменьшить, ⌘0 — 100%.",
                           "For a 24–27″ 4K monitor, 125–160% usually works well. Shortcuts: ⌘= zoom in, ⌘− zoom out, ⌘0 back to 100%."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }
}
