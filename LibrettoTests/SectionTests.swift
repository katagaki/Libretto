import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Sections")
struct SectionTests {
    private func makeController(_ texts: [String]) -> (DocumentTextController, () -> WordDocument?) {
        var document = WordDocument()
        document.body = texts.map { .paragraph(Paragraph(text: $0)) }
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, { latest })
    }

    private func page(of text: String, in controller: DocumentTextController) -> Int {
        let string = controller.textView.textStorage.string as NSString
        let layout = controller.layoutManager
        let glyph = layout.glyphIndexForCharacter(at: string.range(of: text).location)
        return controller.geometry.page(containing: layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).midY)
    }

    @Test("A section in a file is read from its paragraph, and written back as it was")
    func reads() throws {
        let document = try Fixtures.document()
        let appendix = document.allParagraphs.first { $0.plainText == "Appendix" }
        #expect(appendix?.section?.width == 11906)
        #expect(document.unsupportedFeatures.isEmpty)
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<w:pPr><w:sectPr><w:pgSz w:h=\"16838\" w:w=\"11906\"/></w:sectPr></w:pPr>"))
    }

    @Test("A section break splits the paragraph, and each section has pages of its own size")
    func breaks() throws {
        let (controller, latest) = makeController(["One Two"])
        controller.textView.selectedRange = NSRange(location: 4, length: 0)
        controller.insertSectionBreak(.nextPage)
        // The first section turns landscape; the second keeps the document's page.
        controller.textView.selectedRange = NSRange(location: 1, length: 0)
        controller.updateSection { setup in swap(&setup.width, &setup.height) }

        let document = try #require(latest())
        #expect(document.allParagraphs.map(\.plainText) == ["One ", "Two"])
        let first = try #require(document.allParagraphs.first?.section)
        #expect(first.isLandscape)
        #expect(!document.pageSetup.isLandscape)
        #expect(page(of: "Two", in: controller) == 1)
        #expect(controller.geometry.shape(0).size.width > controller.geometry.shape(1).size.width)

        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<w:p><w:pPr><w:sectPr>"))
        #expect(xml.contains("w:orient=\"landscape\""))
        let reread = try DOCXReader.document(fromParts: try Fixtures.written(document))
        #expect(reread.allParagraphs.first?.section?.isLandscape == true)
    }

    @Test("A section that starts on an odd page leaves an even page blank before it")
    func oddPage() throws {
        let (controller, latest) = makeController(["Front", "Chapter"])
        controller.textView.selectedRange = NSRange(location: 6, length: 0)
        controller.insertSectionBreak(.oddPage)
        #expect(latest()?.pageSetup.start == .oddPage)
        // Page index 2 is the third page, an odd one.
        #expect(page(of: "Chapter", in: controller) == 2)
    }

    @Test("A column break ends the page in one column, and is written as one")
    func columnBreak() throws {
        let (controller, latest) = makeController(["Left Right"])
        controller.textView.selectedRange = NSRange(location: 5, length: 0)
        controller.insertColumnBreak()
        #expect(page(of: "Right", in: controller) == 1)
        let document = try #require(latest())
        #expect(Fixtures.text(try Fixtures.written(document), "word/document.xml").contains("<w:br w:type=\"column\"/>"))
        let reread = try DOCXReader.document(fromParts: try Fixtures.written(document))
        #expect(reread.allParagraphs.first?.inlines.contains { $0.content == .columnBreak } == true)
    }
}
