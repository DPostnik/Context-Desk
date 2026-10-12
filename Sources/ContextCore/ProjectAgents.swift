import Foundation

/// Project sub-agents for Claude chats. `--setting-sources ""` also stops the CLI from reading the project's
/// `.claude/agents/*.md`, so the app reads them itself and passes them with `--agents`, which the CLI honors
/// even in isolated launches. Hooks and MCP servers in agent definitions stay out, like the user's own ones.
public enum ProjectAgents {
    static let directory = ".claude/agents"
    static let fileLimit = 64 * 1024
    static let totalLimit = 256 * 1024
    static let fileCountLimit = 64
    /// Frontmatter fields forwarded to the CLI; anything else (hooks, mcpServers, permissionMode) is dropped.
    static let textFields = ["description", "model", "effort", "color", "isolation", "memory", "initialPrompt"]
    static let listFields = ["tools", "disallowedTools", "skills"]

    /// The `--agents` JSON object, or nil when the project defines no usable agents.
    public static func definitions(projectPath: String) -> JSONValue? {
        let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(directory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var agents: [String: JSONValue] = [:]
        var total = 0
        for name in names.filter({ $0.hasSuffix(".md") && !$0.hasPrefix(".") }).sorted().prefix(fileCountLimit) {
            guard let text = ProjectInstructions.read(folder.appendingPathComponent(name), root: root),
                  text.utf8.count <= fileLimit, total + text.utf8.count <= totalLimit,
                  let (agentName, definition) = parse(text, fallbackName: String(name.dropLast(3))),
                  agents[agentName] == nil else { continue }
            agents[agentName] = definition; total += text.utf8.count
        }
        return agents.isEmpty ? nil : .object(agents)
    }

    /// The JSON text for `--agents`, or nil when there is nothing to pass.
    public static func argument(projectPath: String) -> String? {
        guard let value = definitions(projectPath: projectPath) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Parses `---` frontmatter plus a Markdown body (the system prompt). Requires a description and a body.
    static func parse(_ text: String, fallbackName: String) -> (String, JSONValue)? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let fields = frontmatter(Array(lines[1..<end]))
        let prompt = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = fields["name"]?.first ?? fallbackName
        guard isValidName(name), let description = fields["description"]?.first, !description.isEmpty, !prompt.isEmpty else { return nil }
        var definition: [String: JSONValue] = ["prompt": .string(prompt), "description": .string(description)]
        for key in textFields where key != "description" {
            if let value = fields[key]?.first, !value.isEmpty { definition[key] = .string(value) }
        }
        if let turns = fields["maxTurns"]?.first.flatMap(Int.init), turns > 0 { definition["maxTurns"] = .number(Double(turns)) }
        if let background = fields["background"]?.first?.lowercased(), ["true", "false"].contains(background) {
            definition["background"] = .bool(background == "true")
        }
        for key in listFields {
            guard let values = fields[key] else { continue }
            let items = values.flatMap { $0.split(separator: ",") }.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
            if !items.isEmpty { definition[key] = .array(items.map(JSONValue.string)) }
        }
        return (name, .object(definition))
    }

    /// A small YAML subset: `key: value`, `key:` followed by `- item` lines, and `|`/`>` or indented continuations.
    static func frontmatter(_ lines: [String]) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        var key: String?
        var block = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let current = key, line.first == " " || line.first == "\t" {
                var values = fields[current] ?? []
                if trimmed.hasPrefix("- "), !block { values.append(unquote(String(trimmed.dropFirst(2)))) }
                else if let last = values.popLast() { values.append(last.isEmpty ? trimmed : last + (block ? "\n" : " ") + trimmed) }
                else { values = [trimmed] }
                fields[current] = values
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { key = nil; continue }
            let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            key = name
            block = ["|", ">", "|-", ">-"].contains(value)
            if value.hasPrefix("[") && value.hasSuffix("]") { fields[name] = [String(value.dropFirst().dropLast())] }
            else { fields[name] = block ? [""] : (value.isEmpty ? [] : [unquote(value)]) }
        }
        return fields
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
