import Foundation

/// The notch cut-out of a built-in display, in points. Screens without a notch have no island.
/// Geometry follows Coucou (MIT, github.com/Louis-CFM/coucou): the menu-bar areas left and right
/// of the cut-out are reported by AppKit, the notch is the width between them.
public struct NotchGeometry: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }

    public init?(screenWidth: CGFloat, safeAreaTop: CGFloat, auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?) {
        guard safeAreaTop > 0, let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth else { return nil }
        let width = screenWidth - left - right
        guard width > 40, width < screenWidth / 2 else { return nil }
        self.init(width: width, height: safeAreaTop)
    }
}

/// User choices made inside the island itself.
public struct NotchPreferences: Codable, Equatable, Sendable {
    /// Hide the island while no agent works, waits for the user or has an unseen result.
    public var autoHide = true
    public var sound = true
    public init(autoHide: Bool = true, sound: Bool = true) { self.autoHide = autoHide; self.sound = sound }

    public static let defaultsKey = "notchIslandPreferences"
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// One chat as the island shows it. Built from app state; never sent anywhere.
public struct NotchChat: Identifiable, Equatable, Sendable {
    public enum Phase: Int, Comparable, Sendable {
        /// Ordered by urgency: the island leads with the chat that needs the user most.
        case waiting = 0, working = 1, finished = 2
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    public var id: String
    public var title: String
    public var project: String
    public var phase: Phase
    public var activity: String?
    public var since: Date?
    public var updated: Date
    public init(id: String, title: String, project: String, phase: Phase, activity: String? = nil, since: Date? = nil, updated: Date) {
        self.id = id; self.title = title; self.project = project; self.phase = phase
        self.activity = activity; self.since = since; self.updated = updated
    }

    /// Only chats with something to show; the most urgent and most recent first.
    public static func phase(running: Bool, waiting: Bool, unread: Bool) -> Phase? {
        waiting ? .waiting : running ? .working : unread ? .finished : nil
    }
    public static func ordered(_ chats: [NotchChat], limit: Int = 8) -> [NotchChat] {
        Array(chats.sorted { $0.phase != $1.phase ? $0.phase < $1.phase : $0.updated > $1.updated }.prefix(limit))
    }
}

/// The resting look of the island, from the chats it shows.
public enum NotchSummary: Hashable, Sendable {
    case idle
    case working(Int)
    case waiting(Int)
    case finished(Int)

    public init(_ chats: [NotchChat]) {
        let waiting = chats.filter { $0.phase == .waiting }.count
        let working = chats.filter { $0.phase == .working }.count
        let finished = chats.filter { $0.phase == .finished }.count
        self = waiting > 0 ? .waiting(waiting) : working > 0 ? .working(working) : finished > 0 ? .finished(finished) : .idle
    }
    public var isIdle: Bool { self == .idle }
}

/// What changed between two snapshots: drives the sound and the short "peek" animation.
public struct NotchTransition: Equatable, Sendable {
    public var finished: [String] = []
    public var newlyWaiting: [String] = []
    public init(finished: [String] = [], newlyWaiting: [String] = []) { self.finished = finished; self.newlyWaiting = newlyWaiting }
    public var isEmpty: Bool { finished.isEmpty && newlyWaiting.isEmpty }
}

/// Remembers the previous snapshot. The first snapshot after launch only sets the baseline,
/// so restored chats never replay sounds.
public struct NotchTracker: Sendable {
    private var working: Set<String>?
    private var waiting: Set<String> = []
    public init() {}

    /// `waitingRequests` are pending request IDs, so a second request in the same chat also counts as new.
    /// A chat that stops working to wait for the user is announced as waiting, not as finished.
    public mutating func update(working nowWorking: Set<String>, waitingRequests nowWaiting: Set<String>, waitingChats: Set<String>) -> NotchTransition {
        defer { working = nowWorking; waiting = nowWaiting }
        guard let working else { return NotchTransition() }
        let finished = working.subtracting(nowWorking).subtracting(waitingChats).sorted()
        return NotchTransition(finished: finished, newlyWaiting: nowWaiting.subtracting(waiting).sorted())
    }
}

/// Visible state of the island window.
public enum NotchMode: Equatable, Sendable {
    /// Nothing drawn; hovering the notch still opens the island.
    case hidden
    /// A slim strip around the notch with the status.
    case compact
    /// A short wider strip announcing one event.
    case peek
    /// The full panel with chats and settings.
    case expanded
}

/// Pure decisions about the island; the window controller only applies them.
public enum NotchPolicy {
    public static func restingMode(summary: NotchSummary, preferences: NotchPreferences) -> NotchMode {
        summary.isIdle && preferences.autoHide ? .hidden : .compact
    }

    /// Hover opens, a new approval opens on its own, a finished turn peeks; leaving closes after a delay.
    public static func mode(resting: NotchMode, hovering: Bool, pinnedOpen: Bool, peeking: Bool) -> NotchMode {
        if hovering || pinnedOpen { return .expanded }
        if peeking { return .peek }
        return resting
    }

    public static func duration(since start: Date, now: Date = Date(), language: AppLanguage = L10n.language) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return L10n.text("\(seconds) с", "\(seconds)s", language: language) }
        let minutes = seconds / 60
        if minutes < 60 { return L10n.text("\(minutes) мин", "\(minutes)m", language: language) }
        return L10n.text("\(minutes / 60) ч \(minutes % 60) мин", "\(minutes / 60)h \(minutes % 60)m", language: language)
    }
}
