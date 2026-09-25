import AppKit
import SwiftUI
import ContextCore

struct ChatRow<Content: View>: NSViewRepresentable {
    let chat: Chat
    let enabled: Bool
    let activate: () -> Void
    let move: (String) -> Bool
    let targeted: (Bool) -> Void
    let actions: [ChatRowAction]
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> ChatRowView {
        let view = ChatRowView()
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
    func updateNSView(_ view: ChatRowView, context: Context) {
        (view.subviews.first as? NSHostingView<Content>)?.rootView = content
        view.chatID = chat.id
        view.projectID = chat.projectID
        view.archived = chat.isArchived
        view.title = chat.title
        view.toolTip = chat.title
        view.isInteractionEnabled = enabled
        view.activate = activate
        view.move = move
        view.targeted = targeted
        view.actions = actions
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(chat.title)
        view.setAccessibilityEnabled(enabled)
    }
}

struct ChatRowAction {
    let title: String
    var enabled = true
    let perform: () -> Void
}

final class ChatRowView: SidebarRowView {
    static let pasteboardType = NSPasteboard.PasteboardType("com.contextdesk.chat-order")
    var chatID = ""
    var projectID = UUID()
    var archived = false
    var move: (String) -> Bool = { _ in false }
    var actions: [ChatRowAction] = []
    override var dragType: NSPasteboard.PasteboardType { Self.pasteboardType }
    override var dragID: String { chatID }
    override var dragGroup: String { projectID.uuidString + (archived ? ":archive" : ":active") }
    override func performMove(from source: SidebarRowView) -> Bool {
        guard let source = source as? ChatRowView else { return false }
        return move(source.chatID)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isInteractionEnabled else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions { menu.addItem(ChatActionMenuItem(action)) }
        return menu
    }
}

private final class ChatActionMenuItem: NSMenuItem {
    private let callback: () -> Void
    init(_ action: ChatRowAction) {
        callback = action.perform
        super.init(title: action.title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = action.enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { callback() }
}
