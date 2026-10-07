import Foundation

/// Project rules for Claude chats. The app launches Claude with `--setting-sources ""` to keep the user's own
/// settings, hooks and MCP servers out, which also stops the CLI from reading the project's CLAUDE.md, so the
/// app passes the project's AGENTS.md (or CLAUDE.md) itself.
public enum ProjectInstructions {
    static let files = ["AGENTS.md", "CLAUDE.md"]
    static let limit = 64 * 1024

    /// Instructions for the system prompt, or nil when the project has none.
    public static func prompt(projectPath: String, language: AppLanguage = L10n.language) -> String? {
        let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        for name in files {
            guard let text = read(root.appendingPathComponent(name), root: root) else { continue }
            let body = expandImports(text, root: root).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            return L10n.text("Инструкции проекта из \(name) (\(root.path)):", "Project instructions from \(name) (\(root.path)):",
                             language: language) + "\n\n" + String(body.prefix(limit))
        }
        return nil
    }

    /// Reads a regular file that stays inside the project after resolving symlinks.
    static func read(_ file: URL, root: URL) -> String? {
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/"),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= limit,
              let data = try? Data(contentsOf: resolved) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Replaces whole-line `@relative/path.md` imports (the CLAUDE.md convention) one level deep.
    static func expandImports(_ text: String, root: URL) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@"), trimmed.count > 1, !trimmed.contains(" "),
                  let imported = read(root.appendingPathComponent(String(trimmed.dropFirst())), root: root) else { return String(line) }
            return imported
        }.joined(separator: "\n")
    }
}
