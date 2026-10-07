import Foundation
import Testing
@testable import Libretto

@Suite("Plain text")
struct PlainTextTests {
    @Test("Each line is a paragraph, and tabs stay tabs")
    func lines() {
        let document = PlainText.document(from: Data("First line\n\nA\ttab\n".utf8))
        let paragraphs = document.body.compactMap { block -> Paragraph? in
            guard case .paragraph(let paragraph) = block else { return nil }
            return paragraph
        }
        #expect(paragraphs.map(\.plainText) == ["First line", "", "A\ttab"])
        #expect(paragraphs[2].inlines.map(\.content) == [.text("A"), .tab, .text("tab")])
    }

    @Test("Text saves back as it was read")
    func roundTrip() {
        let text = "One\n\n  Two\twith a tab\nThree\n"
        let document = PlainText.document(from: Data(text.utf8))
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == text)
    }

    @Test("Byte order marks and Windows line endings are read through")
    func encodings() {
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("Hello\r\nWorld".data(using: .utf16LittleEndian)!)
        #expect(PlainText.string(from: utf16) == "Hello\nWorld")
        #expect(PlainText.string(from: Data([0xEF, 0xBB, 0xBF]) + Data("Hi\r".utf8)) == "Hi\n")
        #expect(PlainText.string(from: Data([0x63, 0x61, 0x66, 0xE9])) == "café")
    }

    @Test("Formatting and tables come out as their text")
    func writing() {
        var document = WordDocument()
        var bold = Inline(.text("Bold"))
        bold.format.style.isBold = true
        let cell = { (text: String) in TableCell(blocks: [.paragraph(Paragraph(text: text))]) }
        document.body = [
            .paragraph(Paragraph(inlines: [bold, Inline(.lineBreak), Inline(.text("next"))])),
            .table(Table(rows: [TableRow(cells: [cell("a"), cell("b")])], gridColumns: [], hasBorders: false)),
        ]
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == "Bold\nnext\na\tb\n")
    }
}
