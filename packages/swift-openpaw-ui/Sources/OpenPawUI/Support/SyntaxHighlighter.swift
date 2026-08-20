import SwiftUI

/// Languages the highlighter has a real grammar for. `plain` is not a failure case: it is the honest answer for
/// a file whose language we do not know, and it renders faster than a wrong guess reads.
public enum SyntaxLanguage: String, Sendable, CaseIterable, Hashable {
    case swift
    case rust
    case javascript
    case typescript
    case python
    case json
    case markdown
    case shell
    case toml
    case yaml
    case plain
}

/// Syntax colours, deliberately desaturated.
///
/// The theme reserves saturation for the risk ramp: if a keyword were as loud as `destructive_shell`, the one
/// colour in the app that must stop a person would stop competing. These are cool, low-chroma tints of the
/// machine register, and `comment` reuses the existing `textTertiary` token rather than inventing a grey.
public struct SyntaxPalette: Sendable, Hashable {
    public let plain: Color
    public let keyword: Color
    public let type: Color
    public let string: Color
    public let number: Color
    public let comment: Color

    public init(plain: Color, keyword: Color, type: Color, string: Color, number: Color, comment: Color) {
        self.plain = plain
        self.keyword = keyword
        self.type = type
        self.string = string
        self.number = number
        self.comment = comment
    }

    /// The only palette. A second one would be a second accent system.
    public static let machine = SyntaxPalette(
        plain: OpenPawTheme.textPrimary,
        keyword: Color(hex: 0x9E8FD0),
        type: Color(hex: 0x74A9C4),
        string: Color(hex: 0x8FB4A8),
        number: Color(hex: 0x8DA9D6),
        comment: OpenPawTheme.textTertiary
    )
}

/// What a run of source was classified as.
public enum SyntaxToken: Sendable, Hashable, CaseIterable {
    case plain
    case keyword
    case type
    case string
    case number
    case comment

    public func color(in palette: SyntaxPalette = .machine) -> Color {
        switch self {
        case .plain: palette.plain
        case .keyword: palette.keyword
        case .type: palette.type
        case .string: palette.string
        case .number: palette.number
        case .comment: palette.comment
        }
    }
}

/// A single-pass, allocation-conscious tokenizer.
///
/// It is not a parser and does not try to be: it classifies keywords, string literals with their escape and
/// raw/triple-quoted forms, line and block comments, numeric literals, and capitalised identifiers. That is the
/// whole of what a reader needs to skim a diff on a phone, and it is achievable in one left-to-right pass with
/// no backtracking, which is the property that keeps a large blob from freezing a scroll.
///
/// Input beyond the budget is returned unstyled rather than truncated — a reader who scrolls into a generated
/// file gets plain text, never a missing tail.
public enum SyntaxHighlighter {

    /// Scalars styled before the highlighter gives up and passes the rest through. 200k covers every file a
    /// person reads and every diff hunk; past it, colour has no reader.
    public static let defaultBudget = 200_000

    // MARK: - Language detection

    /// Maps a path to a grammar by extension. JavaScript files are highlighted with the TypeScript grammar,
    /// which is a superset; nothing is lost and there is one fewer table to keep in step.
    public static func language(forPath path: String) -> SyntaxLanguage {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .plain }
        switch name[name.index(after: dot)...].lowercased() {
        case "swift": return .swift
        case "rs": return .rust
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyi", "pyw": return .python
        case "json", "jsonc": return .json
        case "md", "markdown", "mdx": return .markdown
        case "sh", "bash", "zsh", "ksh", "command": return .shell
        case "toml": return .toml
        case "yml", "yaml": return .yaml
        default: return .plain
        }
    }

    // MARK: - Highlighting

    public static func highlight(_ source: String, language: SyntaxLanguage) -> AttributedString {
        highlight(source, language: language, budget: defaultBudget, palette: .machine)
    }

    public static func highlight(
        _ source: String,
        language: SyntaxLanguage,
        budget: Int,
        palette: SyntaxPalette = .machine
    ) -> AttributedString {
        var output = AttributedString()
        for run in runs(source, language: language, budget: budget) {
            var piece = AttributedString(run.text)
            piece.foregroundColor = run.token.color(in: palette)
            output.append(piece)
        }
        return output
    }

    /// One classified run of source.
    public struct Run: Sendable, Hashable {
        public let text: String
        public let token: SyntaxToken

        public init(text: String, token: SyntaxToken) {
            self.text = text
            self.token = token
        }
    }

    /// The classification itself, as plain values, so it is testable without a rendering context and reusable by
    /// anything that wants spans rather than an `AttributedString`.
    public static func runs(
        _ source: String,
        language: SyntaxLanguage,
        budget: Int = defaultBudget
    ) -> [Run] {
        if source.isEmpty { return [] }
        guard budget > 0, language != .plain else { return [Run(text: source, token: .plain)] }

        let scalars = source.unicodeScalars
        // One walk to find the cap. `prefix` is lazy, so this is the only traversal of the styled region.
        var cap = scalars.startIndex
        var counted = 0
        while counted < budget, cap < scalars.endIndex {
            cap = scalars.index(after: cap)
            counted += 1
        }
        let styled = Array(scalars[..<cap])
        let remainder = String(scalars[cap...])

        var spans: [Run]
        switch language {
        case .markdown:
            spans = Markdown.scan(styled)
        case .plain:
            spans = [Run(text: String(String.UnicodeScalarView(styled)), token: .plain)]
        default:
            var scanner = Scanner(scalars: styled, grammar: .forLanguage(language))
            spans = scanner.scan()
        }
        if !remainder.isEmpty { spans.append(Run(text: remainder, token: .plain)) }
        return spans
    }
}

// MARK: - Grammar

extension SyntaxHighlighter {

    /// Where a language puts an identifier that names a field rather than calls a function.
    enum KeyRule {
        /// TOML: `key = value`, plus `[section]` headers.
        case beforeEquals
        /// YAML: `key: value`.
        case beforeColon
    }

    struct Grammar {
        var keywords: Set<String> = []
        /// Words that read as types even though they are lower-case (`int`, `str`, `usize`).
        var primitiveTypes: Set<String> = []
        var lineComments: [String] = []
        var blockCommentOpen: String?
        var blockCommentClose: String?
        /// True where `/* /* */ */` is legal, which changes the close condition from "first" to "outermost".
        var nestsBlockComments = false
        var stringDelimiters: Set<Unicode.Scalar> = []
        /// Delimiters that also have a tripled form spanning newlines.
        var tripleQuoted: Set<Unicode.Scalar> = []
        var honoursBackslashEscapes = true
        /// Identifier characters that become a string prefix when a quote follows: Python's `f"…"`, Rust's
        /// `r"…"`. Swift's `#"…"#` is separate because `#` is not an identifier character.
        var stringPrefixes: Set<String> = []
        var hashDelimitedRawStrings = false
        var classifiesCapitalisedIdentifiers = true
        var keyRule: KeyRule?
        /// `$name` and `${name}` read as values, not words.
        var dollarInterpolation = false

        static func forLanguage(_ language: SyntaxLanguage) -> Grammar {
            switch language {
            case .swift: return .swiftGrammar
            case .rust: return .rustGrammar
            case .javascript: return .javascriptGrammar
            case .typescript: return .typescriptGrammar
            case .python: return .pythonGrammar
            case .json: return .jsonGrammar
            case .shell: return .shellGrammar
            case .toml: return .tomlGrammar
            case .yaml: return .yamlGrammar
            case .markdown, .plain: return Grammar()
            }
        }

        static let swiftGrammar: Grammar = {
            var grammar = Grammar()
            grammar.keywords = [
                "actor", "any", "as", "associatedtype", "async", "await", "borrowing", "break", "case", "catch",
                "class", "consume", "consuming", "continue", "convenience", "default", "defer", "deinit",
                "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
                "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "infix", "init",
                "inout", "internal", "is", "lazy", "let", "macro", "mutating", "nil", "nonisolated",
                "nonmutating", "open", "operator", "optional", "override", "package", "postfix",
                "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required", "rethrows",
                "return", "self", "sending", "set", "some", "static", "struct", "subscript", "super", "switch",
                "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak", "where", "while",
                "willSet", "yield",
            ]
            grammar.lineComments = ["//"]
            grammar.blockCommentOpen = "/*"
            grammar.blockCommentClose = "*/"
            grammar.nestsBlockComments = true
            grammar.stringDelimiters = ["\""]
            grammar.tripleQuoted = ["\""]
            grammar.hashDelimitedRawStrings = true
            return grammar
        }()

        static let rustGrammar: Grammar = {
            var grammar = Grammar()
            grammar.keywords = [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
                "ref", "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
                "where", "while", "yield",
            ]
            grammar.primitiveTypes = [
                "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8", "u16",
                "u32", "u64", "u128", "usize",
            ]
            grammar.lineComments = ["//"]
            grammar.blockCommentOpen = "/*"
            grammar.blockCommentClose = "*/"
            grammar.nestsBlockComments = true
            grammar.stringDelimiters = ["\""]
            grammar.stringPrefixes = ["r", "b", "br", "rb"]
            return grammar
        }()

        static let javascriptGrammar: Grammar = {
            var grammar = Grammar()
            grammar.keywords = [
                "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function",
                "get", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "set", "static",
                "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void",
                "while", "with", "yield",
            ]
            grammar.lineComments = ["//"]
            grammar.blockCommentOpen = "/*"
            grammar.blockCommentClose = "*/"
            grammar.stringDelimiters = ["\"", "'", "`"]
            return grammar
        }()

        static let typescriptGrammar: Grammar = {
            var grammar = Grammar.javascriptGrammar
            grammar.keywords.formUnion([
                "abstract", "any", "as", "asserts", "declare", "enum", "implements", "infer", "interface", "is",
                "keyof", "namespace", "never", "private", "protected", "public", "readonly", "satisfies",
                "type", "unknown",
            ])
            grammar.primitiveTypes = ["bigint", "boolean", "number", "object", "string", "symbol"]
            return grammar
        }()

        static let pythonGrammar: Grammar = {
            var grammar = Grammar()
            grammar.keywords = [
                "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
                "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import",
                "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "while",
                "with", "yield",
            ]
            grammar.primitiveTypes = ["bool", "bytes", "dict", "float", "int", "list", "set", "str", "tuple"]
            grammar.lineComments = ["#"]
            grammar.stringDelimiters = ["\"", "'"]
            grammar.tripleQuoted = ["\"", "'"]
            grammar.stringPrefixes = ["r", "f", "b", "u", "rb", "br", "rf", "fr"]
            return grammar
        }()

        static let jsonGrammar: Grammar = {
            var grammar = Grammar()
            grammar.keywords = ["true", "false", "null"]
            grammar.stringDelimiters = ["\""]
            grammar.classifiesCapitalisedIdentifiers = false
            return grammar
        }()

        static let shellGrammar: Grammar = {
            var grammar = Grammar()
            grammar.keywords = [
                "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
                "local", "readonly", "return", "select", "set", "then", "trap", "unset", "until", "while",
            ]
            grammar.lineComments = ["#"]
            grammar.stringDelimiters = ["\"", "'"]
            grammar.classifiesCapitalisedIdentifiers = false
            grammar.dollarInterpolation = true
            return grammar
        }()

        static let tomlGrammar: Grammar = {
            var grammar = Grammar()
            grammar.keywords = ["true", "false"]
            grammar.lineComments = ["#"]
            grammar.stringDelimiters = ["\"", "'"]
            grammar.tripleQuoted = ["\"", "'"]
            grammar.classifiesCapitalisedIdentifiers = false
            grammar.keyRule = .beforeEquals
            return grammar
        }()

        static let yamlGrammar: Grammar = {
            var grammar = Grammar()
            grammar.keywords = ["true", "false", "null", "yes", "no", "on", "off"]
            grammar.lineComments = ["#"]
            grammar.stringDelimiters = ["\"", "'"]
            grammar.classifiesCapitalisedIdentifiers = false
            grammar.keyRule = .beforeColon
            grammar.dollarInterpolation = true
            return grammar
        }()
    }
}

// MARK: - The scanner

extension SyntaxHighlighter {

    /// One left-to-right pass. Every branch either consumes at least one scalar or ends the loop, which is what
    /// makes the linear-time claim structural rather than aspirational.
    struct Scanner {
        let scalars: [Unicode.Scalar]
        let grammar: Grammar

        private var index = 0
        private var runStart = 0
        private var spans: [Run] = []
        /// Start of the current line, used by the key rules and by `[section]` headers.
        private var lineStart = 0

        init(scalars: [Unicode.Scalar], grammar: Grammar) {
            self.scalars = scalars
            self.grammar = grammar
        }

        mutating func scan() -> [Run] {
            while index < scalars.count {
                let scalar = scalars[index]

                if scalar == "\n" {
                    index += 1
                    lineStart = index
                    continue
                }

                if let opener = matchedLineComment() {
                    consumeLineComment(openLength: opener)
                    continue
                }

                if let open = grammar.blockCommentOpen, matches(open, at: index) {
                    consumeBlockComment()
                    continue
                }

                if let opening = matchedStringOpening() {
                    consumeString(
                        from: opening.start,
                        quote: opening.quote,
                        triple: opening.triple,
                        escapes: opening.escapes
                    )
                    continue
                }

                if grammar.dollarInterpolation, scalar == "$" {
                    consumeInterpolation()
                    continue
                }

                if isIdentifierHead(scalar) {
                    consumeIdentifier()
                    continue
                }

                if isDigit(scalar) {
                    consumeNumber()
                    continue
                }

                if grammar.keyRule == .beforeEquals, scalar == "[", isIndentOnlyBeforeIndex() {
                    consumeSectionHeader()
                    continue
                }

                index += 1
            }
            flush(upTo: scalars.count, as: .plain)
            return spans
        }

        // MARK: Emitting

        private mutating func flush(upTo end: Int, as token: SyntaxToken) {
            guard end > runStart else { return }
            var view = String.UnicodeScalarView()
            view.reserveCapacity(end - runStart)
            for position in runStart..<end { view.append(scalars[position]) }
            spans.append(Run(text: String(view), token: token))
            runStart = end
        }

        /// Closes the plain run before `start`, emits `[start, index)` as `token`, and reopens a plain run.
        private mutating func emit(from start: Int, as token: SyntaxToken) {
            flush(upTo: start, as: .plain)
            flush(upTo: index, as: token)
        }

        // MARK: Comments

        private func matchedLineComment() -> Int? {
            for opener in grammar.lineComments where matches(opener, at: index) {
                return opener.unicodeScalars.count
            }
            return nil
        }

        private mutating func consumeLineComment(openLength: Int) {
            let start = index
            index += openLength
            while index < scalars.count, scalars[index] != "\n" { index += 1 }
            emit(from: start, as: .comment)
        }

        private mutating func consumeBlockComment() {
            guard let open = grammar.blockCommentOpen, let close = grammar.blockCommentClose else { return }
            let start = index
            let openWidth = open.unicodeScalars.count
            let closeWidth = close.unicodeScalars.count
            index += openWidth
            var depth = 1
            while index < scalars.count {
                if grammar.nestsBlockComments, matches(open, at: index) {
                    depth += 1
                    index += openWidth
                    continue
                }
                if matches(close, at: index) {
                    depth -= 1
                    index += closeWidth
                    if depth == 0 { break }
                    continue
                }
                if scalars[index] == "\n" { lineStart = index + 1 }
                index += 1
            }
            emit(from: start, as: .comment)
        }

        // MARK: Strings

        /// The span start (which may precede `index` for a prefixed literal), the delimiter, whether it is the
        /// tripled form, and whether backslash escapes apply.
        private func matchedStringOpening()
            -> (start: Int, quote: Unicode.Scalar, triple: Bool, escapes: Bool)? {
            let scalar = scalars[index]

            if grammar.hashDelimitedRawStrings, scalar == "#" {
                var probe = index
                while probe < scalars.count, scalars[probe] == "#" { probe += 1 }
                guard probe < scalars.count, scalars[probe] == "\"" else { return nil }
                return (index, "\"", isTripled(at: probe, quote: "\""), false)
            }

            guard grammar.stringDelimiters.contains(scalar) else { return nil }
            return (index, scalar, isTripled(at: index, quote: scalar), grammar.honoursBackslashEscapes)
        }

        private func isTripled(at position: Int, quote: Unicode.Scalar) -> Bool {
            guard grammar.tripleQuoted.contains(quote) else { return false }
            return position + 2 < scalars.count
                && scalars[position + 1] == quote
                && scalars[position + 2] == quote
        }

        private mutating func consumeString(
            from start: Int, quote: Unicode.Scalar, triple: Bool, escapes: Bool
        ) {
            // Step over whatever prefix the opening match claimed (`f`, `r`, `#`).
            while index < scalars.count, scalars[index] != quote { index += 1 }
            index += triple ? 3 : 1

            while index < scalars.count {
                let scalar = scalars[index]
                if escapes, scalar == "\\", index + 1 < scalars.count {
                    index += 2
                    continue
                }
                if scalar == quote {
                    if triple {
                        if index + 2 < scalars.count, scalars[index + 1] == quote, scalars[index + 2] == quote {
                            index += 3
                            break
                        }
                        index += 1
                        continue
                    }
                    index += 1
                    break
                }
                if scalar == "\n" {
                    lineStart = index + 1
                    // A single-delimiter literal never spans a line; stopping here keeps one stray apostrophe
                    // from painting the rest of the file.
                    if !triple { break }
                }
                index += 1
            }
            // Trailing `#`s of a Swift raw literal belong to the literal.
            if grammar.hashDelimitedRawStrings {
                while index < scalars.count, scalars[index] == "#" { index += 1 }
            }
            emit(from: start, as: .string)
        }

        // MARK: Identifiers, numbers, keys

        private mutating func consumeIdentifier() {
            let start = index
            while index < scalars.count, isIdentifierBody(scalars[index]) { index += 1 }
            let word = string(from: start, to: index)

            // A string prefix belongs to the literal that follows it, not to the identifier stream.
            if grammar.stringPrefixes.contains(word), index < scalars.count,
                grammar.stringDelimiters.contains(scalars[index]) {
                let quote = scalars[index]
                consumeString(
                    from: start,
                    quote: quote,
                    triple: isTripled(at: index, quote: quote),
                    escapes: word.contains("r") ? false : grammar.honoursBackslashEscapes
                )
                return
            }

            if grammar.keywords.contains(word) {
                emit(from: start, as: .keyword)
                return
            }
            if grammar.primitiveTypes.contains(word) {
                emit(from: start, as: .type)
                return
            }
            if let rule = grammar.keyRule, isKey(from: start, rule: rule) {
                emit(from: start, as: .keyword)
                return
            }
            if grammar.classifiesCapitalisedIdentifiers, let first = word.unicodeScalars.first,
                CharacterSet.uppercaseLetters.contains(first) {
                emit(from: start, as: .type)
            }
        }

        private mutating func consumeNumber() {
            let start = index
            if scalars[index] == "0", index + 1 < scalars.count, isRadixMarker(scalars[index + 1]) {
                index += 2
                while index < scalars.count, isHexBody(scalars[index]) { index += 1 }
            } else {
                while index < scalars.count, isNumberBody(scalars[index]) { index += 1 }
                if index + 1 < scalars.count, scalars[index] == ".", isDigit(scalars[index + 1]) {
                    index += 1
                    while index < scalars.count, isNumberBody(scalars[index]) { index += 1 }
                }
                if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                    var probe = index + 1
                    if probe < scalars.count, scalars[probe] == "+" || scalars[probe] == "-" { probe += 1 }
                    if probe < scalars.count, isDigit(scalars[probe]) {
                        index = probe
                        while index < scalars.count, isDigit(scalars[index]) { index += 1 }
                    }
                }
            }
            // Type suffixes (`10_u32`, `1.5f`) read as part of the literal.
            while index < scalars.count, isIdentifierBody(scalars[index]) { index += 1 }
            emit(from: start, as: .number)
        }

        private mutating func consumeInterpolation() {
            let start = index
            index += 1
            if index < scalars.count, scalars[index] == "{" {
                while index < scalars.count, scalars[index] != "}" { index += 1 }
                if index < scalars.count { index += 1 }
            } else {
                while index < scalars.count, isIdentifierBody(scalars[index]) { index += 1 }
            }
            emit(from: start, as: .type)
        }

        private mutating func consumeSectionHeader() {
            let start = index
            while index < scalars.count, scalars[index] != "]", scalars[index] != "\n" { index += 1 }
            if index < scalars.count, scalars[index] == "]" { index += 1 }
            emit(from: start, as: .type)
        }

        // MARK: Predicates

        private func string(from start: Int, to end: Int) -> String {
            var view = String.UnicodeScalarView()
            view.reserveCapacity(end - start)
            for position in start..<end { view.append(scalars[position]) }
            return String(view)
        }

        /// True when only indentation (or a YAML list dash) separates the line start from `index`.
        private func isIndentOnlyBeforeIndex() -> Bool {
            isIndentOnly(from: lineStart, to: index)
        }

        private func isIndentOnly(from start: Int, to end: Int) -> Bool {
            var probe = start
            while probe < end {
                let scalar = scalars[probe]
                guard scalar == " " || scalar == "\t" || scalar == "-" else { return false }
                probe += 1
            }
            return true
        }

        /// An identifier is a key when it is the first thing on its line and the assignment character follows on
        /// the same line, with nothing but identifier characters, dots or spaces in between.
        private func isKey(from start: Int, rule: KeyRule) -> Bool {
            guard isIndentOnly(from: lineStart, to: start) else { return false }
            let assignment: Unicode.Scalar = rule == .beforeEquals ? "=" : ":"
            var lookahead = index
            while lookahead < scalars.count, scalars[lookahead] != "\n" {
                let scalar = scalars[lookahead]
                if scalar == assignment { return true }
                guard scalar == " " || scalar == "\t" || scalar == "." || isIdentifierBody(scalar) else {
                    return false
                }
                lookahead += 1
            }
            return false
        }

        private func matches(_ needle: String, at position: Int) -> Bool {
            var probe = position
            for scalar in needle.unicodeScalars {
                guard probe < scalars.count, scalars[probe] == scalar else { return false }
                probe += 1
            }
            return true
        }

        private func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar >= "0" && scalar <= "9" }

        private func isRadixMarker(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "x" || scalar == "X" || scalar == "b" || scalar == "B" || scalar == "o" || scalar == "O"
        }

        private func isNumberBody(_ scalar: Unicode.Scalar) -> Bool { isDigit(scalar) || scalar == "_" }

        private func isHexBody(_ scalar: Unicode.Scalar) -> Bool {
            isDigit(scalar) || scalar == "_"
                || (scalar >= "a" && scalar <= "f") || (scalar >= "A" && scalar <= "F")
        }

        private func isIdentifierHead(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || CharacterSet.letters.contains(scalar)
        }

        private func isIdentifierBody(_ scalar: Unicode.Scalar) -> Bool {
            isIdentifierHead(scalar) || isDigit(scalar)
        }
    }
}

// MARK: - Markdown

extension SyntaxHighlighter {

    /// Markdown is line-structured rather than token-structured, so it gets its own pass instead of being bent
    /// into the code scanner. Mapping onto the same six tokens keeps one palette: headings read as keywords,
    /// code as strings, links and emphasis as types, quotes and rules as comments.
    enum Markdown {
        static func scan(_ scalars: [Unicode.Scalar]) -> [Run] {
            var spans: [Run] = []
            var inFence = false

            for line in splitKeepingNewlines(scalars) {
                let text = String(String.UnicodeScalarView(line))
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)

                if body.hasPrefix("```") || body.hasPrefix("~~~") {
                    inFence.toggle()
                    spans.append(Run(text: text, token: .comment))
                    continue
                }
                if inFence {
                    spans.append(Run(text: text, token: .string))
                    continue
                }
                if body.hasPrefix("#") {
                    spans.append(Run(text: text, token: .keyword))
                    continue
                }
                if body.hasPrefix(">") || body.hasPrefix("|") || isRule(body) {
                    spans.append(Run(text: text, token: .comment))
                    continue
                }
                spans.append(contentsOf: inline(line))
            }
            return spans
        }

        /// Inline spans: `code`, [links](targets), **emphasis**, and the leading list marker.
        private static func inline(_ scalars: [Unicode.Scalar]) -> [Run] {
            var spans: [Run] = []
            var index = 0
            var runStart = 0

            func flush(upTo end: Int, as token: SyntaxToken) {
                guard end > runStart else { return }
                var view = String.UnicodeScalarView()
                view.reserveCapacity(end - runStart)
                for position in runStart..<end { view.append(scalars[position]) }
                spans.append(Run(text: String(view), token: token))
                runStart = end
            }

            if let marker = listMarkerLength(scalars) {
                index = marker
                flush(upTo: marker, as: .number)
            }

            while index < scalars.count {
                switch scalars[index] {
                case "`":
                    let start = index
                    index += 1
                    while index < scalars.count, scalars[index] != "`", scalars[index] != "\n" { index += 1 }
                    if index < scalars.count, scalars[index] == "`" { index += 1 }
                    flush(upTo: start, as: .plain)
                    flush(upTo: index, as: .string)

                case "(" where index > 0 && scalars[index - 1] == "]":
                    let start = index
                    index += 1
                    while index < scalars.count, scalars[index] != ")", scalars[index] != "\n" { index += 1 }
                    if index < scalars.count, scalars[index] == ")" { index += 1 }
                    flush(upTo: start, as: .plain)
                    flush(upTo: index, as: .type)

                case "*", "_":
                    let delimiter = scalars[index]
                    let width = (index + 1 < scalars.count && scalars[index + 1] == delimiter) ? 2 : 1
                    if let end = closingDelimiter(scalars, from: index + width, delimiter: delimiter, width: width),
                        end - (index + width) > 0 {
                        let start = index
                        index = end
                        flush(upTo: start, as: .plain)
                        flush(upTo: index, as: .type)
                    } else {
                        index += width
                    }

                default:
                    index += 1
                }
            }
            flush(upTo: scalars.count, as: .plain)
            return spans
        }

        /// Index just past the closing run of `width` delimiters, or `nil` when the emphasis never closes on
        /// this line.
        private static func closingDelimiter(
            _ scalars: [Unicode.Scalar], from start: Int, delimiter: Unicode.Scalar, width: Int
        ) -> Int? {
            var probe = start
            while probe < scalars.count, scalars[probe] != "\n" {
                if scalars[probe] == delimiter {
                    if width == 1 { return probe + 1 }
                    if probe + 1 < scalars.count, scalars[probe + 1] == delimiter { return probe + 2 }
                }
                probe += 1
            }
            return nil
        }

        private static func listMarkerLength(_ scalars: [Unicode.Scalar]) -> Int? {
            var probe = 0
            while probe < scalars.count, scalars[probe] == " " || scalars[probe] == "\t" { probe += 1 }
            guard probe < scalars.count else { return nil }
            if scalars[probe] == "-" || scalars[probe] == "*" || scalars[probe] == "+" {
                guard probe + 1 < scalars.count, scalars[probe + 1] == " " else { return nil }
                return probe + 2
            }
            var digits = probe
            while digits < scalars.count, scalars[digits] >= "0", scalars[digits] <= "9" { digits += 1 }
            guard digits > probe, digits + 1 < scalars.count, scalars[digits] == ".",
                scalars[digits + 1] == " "
            else { return nil }
            return digits + 2
        }

        private static func isRule(_ body: String) -> Bool {
            guard body.count >= 3 else { return false }
            return body.allSatisfy { $0 == "=" } || body.allSatisfy { $0 == "-" }
        }

        private static func splitKeepingNewlines(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
            var lines: [[Unicode.Scalar]] = []
            var current: [Unicode.Scalar] = []
            for scalar in scalars {
                current.append(scalar)
                if scalar == "\n" {
                    lines.append(current)
                    current = []
                }
            }
            if !current.isEmpty { lines.append(current) }
            return lines
        }
    }
}
