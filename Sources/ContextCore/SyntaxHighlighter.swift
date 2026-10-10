import Foundation

/// A small lexical highlighter: comments, strings, numbers, keywords, types and keys.
/// It never parses or evaluates code; unknown languages get no tokens.
public enum SyntaxHighlighter {
    public enum Kind: Equatable, Sendable { case keyword, string, comment, number, type, key, variable, attribute }
    public struct Token: Equatable, Sendable {
        public var range: NSRange
        public var kind: Kind
    }

    struct Language {
        var keywords: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (String, String)?
        var quotes: Set<Character> = ["\"", "'"]
        var typesCapitalized = false
        var shellVariables = false
        var attributes: Character?
        var jsonKeys = false
        var yamlKeys = false
    }

    /// Code longer than this is shown without colors to keep streaming responsive.
    public static let limit = 60_000

    public static func tokens(in code: String, language: String?) -> [Token] {
        guard code.utf16.count <= limit, let spec = language.flatMap(Self.spec(for:)) else { return [] }
        let text = Array(code.utf16)
        var tokens: [Token] = []
        var index = 0
        var lineStart = true
        func matches(_ value: String, at position: Int) -> Bool {
            var offset = position
            for unit in value.utf16 {
                guard offset < text.count, text[offset] == unit else { return false }
                offset += 1
            }
            return true
        }
        func isIdentifier(_ unit: UInt16) -> Bool {
            unit == 95 || (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit > 127
        }
        let newline: UInt16 = 10
        while index < text.count {
            let unit = text[index]
            if unit == newline { lineStart = true; index += 1; continue }
            if unit == 32 || unit == 9 { index += 1; continue }
            let atLineStart = lineStart
            lineStart = false
            // YAML keys: `name:` at the start of a line or after a list dash.
            if spec.yamlKeys, atLineStart || (index > 1 && text[index - 2] == 45 && text[index - 1] == 32) {
                var end = index
                while end < text.count, isIdentifier(text[end]) || text[end] == 45 || text[end] == 46 { end += 1 }
                if end > index, end < text.count, text[end] == 58, end + 1 == text.count || text[end + 1] == 32 || text[end + 1] == newline {
                    tokens.append(Token(range: NSRange(location: index, length: end - index), kind: .key))
                    index = end + 1; continue
                }
            }
            if let comment = spec.lineComments.first(where: { matches($0, at: index) }),
               comment != "#" || index == 0 || text[index - 1] == 32 || text[index - 1] == 9 || text[index - 1] == newline {
                var end = index
                while end < text.count, text[end] != newline { end += 1 }
                tokens.append(Token(range: NSRange(location: index, length: end - index), kind: .comment))
                index = end; continue
            }
            if let block = spec.blockComment, matches(block.0, at: index) {
                var end = index + block.0.utf16.count
                while end < text.count, !matches(block.1, at: end) { end += 1 }
                end = min(text.count, end + block.1.utf16.count)
                tokens.append(Token(range: NSRange(location: index, length: end - index), kind: .comment))
                index = end; continue
            }
            if let scalar = Unicode.Scalar(unit), spec.quotes.contains(Character(scalar)) {
                var end = index + 1
                let triple = matches(String(repeating: String(Character(scalar)), count: 3), at: index)
                if triple {
                    end = index + 3
                    let closing = String(repeating: String(Character(scalar)), count: 3)
                    while end < text.count, !matches(closing, at: end) { end += text[end] == 92 ? 2 : 1 }
                    end = min(text.count, end + 3)
                } else {
                    while end < text.count, text[end] != unit, text[end] != newline { end += text[end] == 92 ? 2 : 1 }
                    end = min(text.count, end + 1)
                }
                var kind = Kind.string
                if spec.jsonKeys {
                    var next = end
                    while next < text.count, text[next] == 32 { next += 1 }
                    if next < text.count, text[next] == 58 { kind = .key }
                }
                tokens.append(Token(range: NSRange(location: index, length: end - index), kind: kind))
                index = end; continue
            }
            if spec.shellVariables, unit == 36 {
                var end = index + 1
                if end < text.count, text[end] == 123 {
                    while end < text.count, text[end] != 125, text[end] != newline { end += 1 }
                    end = min(text.count, end + 1)
                } else {
                    while end < text.count, isIdentifier(text[end]) { end += 1 }
                }
                if end > index + 1 { tokens.append(Token(range: NSRange(location: index, length: end - index), kind: .variable)) }
                index = max(end, index + 1); continue
            }
            if let marker = spec.attributes, let scalar = Unicode.Scalar(unit), Character(scalar) == marker {
                var end = index + 1
                while end < text.count, isIdentifier(text[end]) { end += 1 }
                if end > index + 1 { tokens.append(Token(range: NSRange(location: index, length: end - index), kind: .attribute)) }
                index = max(end, index + 1); continue
            }
            if unit >= 48 && unit <= 57, index == 0 || !isIdentifier(text[index - 1]) {
                var end = index
                while end < text.count, isIdentifier(text[end]) || text[end] == 46 { end += 1 }
                tokens.append(Token(range: NSRange(location: index, length: end - index), kind: .number))
                index = end; continue
            }
            if isIdentifier(unit) {
                var end = index
                while end < text.count, isIdentifier(text[end]) { end += 1 }
                let word = String(decoding: text[index..<end], as: UTF16.self)
                if spec.keywords.contains(word) {
                    tokens.append(Token(range: NSRange(location: index, length: end - index), kind: .keyword))
                } else if spec.typesCapitalized, let first = word.first, first.isUppercase, first.isASCII {
                    tokens.append(Token(range: NSRange(location: index, length: end - index), kind: .type))
                }
                index = end; continue
            }
            index += 1
        }
        return tokens
    }

    static func spec(for name: String) -> Language? {
        let cFamily = ["//"]
        switch name.lowercased() {
        case "swift":
            return Language(keywords: ["let", "var", "func", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch",
                                       "default", "for", "in", "while", "repeat", "import", "public", "private", "fileprivate", "internal",
                                       "static", "final", "extension", "protocol", "init", "deinit", "self", "Self", "super", "nil", "true",
                                       "false", "try", "throw", "throws", "rethrows", "async", "await", "do", "catch", "some", "any", "where",
                                       "inout", "defer", "break", "continue", "override", "mutating", "lazy", "weak", "unowned", "actor",
                                       "nonisolated", "typealias", "associatedtype", "is", "as", "get", "set", "willSet", "didSet", "open"],
                            lineComments: cFamily, blockComment: ("/*", "*/"), quotes: ["\""], typesCapitalized: true, attributes: "@")
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs":
            return Language(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
                                       "default", "break", "continue", "new", "class", "extends", "import", "export", "from", "as", "async",
                                       "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined",
                                       "true", "false", "this", "super", "interface", "type", "enum", "implements", "public", "private",
                                       "protected", "readonly", "static", "yield", "void", "delete"],
                            lineComments: cFamily, blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], typesCapitalized: true, attributes: "@")
        case "py", "python":
            return Language(keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
                                       "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue",
                                       "lambda", "yield", "None", "True", "False", "async", "await", "global", "nonlocal", "self", "assert", "del"],
                            lineComments: ["#"], typesCapitalized: true, attributes: "@")
        case "sh", "bash", "zsh", "shell", "console", "terminal", "fish":
            return Language(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function",
                                       "return", "export", "local", "set", "unset", "source", "echo", "cd", "exit", "sudo"],
                            lineComments: ["#"], shellVariables: true)
        case "json", "jsonc", "json5":
            return Language(keywords: ["true", "false", "null"], lineComments: name == "json" ? [] : cFamily, quotes: ["\""], jsonKeys: true)
        case "yaml", "yml":
            return Language(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], yamlKeys: true)
        case "toml", "ini":
            return Language(keywords: ["true", "false"], lineComments: ["#", ";"])
        case "go", "golang":
            return Language(keywords: ["package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default",
                                       "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "nil",
                                       "true", "false", "break", "continue"],
                            lineComments: cFamily, blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], typesCapitalized: true)
        case "rust", "rs":
            return Language(keywords: ["fn", "let", "mut", "if", "else", "match", "for", "in", "while", "loop", "return", "struct", "enum",
                                       "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "super", "true", "false", "as", "ref",
                                       "where", "async", "await", "move", "const", "static", "type", "unsafe", "dyn"],
                            lineComments: cFamily, blockComment: ("/*", "*/"), quotes: ["\""], typesCapitalized: true, attributes: "#")
        case "c", "h", "cpp", "c++", "objc", "objective-c", "java", "kotlin", "kt", "cs", "csharp":
            return Language(keywords: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "const", "static", "struct",
                                       "class", "public", "private", "protected", "return", "if", "else", "for", "while", "do", "switch",
                                       "case", "default", "break", "continue", "new", "delete", "true", "false", "null", "nullptr", "this",
                                       "import", "package", "fun", "val", "var", "override", "interface", "extends", "implements", "try",
                                       "catch", "throw", "namespace", "using", "include", "define", "bool", "auto", "enum", "typedef"],
                            lineComments: cFamily, blockComment: ("/*", "*/"), typesCapitalized: true, attributes: "@")
        case "sql":
            let words = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index",
                         "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "limit", "and", "or",
                         "not", "null", "as", "primary", "key", "references", "distinct", "having", "union", "case", "when", "then",
                         "else", "end", "begin", "commit", "with", "is", "in", "exists", "default"]
            return Language(keywords: Set(words + words.map { $0.uppercased() }), lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'"])
        case "html", "xml", "svg", "plist":
            return Language(blockComment: ("<!--", "-->"), quotes: ["\""])
        case "css", "scss":
            return Language(keywords: ["important"], blockComment: ("/*", "*/"))
        default:
            return nil
        }
    }
}
