import SwiftUI
import UIKit

/// What a stretch of source code is, for colouring.
enum SyntaxKind: Sendable {
    case keyword
    case type
    case string
    case comment
    case number
    /// Swift attributes, Python decorators, CSS classes and IDs.
    case attribute
    /// HTML tags and CSS element selectors.
    case tag
    /// HTML attribute names and CSS properties.
    case property
    /// Shell variables.
    case variable
}

struct SyntaxToken: Equatable, Sendable {
    /// UTF-16, as `NSString` counts.
    var range: NSRange
    var kind: SyntaxKind
}

/// Finds the keywords, strings, comments and the rest in source code.
///
/// It reads the text in one pass, without parsing it, which is enough to
/// colour code as an editor does and quick enough to run on every keystroke.
/// Line separators count as line ends, so it reads the editor's text as well
/// as a file's.
enum SyntaxHighlighter {
    static func tokens(in text: String, language: SourceLanguage) -> [SyntaxToken] {
        var scanner = Scanner(units: Array(text.utf16))
        let all = 0..<scanner.units.count
        switch language {
        case .html: scanner.scanHTML(all)
        case .css: scanner.scanCSS(all)
        default: scanner.scanCode(all, rules: CodeRules(language))
        }
        return scanner.tokens
    }

    /// Colours `text` by its syntax, and what is not syntax in `plainColor`.
    /// Only what changes colour is touched, so the layout of the rest stands.
    static func apply(
        _ language: SourceLanguage, to text: NSMutableAttributedString, scheme: ColorScheme, plainColor: UIColor
    ) {
        var colors: [SyntaxKind: UIColor] = [:]
        var segments: [(range: NSRange, color: UIColor)] = []
        var location = 0
        for token in tokens(in: text.string, language: language) where NSMaxRange(token.range) > location {
            let start = max(location, token.range.location)
            if start > location { segments.append((NSRange(location: location, length: start - location), plainColor)) }
            let color = colors[token.kind] ?? color(for: token.kind, scheme: scheme)
            colors[token.kind] = color
            segments.append((NSRange(location: start, length: NSMaxRange(token.range) - start), color))
            location = NSMaxRange(token.range)
        }
        if location < text.length { segments.append((NSRange(location: location, length: text.length - location), plainColor)) }

        text.beginEditing()
        for segment in segments {
            var effective = NSRange()
            let current = text.attribute(
                .foregroundColor, at: segment.range.location, longestEffectiveRange: &effective, in: segment.range
            ) as? UIColor
            if current != segment.color || effective != segment.range {
                text.addAttribute(.foregroundColor, value: segment.color, range: segment.range)
            }
        }
        text.endEditing()
    }

    /// Xcode's default colours, light and dark, darkened or lightened in
    /// their own hue where they fell short of a contrast of 7.5:1 against
    /// white, or 10:1 against black.
    static func color(for kind: SyntaxKind, scheme: ColorScheme) -> UIColor {
        let dark = scheme == .dark
        let hex: UInt32
        switch kind {
        case .keyword: hex = dark ? 0xFF91BF : 0x912189
        case .type: hex = dark ? 0xDABAFF : 0x3900A0
        case .string: hex = dark ? 0xFF978A : 0xA81613
        case .comment: hex = dark ? 0xACB5BC : 0x4A5660
        case .number: hex = dark ? 0xD9C97C : 0x1C00CF
        case .attribute: hex = dark ? 0xD6AB85 : 0x6D5003
        case .tag: hex = dark ? 0x5DD8FF : 0x0D5786
        case .property: hex = dark ? 0x7CC1B0 : 0x2A5B60
        case .variable: hex = dark ? 0xC8A7F0 : 0x6C36A9
        }
        return UIColor(
            red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

// MARK: - Languages

private struct CodeRules {
    struct StringRule {
        var delimiter: String
        var spansLines: Bool
        var escapes = true
    }

    var lineComment: String?
    var blockComment: (open: String, close: String)?
    /// Longest delimiters first, so `"""` is not taken for an empty string.
    var strings: [StringRule]
    var keywords: Set<String>
    /// Capitalised names are types, as they are by convention.
    var capitalisedTypes = true
    /// Characters that make the name after them an attribute: `@` for Swift
    /// attributes and decorators.
    var attributePrefix: Character?
    /// Characters that make the name after them a keyword: `#` for Swift's
    /// compiler directives.
    var directivePrefix: Character?
    /// Shell: `#` only starts a comment at the start of a word, and `$` starts a variable.
    var isShell = false

    init(_ language: SourceLanguage) {
        let quoted = [StringRule(delimiter: "\"", spansLines: false), StringRule(delimiter: "'", spansLines: false)]
        switch language {
        case .swift:
            lineComment = "//"
            blockComment = ("/*", "*/")
            strings = [StringRule(delimiter: "\"\"\"", spansLines: true), quoted[0]]
            keywords = Self.swift
            attributePrefix = "@"
            directivePrefix = "#"
        case .python:
            lineComment = "#"
            strings = [
                StringRule(delimiter: "\"\"\"", spansLines: true), StringRule(delimiter: "'''", spansLines: true),
            ] + quoted
            keywords = Self.python
            attributePrefix = "@"
        case .javaScript, .typeScript:
            lineComment = "//"
            blockComment = ("/*", "*/")
            strings = quoted + [StringRule(delimiter: "`", spansLines: true)]
            keywords = language == .typeScript ? Self.javaScript.union(Self.typeScript) : Self.javaScript
            attributePrefix = language == .typeScript ? "@" : nil
        case .shell:
            lineComment = "#"
            strings = [
                StringRule(delimiter: "\"", spansLines: true),
                StringRule(delimiter: "'", spansLines: true, escapes: false),
            ]
            keywords = Self.shell
            capitalisedTypes = false
            isShell = true
        case .html, .css:
            strings = quoted
            keywords = []
        }
    }

    static let swift: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "consume",
        "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "each", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import",
        "in", "indirect", "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating",
        "nil", "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package", "postfix",
        "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required", "rethrows", "return",
        "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
        "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet",
    ]
    static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else",
        "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "None",
        "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield",
    ]
    static let javaScript: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
        "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "import",
        "in", "instanceof", "let", "new", "null", "of", "return", "set", "static", "super", "switch", "this",
        "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
    ]
    static let typeScript: Set<String> = [
        "abstract", "any", "as", "asserts", "bigint", "boolean", "declare", "enum", "implements", "infer",
        "interface", "is", "keyof", "module", "namespace", "never", "number", "object", "override", "private",
        "protected", "public", "readonly", "satisfies", "string", "symbol", "type", "unique", "unknown",
    ]
    static let shell: Set<String> = [
        "alias", "break", "case", "cd", "continue", "declare", "do", "done", "echo", "elif", "else", "esac", "eval",
        "exec", "exit", "export", "false", "fi", "for", "function", "if", "in", "local", "printf", "read",
        "readonly", "return", "select", "set", "shift", "source", "then", "time", "trap", "true", "typeset",
        "unset", "until", "while",
    ]
}

// MARK: - Scanning

private struct Scanner {
    let units: [UInt16]
    var tokens: [SyntaxToken] = []

    init(units: [UInt16]) {
        self.units = units
    }

    private mutating func add(_ range: Range<Int>, _ kind: SyntaxKind) {
        guard !range.isEmpty else { return }
        tokens.append(SyntaxToken(range: NSRange(location: range.lowerBound, length: range.count), kind: kind))
    }

    // MARK: Characters

    private func unit(_ index: Int) -> UInt16? {
        index >= 0 && index < units.count ? units[index] : nil
    }

    private static func ascii(_ character: Character) -> UInt16 {
        UInt16(character.asciiValue!)
    }

    private func isNewline(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == TextCharacters.lineBreakUnit
    }

    private func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || isNewline(unit)
    }

    private func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
            // Beyond ASCII, anything not a separator or a stand-in for a picture.
            || (unit >= 0x80 && unit != TextCharacters.lineBreakUnit && unit != TextCharacters.attachmentUnit)
    }

    private func isNamePart(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit)
    }

    private func matches(_ text: String, at index: Int, ignoringCase: Bool = false) -> Bool {
        var position = index
        for expected in text.utf16 {
            guard let actual = unit(position) else { return false }
            if ignoringCase ? lowercased(actual) != lowercased(expected) : actual != expected { return false }
            position += 1
        }
        return true
    }

    private func lowercased(_ unit: UInt16) -> UInt16 {
        unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit
    }

    private func first(_ text: String, from index: Int, before end: Int, ignoringCase: Bool = false) -> Int? {
        var position = index
        while position < end {
            if matches(text, at: position, ignoringCase: ignoringCase) { return position }
            position += 1
        }
        return nil
    }

    private func lineEnd(from index: Int, before end: Int) -> Int {
        var position = index
        while position < end, !isNewline(units[position]) { position += 1 }
        return position
    }

    private func nameEnd(from index: Int, before end: Int, extra: Set<UInt16> = []) -> Int {
        var position = index
        while position < end, isNamePart(units[position]) || extra.contains(units[position]) { position += 1 }
        return position
    }

    private func word(_ range: Range<Int>) -> String {
        String(utf16CodeUnits: Array(units[range]), count: range.count)
    }

    /// A number from `index`: digits, with the letters of hex, exponents and
    /// suffixes, and a point only where a digit follows it.
    private func numberEnd(from index: Int, before end: Int) -> Int {
        var position = index
        while position < end {
            let current = units[position]
            if isNamePart(current) {
                position += 1
            } else if current == Self.ascii("."), let next = unit(position + 1), isDigit(next) {
                position += 1
            } else {
                break
            }
        }
        return min(position, end)
    }

    /// A quoted string from `index`, which is its opening delimiter.
    private func stringEnd(_ rule: CodeRules.StringRule, from index: Int, before end: Int) -> Int {
        let delimiter = rule.delimiter
        var position = index + delimiter.utf16.count
        while position < end {
            let current = units[position]
            if rule.escapes, current == Self.ascii("\\") {
                position += 2
                continue
            }
            if matches(delimiter, at: position) { return position + delimiter.utf16.count }
            if !rule.spansLines, isNewline(current) { return position }
            position += 1
        }
        return end
    }

    // MARK: Code

    mutating func scanCode(_ range: Range<Int>, rules: CodeRules) {
        let end = range.upperBound
        var index = range.lowerBound
        scanning: while index < end {
            let current = units[index]
            let previous = index > range.lowerBound ? units[index - 1] : 0x20

            if let (open, close) = rules.blockComment, matches(open, at: index) {
                let closing = first(close, from: index + open.utf16.count, before: end).map { $0 + close.utf16.count }
                let stop = min(closing ?? end, end)
                add(index..<stop, .comment)
                index = stop
                continue
            }
            if let comment = rules.lineComment, matches(comment, at: index),
               !rules.isShell || isSpace(previous) || index == range.lowerBound {
                let stop = lineEnd(from: index, before: end)
                add(index..<stop, .comment)
                index = stop
                continue
            }
            for rule in rules.strings where matches(rule.delimiter, at: index) {
                let stop = stringEnd(rule, from: index, before: end)
                add(index..<stop, .string)
                index = stop
                continue scanning
            }
            if isDigit(current), !isNamePart(previous) {
                let stop = numberEnd(from: index, before: end)
                add(index..<stop, .number)
                index = stop
                continue
            }
            if rules.isShell, current == Self.ascii("$"), let next = unit(index + 1), index + 1 < end {
                let stop: Int
                if next == Self.ascii("{") {
                    stop = min((first("}", from: index + 2, before: end) ?? end - 1) + 1, end)
                } else if isNamePart(next) {
                    stop = nameEnd(from: index + 1, before: end)
                } else {
                    // `$?`, `$@`, `$#` and the like.
                    stop = isSpace(next) ? index + 1 : index + 2
                }
                add(index..<stop, .variable)
                index = max(stop, index + 1)
                continue
            }
            let prefix = current < 0x80 ? Character(UnicodeScalar(UInt8(current))) : nil
            if let prefix, prefix == rules.attributePrefix || prefix == rules.directivePrefix,
               let next = unit(index + 1), isLetter(next), !isNamePart(previous) {
                let stop = nameEnd(from: index + 1, before: end, extra: [Self.ascii(".")])
                add(index..<stop, prefix == rules.attributePrefix ? .attribute : .keyword)
                index = stop
                continue
            }
            if isLetter(current), !isNamePart(previous) {
                // Shell words run on through hyphens, as in `set -e` or `my-script`.
                let stop = nameEnd(from: index, before: end, extra: rules.isShell ? [Self.ascii("-")] : [])
                let name = word(index..<stop)
                if rules.keywords.contains(name), previous != Self.ascii(".") {
                    add(index..<stop, .keyword)
                } else if rules.capitalisedTypes, let first = name.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first) {
                    add(index..<stop, .type)
                }
                index = stop
                continue
            }
            index += 1
        }
    }

    // MARK: HTML

    mutating func scanHTML(_ range: Range<Int>) {
        let end = range.upperBound
        var index = range.lowerBound
        while index < end {
            if matches("<!--", at: index) {
                let stop = min((first("-->", from: index + 4, before: end) ?? end - 3) + 3, end)
                add(index..<stop, .comment)
                index = stop
            } else if matches("<!", at: index) || matches("<?", at: index) {
                let stop = min((first(">", from: index, before: end) ?? end - 1) + 1, end)
                add(index..<stop, .keyword)
                index = stop
            } else if units[index] == Self.ascii("<"), let next = unit(index + 1), index + 1 < end,
                      isLetter(next) || next == Self.ascii("/") {
                index = scanTag(from: index, before: end)
            } else if units[index] == Self.ascii("&") {
                let stop = nameEnd(from: index + 1, before: end, extra: [Self.ascii("#")])
                if stop > index + 1, unit(stop) == Self.ascii(";"), stop < end {
                    add(index..<(stop + 1), .number)
                    index = stop + 1
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
    }

    /// A tag from its `<`, with its attributes, and the script or style it opens.
    private mutating func scanTag(from start: Int, before end: Int) -> Int {
        let isClosing = units[start + 1] == Self.ascii("/")
        let nameStart = start + (isClosing ? 2 : 1)
        let nameStop = nameEnd(from: nameStart, before: end, extra: [Self.ascii("-"), Self.ascii(":")])
        add(start..<nameStop, .tag)
        let name = word(nameStart..<nameStop).lowercased()

        var index = nameStop
        while index < end {
            let current = units[index]
            if current == Self.ascii(">") || matches("/>", at: index) {
                let stop = current == Self.ascii(">") ? index + 1 : index + 2
                add(index..<stop, .tag)
                index = stop
                break
            } else if current == Self.ascii("\"") || current == Self.ascii("'") {
                let stop = stringEnd(CodeRules.StringRule(delimiter: current == 0x22 ? "\"" : "'", spansLines: true, escapes: false),
                                     from: index, before: end)
                add(index..<stop, .string)
                index = stop
            } else if isSpace(current) || current == Self.ascii("=") {
                index += 1
            } else {
                var stop = index
                while stop < end, !isSpace(units[stop]), !"=>\"'".utf16.contains(units[stop]), !matches("/>", at: stop) {
                    stop += 1
                }
                // A value without quotes follows its `=`.
                let isValue = index > nameStop && units[index - 1] == Self.ascii("=")
                add(index..<max(stop, index + 1), isValue ? .string : .property)
                index = max(stop, index + 1)
            }
        }

        // What a script or style element holds is code of its own.
        guard !isClosing, name == "script" || name == "style" else { return index }
        let closing = first("</\(name)", from: index, before: end, ignoringCase: true) ?? end
        if name == "script" {
            scanCode(index..<closing, rules: CodeRules(.javaScript))
        } else {
            scanCSS(index..<closing)
        }
        return closing
    }

    // MARK: CSS

    mutating func scanCSS(_ range: Range<Int>) {
        let end = range.upperBound
        var index = range.lowerBound
        var depth = 0
        // Whether the current statement is a selector, worked out from
        // whether a block or the end of a declaration comes first.
        var isSelector: Bool?
        let nameExtra: Set<UInt16> = [Self.ascii("-")]
        while index < end {
            let current = units[index]
            let previous = index > range.lowerBound ? units[index - 1] : 0x20
            if matches("/*", at: index) {
                let stop = min((first("*/", from: index + 2, before: end) ?? end - 2) + 2, end)
                add(index..<stop, .comment)
                index = stop
            } else if current == Self.ascii("\"") || current == Self.ascii("'") {
                let rule = CodeRules.StringRule(delimiter: current == 0x22 ? "\"" : "'", spansLines: false)
                let stop = stringEnd(rule, from: index, before: end)
                add(index..<stop, .string)
                index = stop
            } else if current == Self.ascii("{") || current == Self.ascii("}") || current == Self.ascii(";") {
                if current != Self.ascii(";") { depth = max(0, depth + (current == Self.ascii("{") ? 1 : -1)) }
                isSelector = nil
                index += 1
            } else if current == Self.ascii("@") || (current == Self.ascii("!") && matches("!important", at: index)) {
                let stop = nameEnd(from: index + 1, before: end, extra: nameExtra)
                add(index..<stop, .keyword)
                index = stop
            } else if isSelector ?? opensBlock(from: index, before: end, orAtTopLevel: depth == 0) {
                isSelector = true
                if (current == Self.ascii(".") || current == Self.ascii("#")), let next = unit(index + 1), isLetter(next) {
                    let stop = nameEnd(from: index + 1, before: end, extra: nameExtra)
                    add(index..<stop, .attribute)
                    index = stop
                } else if current == Self.ascii(":") {
                    let start = unit(index + 1) == Self.ascii(":") ? index + 2 : index + 1
                    let stop = nameEnd(from: start, before: end, extra: nameExtra)
                    add(index..<stop, .keyword)
                    index = max(stop, index + 1)
                } else if isLetter(current), !isNamePart(previous) {
                    let stop = nameEnd(from: index, before: end, extra: nameExtra)
                    add(index..<stop, .tag)
                    index = stop
                } else {
                    index += 1
                }
            } else {
                isSelector = false
                if current == Self.ascii("#"), let next = unit(index + 1), isNamePart(next) {
                    let stop = nameEnd(from: index + 1, before: end)
                    add(index..<stop, .number)
                    index = stop
                } else if (isDigit(current) || (current == Self.ascii(".") && unit(index + 1).map(isDigit) == true)),
                          !isNamePart(previous) {
                    var stop = numberEnd(from: index, before: end)
                    if unit(stop) == Self.ascii("%"), stop < end { stop += 1 }
                    add(index..<stop, .number)
                    index = stop
                } else if isLetter(current) || (current == Self.ascii("-") && unit(index + 1).map(isLetter) == true),
                          !isNamePart(previous), previous != Self.ascii("-") {
                    let stop = nameEnd(from: index, before: end, extra: nameExtra)
                    var after = stop
                    while after < end, units[after] == 0x20 || units[after] == 0x09 { after += 1 }
                    if unit(after) == Self.ascii(":") { add(index..<stop, .property) }
                    index = max(stop, index + 1)
                } else {
                    index += 1
                }
            }
        }
    }

    /// Whether a block opens before the statement from `index` ends, as it
    /// does after a selector. Text running to the end is a selector only
    /// outside every block.
    private func opensBlock(from index: Int, before end: Int, orAtTopLevel topLevel: Bool) -> Bool {
        var position = index
        while position < end {
            switch units[position] {
            case Self.ascii("{"): return true
            case Self.ascii(";"), Self.ascii("}"): return false
            default: position += 1
            }
        }
        return topLevel
    }
}
