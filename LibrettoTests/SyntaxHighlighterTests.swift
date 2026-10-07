import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Libretto

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    /// Each token's text and kind.
    private func tokens(_ text: String, _ language: SourceLanguage) -> [String: SyntaxKind] {
        let string = text as NSString
        var result: [String: SyntaxKind] = [:]
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            result[string.substring(with: token.range)] = token.kind
        }
        return result
    }

    @Test("Swift keywords, types, strings, comments, numbers and attributes")
    func swift() {
        let found = tokens("""
            @MainActor final class View { // note
                let name: String = "a \\"b\\""
                /* block
                   comment */ var count = 42
            #if DEBUG
            }
            """, .swift)
        #expect(found["@MainActor"] == .attribute)
        #expect(found["final"] == .keyword)
        #expect(found["View"] == .type)
        #expect(found["String"] == .type)
        #expect(found["// note"] == .comment)
        #expect(found["\"a \\\"b\\\"\""] == .string)
        #expect(found.first { $0.key.hasPrefix("/* block\n") && $0.key.hasSuffix("comment */") }?.value == .comment)
        #expect(found["42"] == .number)
        #expect(found["#if"] == .keyword)
        #expect(found["name"] == nil)
    }

    @Test("Python strings and comments, and keywords only where they are words")
    func python() {
        let found = tokens("def f(x):\n    '''doc\n    string'''\n    return x.def  # done\n", .python)
        #expect(found["def"] == .keyword)
        #expect(found["'''doc\n    string'''"] == .string)
        #expect(found["return"] == .keyword)
        #expect(found["# done"] == .comment)
        #expect(tokens("x.def", .python)["def"] == nil)
    }

    @Test("TypeScript has its own keywords and keeps template strings whole")
    func scripts() {
        let found = tokens("interface A { b: number }\nconst s = `x\ny`", .typeScript)
        #expect(found["interface"] == .keyword)
        #expect(found["number"] == .keyword)
        #expect(found["`x\ny`"] == .string)
        #expect(tokens("interface A {}", .javaScript)["interface"] == nil)
    }

    @Test("Shell variables, and # only as a comment at the start of a word")
    func shell() {
        let found = tokens("if [ -n \"$HOME\" ]; then echo ${#ARR} $1 # done\nfi", .shell)
        #expect(found["if"] == .keyword)
        #expect(found["\"$HOME\""] == .string)
        #expect(found["${#ARR}"] == .variable)
        #expect(found["$1"] == .variable)
        #expect(found["# done"] == .comment)
        #expect(found["fi"] == .keyword)
    }

    @Test("HTML tags and attributes, with the script and style inside them")
    func html() {
        let found = tokens("""
            <!-- c --><a href="x" hidden>&amp;</a>
            <script>let n = 1</script><style>p { color: red }</style>
            """, .html)
        #expect(found["<!-- c -->"] == .comment)
        #expect(found["<a"] == .tag)
        #expect(found["href"] == .property)
        #expect(found["\"x\""] == .string)
        #expect(found["hidden"] == .property)
        #expect(found["&amp;"] == .number)
        #expect(found["</a"] == .tag)
        #expect(found["let"] == .keyword)
        #expect(found["p"] == .tag)
        #expect(found["color"] == .property)
    }

    @Test("CSS selectors, properties, numbers and at-rules")
    func css() {
        let found = tokens("@media screen { .card > h1:hover { margin: -4px 1.5em; color: #fff !important; } }", .css)
        #expect(found["@media"] == .keyword)
        #expect(found[".card"] == .attribute)
        #expect(found["h1"] == .tag)
        #expect(found[":hover"] == .keyword)
        #expect(found["margin"] == .property)
        #expect(found["4px"] == .number)
        #expect(found["1.5em"] == .number)
        #expect(found["#fff"] == .number)
        #expect(found["!important"] == .keyword)
    }

    @Test("A file's language comes from its name, or its type")
    func languages() {
        #expect(SourceLanguage(contentType: .mpeg2TransportStream, filename: "app.ts") == .typeScript)
        #expect(SourceLanguage(contentType: .plainText, filename: "run.sh") == .shell)
        #expect(SourceLanguage(contentType: .pythonScript, filename: nil) == .python)
        #expect(SourceLanguage(contentType: .plainText, filename: "notes.txt") == nil)
        #expect(SourceLanguage(contentType: .markdownDocument, filename: "README.md") == nil)
    }

    @Test("Colouring changes only colours, so the text reads back the same")
    func applying() {
        let text = NSMutableAttributedString(string: "let x = 1 // c", attributes: [.foregroundColor: UIColor.black])
        SyntaxHighlighter.apply(.swift, to: text, scheme: .light, plainColor: .black)
        let keyword = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let plain = text.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor
        #expect(keyword == SyntaxHighlighter.color(for: .keyword, scheme: .light))
        #expect(plain == .black)
        #expect(text.string == "let x = 1 // c")
    }
}
