import Foundation

/// Resolves `[[page]]` links the way Obsidian does: by path suffix inside the vault,
/// preferring the match closest to the linking file. Read-only; it only lists files.
public final class WikiIndex: @unchecked Sendable {
    public let root: URL
    /// Lowercased vault-relative paths without extension → files.
    private let files: [(key: String, url: URL)]
    /// Lowercased absolute paths → files, for links relative to the linking page.
    private let byPath: [String: URL]
    /// Last path component → indexes into `files`, so suffix matching never scans the whole vault.
    private let byName: [String: [Int]]
    public static let fileLimit = 50_000

    public init(root: URL) {
        self.root = root.standardizedFileURL
        var files: [(String, URL)] = []
        let manager = FileManager.default
        if let walker = manager.enumerator(at: self.root, includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                if url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
                guard ["md", "markdown", "mdx"].contains(url.pathExtension.lowercased()) else { continue }
                let relative = url.standardizedFileURL.path.dropFirst(self.root.path.count).drop(while: { $0 == "/" })
                files.append((String(relative.dropLast(url.pathExtension.count + 1)).lowercased(), url.standardizedFileURL))
                if files.count >= Self.fileLimit { break }
            }
        }
        self.files = files
        var byPath: [String: URL] = [:], byName: [String: [Int]] = [:]
        for (offset, file) in files.enumerated() {
            byPath[file.1.path.lowercased()] = file.1
            byName[String(file.0.split(separator: "/").last ?? ""), default: []].append(offset)
        }
        self.byPath = byPath
        self.byName = byName
    }

    /// The vault containing a file: the nearest folder with `.obsidian`, else the nearest repository root.
    public static func root(for file: URL) -> URL? {
        var directory = file.hasDirectoryPath ? file : file.deletingLastPathComponent()
        var repository: URL?
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while directory.path.count > 1, directory.standardizedFileURL.path != home {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".obsidian").path) { return directory }
            if repository == nil, FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { repository = directory }
            directory.deleteLastPathComponent()
        }
        return repository
    }

    /// Splits `page#Heading|alias` into its parts.
    public static func parse(_ link: String) -> (target: String, anchor: String?, alias: String?) {
        var body = link
        var alias: String?
        if let bar = body.firstIndex(of: "|") {
            alias = String(body[body.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<bar])
        }
        var anchor: String?
        if let hash = body.firstIndex(of: "#") {
            anchor = String(body[body.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<hash])
        }
        return (body.trimmingCharacters(in: .whitespaces), anchor?.isEmpty == true ? nil : anchor, alias?.isEmpty == true ? nil : alias)
    }

    private let memoLock = NSLock()
    private var memo: [String: URL?] = [:]

    /// Long pages link the same targets many times; answers are memoized for the index's lifetime.
    public func resolve(_ target: String, from source: URL? = nil) -> URL? {
        let memoKey = target + "\u{0}" + (source?.deletingLastPathComponent().path ?? "")
        memoLock.lock()
        if let known = memo[memoKey] { memoLock.unlock(); return known }
        memoLock.unlock()
        let url = lookup(target, from: source)
        memoLock.lock(); memo[memoKey] = url; memoLock.unlock()
        return url
    }

    private func lookup(_ target: String, from source: URL?) -> URL? {
        var key = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return source }
        if key.hasPrefix("/") { key.removeFirst() }
        for ext in [".md", ".markdown", ".mdx"] where key.hasSuffix(ext) { key.removeLast(ext.count) }
        // A path relative to the linking file wins when it exists.
        if let source {
            let relative = source.deletingLastPathComponent().appendingPathComponent(target + (target.contains(".") ? "" : ".md")).standardizedFileURL
            // Prefer the indexed spelling: the file system ignores case, links often do too.
            if let indexed = byPath[relative.path.lowercased()] { return indexed }
            // Non-Markdown targets (images, PDFs) are not indexed.
            if target.contains("."), !key.isEmpty, FileManager.default.fileExists(atPath: relative.path) { return relative }
        }
        let name = String(key.split(separator: "/").last ?? "")
        let matches = (byName[name] ?? []).map { files[$0] }.filter { $0.key == key || $0.key.hasSuffix("/" + key) }
        guard !matches.isEmpty else { return nil }
        guard let source, matches.count > 1 else { return matches.first?.url }
        let from = source.deletingLastPathComponent().standardizedFileURL.pathComponents
        return matches.min { lhs, rhs in
            func distance(_ url: URL) -> Int {
                let parts = url.deletingLastPathComponent().pathComponents
                let common = zip(parts, from).prefix(while: { $0 == $1 }).count
                return (parts.count - common) + (from.count - common)
            }
            return (distance(lhs.url), lhs.key.count) < (distance(rhs.url), rhs.key.count)
        }?.url
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (WikiIndex, Date)] = [:]

    /// A cached index for the vault around `file`; refreshed after 30 seconds so new pages appear.
    nonisolated(unsafe) private static var roots: [String: (URL?, Date)] = [:]

    public static func shared(for file: URL) -> WikiIndex? {
        let directory = (file.hasDirectoryPath ? file : file.deletingLastPathComponent()).path
        lock.lock()
        let known = roots[directory].flatMap { Date().timeIntervalSince($0.1) < 30 ? $0 : nil }
        lock.unlock()
        let root: URL?
        if let known { root = known.0 } else {
            root = Self.root(for: file)
            lock.lock(); roots[directory] = (root, Date()); lock.unlock()
        }
        guard let root else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let (index, built) = cache[root.path], Date().timeIntervalSince(built) < 30 { return index }
        let index = WikiIndex(root: root)
        cache[root.path] = (index, Date())
        return index
    }
}
