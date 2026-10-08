import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Character and paragraph formatting")
struct FormattingTests {
    private func makeController(text: String) -> (DocumentTextController, EditorState, () -> WordDocument?) {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: text))]
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, state, { latest })
    }

    private func firstParagraph(_ document: WordDocument?) -> Paragraph? {
        guard case .paragraph(let paragraph)? = document?.body.first else { return nil }
        return paragraph
    }

    private func xml(_ document: WordDocument) throws -> String {
        String(decoding: try ZipArchive.entries(in: DOCXWriter.data(from: document))["word/document.xml"]!, as: UTF8.self)
    }

    @Test("Underline kinds, effects, spacing and position are written and read back")
    func effects() throws {
        let (controller, state, latest) = makeController(text: "Fine print")
        controller.textView.selectedRange = NSRange(location: 0, length: 4)
        controller.setUnderline("double")
        controller.setEffect(\.smallCaps, true)
        controller.setEffect(\.isDoubleStruckThrough, true)
        controller.setEffect(\.outline, true)
        controller.setCharacterSpacing(30)
        controller.setPosition(-4)
        #expect(state.selectionFormat.underlineKind == "double")
        #expect(state.selectionFormat.smallCaps)

        let document = try #require(latest())
        let style = try #require(firstParagraph(document)?.inlines.first?.format.style)
        #expect(style.underline == true && style.underlineStyle == "double")
        let written = try xml(document)
        #expect(written.contains("<w:rPr><w:smallCaps/><w:dstrike/><w:outline/><w:spacing w:val=\"30\"/><w:position w:val=\"-4\"/><w:u w:val=\"double\"/></w:rPr>"))

        let reread = try DOCXReader.document(from: DOCXWriter.data(from: document))
        #expect(firstParagraph(reread)?.inlines.first?.format.style == style)

        controller.setUnderline("none")
        #expect(firstParagraph(latest())?.inlines.first?.format.style.underline == nil)
    }

    @Test("Page breaking settings, borders, shading and tab stops are written and read back")
    func paragraphSettings() throws {
        let (controller, state, latest) = makeController(text: "Total\t12.5")
        controller.setParagraphFlag(\.keepNext, true)
        controller.setParagraphFlag(\.widowControl, true)
        let line = BorderLine(style: "double", size: 6, colorHex: "FF0000", space: 4)
        controller.setBorders(ParagraphBorders(top: line, bottom: line))
        controller.setShading("FFEEEEEE")
        controller.setTabStops([TabStop(position: 4320, alignment: .decimal, leader: "dot")])
        #expect(state.selectionFormat.keepNext)
        #expect(state.selectionFormat.tabStops.first?.leader == "dot")

        let document = try #require(latest())
        let written = try xml(document)
        #expect(written.contains("<w:keepNext/><w:widowControl/><w:pBdr>"))
        #expect(written.contains("<w:top w:color=\"FF0000\" w:space=\"4\" w:sz=\"6\" w:val=\"double\"/>"))
        #expect(written.contains("<w:shd w:color=\"auto\" w:fill=\"EEEEEE\" w:val=\"clear\"/>"))
        #expect(written.contains("<w:tabs><w:tab w:leader=\"dot\" w:pos=\"4320\" w:val=\"decimal\"/></w:tabs>"))

        let reread = try DOCXReader.document(from: DOCXWriter.data(from: document))
        #expect(firstParagraph(reread)?.properties == firstParagraph(document)?.properties)
        let paragraphStyle = controller.textView.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
        #expect(paragraphStyle?.tabStops.first?.location == 216)
    }

    @Test("A style's tab stop the paragraph does without is cleared")
    func clearsStyleTabs() {
        let style = ParagraphProperties(tabStops: [TabStop(position: 720), TabStop(position: 1440)])
        let own = ParagraphProperties(tabStops: [TabStop(position: 720, alignment: .clear), TabStop(position: 2160, alignment: .right)])
        #expect(style.merged(with: own).tabStops == [TabStop(position: 1440), TabStop(position: 2160, alignment: .right)])
    }

    @Test("A heading kept with the next paragraph goes over to the next page with it")
    func keepsWithNext() throws {
        func pages(filler count: Int, keep: Bool) -> (heading: Int, body: Int) {
            var document = WordDocument()
            var heading = Paragraph(text: "Heading")
            heading.properties.keepNext = keep
            document.body = (0..<count).map { Block.paragraph(Paragraph(text: "Line \($0)")) }
                + [.paragraph(heading), .paragraph(Paragraph(text: "Body after the heading."))]
            let controller = DocumentTextController(document: document, scheme: .light)
            let layout = controller.layoutManager
            let text = controller.textView.textStorage.string as NSString
            func page(of string: String) -> Int {
                let glyph = layout.glyphIndexForCharacter(at: text.range(of: string).location)
                return controller.geometry.page(containing: layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).midY)
            }
            return (page(of: "Heading"), page(of: "Body after"))
        }
        // Enough lines that, left to itself, the heading ends the first page, alone.
        let count = try #require((20..<80).first { pages(filler: $0, keep: false) == (0, 1) })
        #expect(pages(filler: count, keep: true) == (1, 1))
    }

    @Test("Text in capitals is drawn with capital glyphs, and keeps its letters")
    func allCaps() throws {
        let (controller, _, latest) = makeController(text: "abc")
        controller.textView.selectedRange = NSRange(location: 0, length: 3)
        controller.setEffect(\.allCaps, true)
        #expect(firstParagraph(latest())?.plainText == "abc")

        let layout = controller.layoutManager
        layout.ensureLayout(for: layout.textContainers[0])
        let font = try #require(controller.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        var capital: UniChar = 0x41
        var expected = CGGlyph()
        _ = CTFontGetGlyphsForCharacters(font as CTFont, &capital, &expected, 1)
        #expect(layout.cgGlyph(at: 0) == expected)
    }
}
