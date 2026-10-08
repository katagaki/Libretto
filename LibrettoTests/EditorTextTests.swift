import Foundation
import Testing
import UIKit
@testable import Libretto

@Suite("Editor text")
struct EditorTextTests {
    private func render(_ document: WordDocument) -> RenderedText {
        DocumentRenderer.render(document.body, context: RenderContext(document: document, scheme: .light, images: ImageStore()))
    }

    private func read(_ rendered: RenderedText, _ text: NSAttributedString? = nil) -> AttributedReader.Result {
        AttributedReader.blocks(
            from: text ?? rendered.string, finalParagraph: rendered.finalParagraph,
            trailingMarkers: rendered.trailingMarkers
        )
    }

    @Test("Text reads back as exactly the document it was rendered from")
    func roundTrip() throws {
        let document = try Fixtures.document()
        let rendered = render(document)
        let read = read(rendered)
        #expect(read.blocks == document.body)
        #expect(!read.needsRender)
    }

    @Test("Typing changes only the paragraph typed in")
    func typing() throws {
        let document = try Fixtures.document()
        let rendered = render(document)
        let text = NSMutableAttributedString(attributedString: rendered.string)
        let location = (text.string as NSString).range(of: "Second item").location
        let attributes = text.attributes(at: location, effectiveRange: nil)
        text.insert(NSAttributedString(string: "Very ", attributes: attributes), at: location)

        let blocks = read(rendered, text).blocks
        #expect(blocks.count == document.body.count)
        guard case .paragraph(let edited) = blocks[3] else { return }
        #expect(edited.plainText == "Very Second item")
        #expect(edited.inlines != edited.originalInlines)
        for index in blocks.indices where index != 3 {
            #expect(blocks[index] == document.body[index])
        }
    }

    @Test("Splitting a paragraph leaves its section break with the second half")
    func splitting() throws {
        let document = try Fixtures.document()
        let rendered = render(document)
        let text = NSMutableAttributedString(attributedString: rendered.string)
        let location = (text.string as NSString).range(of: "Appendix").location + 3
        text.insert(NSAttributedString(string: "\n", attributes: text.attributes(at: location, effectiveRange: nil)), at: location)

        let blocks = read(rendered, text).blocks
        guard case .paragraph(let first) = blocks[6], case .paragraph(let second) = blocks[7] else {
            Issue.record("the paragraph did not split")
            return
        }
        #expect(first.plainText == "App")
        #expect(second.plainText == "endix")
        #expect(first.id != second.id)
        #expect(!(first.preservedPropertiesXML ?? "").contains("sectPr"))
        #expect((second.preservedPropertiesXML ?? "").contains("sectPr"))
    }

    @Test("Deleting a table's row takes it out of the table")
    func deletingRows() throws {
        let document = try Fixtures.document()
        let rendered = render(document)
        let text = NSMutableAttributedString(attributedString: rendered.string)
        var rows: [NSRange] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value is BlockAttachment { rows.append(range) }
        }
        #expect(rows.count == 2)
        // The second row, and the line break before it.
        text.deleteCharacters(in: NSRange(location: rows[1].location - 1, length: 2))

        let read = read(rendered, text)
        guard case .table(let table) = read.blocks[4] else { return }
        #expect(table.rows.count == 1)
        #expect(read.needsRender)
    }

    @Test("Page breaks and pictures keep their places")
    func specialCharacters() throws {
        let document = try Fixtures.document()
        let string = render(document).string.string
        #expect(string.contains(TextCharacters.pageBreak))
        #expect(string.components(separatedBy: TextCharacters.attachment).count - 1 == 2)
    }

    @Test("Text lays out in pages that break where the document breaks them")
    func pagination() throws {
        let document = try Fixtures.document()
        let geometry = PageGeometry(setup: document.pageSetup, gap: 20)
        let storage = NSTextStorage(attributedString: render(document).string)
        let layoutManager = PageLayoutManager(geometry: geometry)
        layoutManager.styles = document.styles
        let container = NSTextContainer()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let pages = layoutManager.layOutPages(in: container, startingWith: 1)
        #expect(pages == 2)

        // The paragraph after the page break starts the second page.
        let location = (storage.string as NSString).range(of: "Appendix").location
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        #expect(geometry.page(containing: line.minY) == 1)
        #expect(line.minY - layoutManager.geometry.textTop(1) < 1)
    }

    @Test("A PDF has a page per page, each section's at its own size")
    func pdf() throws {
        let data = PDFExporter.data(from: try Fixtures.document())
        #expect(data.starts(with: Array("%PDF".utf8)))
        let pdf = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        // The page break, then the section break after the appendix's heading.
        #expect(pdf.numberOfPages == 3)
        let sizes = (1...3).map { pdf.page(at: $0)?.getBoxRect(.mediaBox).size }
        #expect(sizes[1].map { abs($0.width - 595.3) < 1 && abs($0.height - 841.9) < 1 } == true)
        #expect(sizes[2] == CGSize(width: 612, height: 792))
    }

    @Test("The reader lays every block out, and makes one space of many")
    func mobileLayout() throws {
        var document = try Fixtures.document()
        document.body.insert(contentsOf: [.paragraph(Paragraph()), .paragraph(Paragraph())], at: 1)
        let items = MobileLayout(document: document, scheme: .light).items
        let spacers = items.filter { if case .spacer = $0.content { return true } else { return false } }
        let tables = items.filter { if case .table = $0.content { return true } else { return false } }
        // The page-break paragraph is empty to a reader, so it makes a space too.
        #expect(spacers.count == 2)
        #expect(tables.count == 1)
    }
}

@Suite("Editor text, beyond the Basic Multilingual Plane")
struct AstralTextTests {
    @Test("Emoji and mathematical letters read back whole")
    func astral() {
        let document = { () -> WordDocument in
            var document = WordDocument()
            let bookmark = Inline(.paragraphChild(xml: "<w:bookmarkStart w:id=\"0\" w:name=\"a\"/>", display: nil))
            document.body = [.paragraph(Paragraph(inlines: [
                Inline(.text("Smile 😀, math ")), bookmark, Inline(.text("𝑆, flag 🇯🇵.")),
            ]))]
            return document
        }()
        let rendered = DocumentRenderer.render(
            document.body, context: RenderContext(document: document, scheme: .light, images: ImageStore())
        )
        let read = AttributedReader.blocks(
            from: rendered.string, finalParagraph: rendered.finalParagraph, trailingMarkers: rendered.trailingMarkers
        )
        // A marker riding on a character made of two UTF-16 units included.
        #expect(read.blocks == document.body)
        #expect(read.blocks.first?.paragraphs.first?.plainText == "Smile 😀, math 𝑆, flag 🇯🇵.")
    }
}
