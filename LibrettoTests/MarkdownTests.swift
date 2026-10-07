import Foundation
import Testing
@testable import Libretto

@Suite("Markdown")
struct MarkdownTests {
    private func paragraphs(_ document: WordDocument) -> [Paragraph] {
        document.body.compactMap { block in
            guard case .paragraph(let paragraph) = block else { return nil }
            return paragraph
        }
    }

    private func roundTrip(_ text: String) -> String {
        MarkdownWriter.string(from: MarkdownReader.document(from: text))
    }

    @Test("Headings, quotes and lists take Libretto's styles")
    func blocks() {
        let document = MarkdownReader.document(from: """
            # Title

            Some text
            on two lines.

            > Quoted

            - One
              - Nested
            1. First
            """)
        let paragraphs = paragraphs(document)
        #expect(paragraphs.map(\.plainText) == ["Title", "Some text\non two lines.", "Quoted", "One", "Nested", "First"])
        #expect(paragraphs[0].properties.styleID == "Heading1")
        #expect(paragraphs[2].properties.styleID == "Quote")
        #expect(paragraphs[3].properties.list?.level == 0)
        #expect(paragraphs[4].properties.list?.level == 1)
        #expect(paragraphs[4].properties.list?.numberingID == paragraphs[3].properties.list?.numberingID)
        #expect(paragraphs[5].properties.list.flatMap { document.numbering.kind(of: $0.numberingID) } == .numbered)
    }

    @Test("Emphasis, code and links become formatting")
    func inlines() throws {
        let spans = MarkdownInlineReader.spans("Plain **bold** *it* ~~gone~~ `x*y` [site](https://example.com/) 2*3")
        #expect(spans.map(\.text) == ["Plain ", "bold", " ", "it", " ", "gone", " ", "x*y", " ", "site", " 2*3"])
        #expect(spans[1].marks.bold)
        #expect(spans[3].marks.italic)
        #expect(spans[5].marks.struckThrough)
        #expect(spans[7].marks.code)
        #expect(spans[9].marks.link == URL(string: "https://example.com/"))
        #expect(MarkdownInlineReader.spans("snake_case_name").count == 1)
        #expect(MarkdownInlineReader.spans("***both***").first?.marks == MarkdownMarks(bold: true, italic: true))
    }

    @Test("Markdown Libretto does not model saves back as it was written")
    func faithful() {
        let text = """
            # Libretto

            A *word* processor for `.docx`, with **bold** and [links](https://example.com/a_b).
            Pictures ![logo](img/logo_v2.png) and <b>HTML</b> stay, as do 2 * 3 and snake_case.

            | Column | Other |
            | --- | --- |
            | a | b |

            ```swift
            let x = a * b_c
            ```

            ---

            - Item one
            - Item **two**
              - Nested

            1. First
            2. Second

            > A quote
            > on two lines
            >
            > and another paragraph.

                indented code
            """
        #expect(roundTrip(text) == text + "\n")
    }

    @Test("Text that looks like Markdown is escaped when written")
    func escaping() {
        var document = WordDocument()
        var bold = Inline(.text("bold"))
        bold.format.style.isBold = true
        document.body = [
            .paragraph(Paragraph(text: "# not a heading")),
            .paragraph(Paragraph(text: "1. not a list")),
            .paragraph(Paragraph(text: "*stars* and [brackets](x)")),
            .paragraph(Paragraph(inlines: [Inline(.text("a ")), bold, Inline(.text(" word"))])),
        ]
        let text = MarkdownWriter.string(from: document)
        #expect(text == "\\# not a heading\n\n1\\. not a list\n\n\\*stars\\* and \\[brackets\\](x)\n\na **bold** word\n")
        let reread = paragraphs(MarkdownReader.document(from: text))
        #expect(reread.map(\.plainText) == ["# not a heading", "1. not a list", "*stars* and [brackets](x)", "a bold word"])
        #expect(reread.allSatisfy { $0.properties.styleID == nil && $0.properties.list == nil })
    }

    @Test("Formatting given in Libretto is written as Markdown")
    func writingFormatting() {
        var document = WordDocument()
        var heading = Paragraph(text: "Heading")
        heading.properties.styleID = "Heading2"
        var item = Paragraph(text: "Item")
        item.properties.list = ListReference(numberingID: document.numbering.addList(.numbered), level: 0)
        var link = Inline(.text("here"))
        link.hyperlink = Hyperlink(url: URL(string: "https://example.com/"), attributesXML: "")
        var code = Inline(.text("code"))
        code.format.style.fontName = Markdown.codeFont
        var spaced = Inline(.text(" italic "))
        spaced.format.style.isItalic = true
        document.body = [
            .paragraph(heading),
            .paragraph(item),
            .paragraph(item),
            .paragraph(Paragraph(inlines: [Inline(.text("See")), spaced, link, Inline(.text(" and ")), code])),
        ]
        #expect(MarkdownWriter.string(from: document) == """
            ## Heading

            1. Item
            2. Item

            See *italic* [here](https://example.com/) and `code`

            """)
    }
}
