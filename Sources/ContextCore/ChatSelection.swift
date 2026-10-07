import Foundation

/// Sidebar multi-selection: Command toggles a chat, Shift extends a range in one project's order.
public struct ChatSelection: Equatable, Sendable {
    public private(set) var ids: Set<String> = []
    public private(set) var anchor: String?

    public init() {}

    public var isEmpty: Bool { ids.isEmpty }
    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The first toggle also keeps the currently open chat, as in Finder.
    public mutating func toggle(_ id: String, current: String? = nil, eligible: Set<String> = []) {
        if ids.isEmpty, let current, current != id, eligible.contains(current) { ids.insert(current) }
        if ids.remove(id) == nil { ids.insert(id) }
        anchor = id
    }

    public mutating func extend(to id: String, in ordered: [String], current: String? = nil) {
        let start = anchor ?? current
        guard let start, let from = ordered.firstIndex(of: start), let to = ordered.firstIndex(of: id) else {
            ids.insert(id); anchor = id; return
        }
        ids.formUnion(ordered[min(from, to)...max(from, to)])
        if anchor == nil { anchor = start }
    }

    public mutating func select(_ chats: [String]) {
        ids.formUnion(chats)
        anchor = chats.last ?? anchor
    }

    public mutating func clear() { ids = []; anchor = nil }

    /// Drop chats that were archived, deleted or otherwise left the active sidebar.
    public mutating func prune(keeping valid: Set<String>) {
        ids.formIntersection(valid)
        if let anchor, !valid.contains(anchor) { self.anchor = nil }
    }
}
