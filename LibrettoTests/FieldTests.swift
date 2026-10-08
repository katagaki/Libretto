import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Updating and inserting fields")
struct FieldUpdateTests {
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

    @Test("Dates follow Word's pictures, and codes split into their words")
    func pictures() {
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 8, hour: 14, minute: 5).date!
        #expect(Fields.date(date, picture: "yyyy-MM-dd") == "2026-10-08")
        #expect(Fields.date(date, picture: "h:mm").hasPrefix("2:05"))
        #expect(Fields.words(" DATE \\@ \"d MMMM yyyy\" ") == ["DATE", "\\@", "d MMMM yyyy"])
        #expect(Fields.number(4, "ROMAN") == "IV")
    }

    @Test("Captions number themselves, and number again when one goes in before")
    func captions() throws {
        let (controller, latest) = makeController(["A", "B"])
        controller.textView.selectedRange = NSRange(location: 3, length: 0)
        controller.insertCaption("Figure")
        #expect(latest()?.allParagraphs.map(\.plainText) == ["A", "BFigure 1"])
        controller.textView.selectedRange = NSRange(location: 1, length: 0)
        controller.insertCaption("Figure")
        #expect(latest()?.allParagraphs.map(\.plainText) == ["AFigure 1", "BFigure 2"])

        let xml = Fixtures.text(try Fixtures.written(try #require(latest())), "word/document.xml")
        #expect(xml.contains("<w:fldChar w:fldCharType=\"begin\"/>"))
        #expect(xml.contains("<w:instrText xml:space=\"preserve\"> SEQ Figure \\* ARABIC </w:instrText>"))
        #expect(xml.contains("<w:t xml:space=\"preserve\">2</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/>"))
    }

    @Test("Cross-references give a bookmark's text and page, and the page number its own")
    func references() throws {
        let (controller, latest) = makeController(["Intro", "Details"])
        controller.textView.selectedRange = NSRange(location: 6, length: 7)
        controller.addBookmark("details")
        controller.textView.selectedRange = NSRange(location: 5, length: 0)
        controller.insertField("REF details \\h")
        controller.insertField("PAGEREF details \\h")
        controller.insertField("PAGE")
        controller.insertField("NUMPAGES")
        #expect(latest()?.allParagraphs.first?.plainText == "IntroDetails111")
    }

    @Test("A table of contents lists the headings with their pages, and is built afresh when they change")
    func contents() throws {
        var document = WordDocument()
        var intro = Paragraph(text: "Introduction")
        intro.properties.styleID = document.styles.ensureStyle(.heading1)
        var detail = Paragraph(text: "Detail")
        detail.properties.styleID = document.styles.ensureStyle(.heading2)
        detail.properties.pageBreakBefore = true
        document.body = [.paragraph(Paragraph(text: "")), .paragraph(intro), .paragraph(Paragraph(text: "Body")), .paragraph(detail)]
        let controller = DocumentTextController(document: document, scheme: .light)
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        controller.textView.selectedRange = NSRange(location: 0, length: 0)
        controller.insertTableOfContents()

        let withContents = try #require(latest)
        let texts = withContents.allParagraphs.map(\.plainText)
        #expect(texts.prefix(2) == ["Introduction\t1", "Detail\t2"])
        #expect(withContents.allParagraphs[0].properties.styleID == "TOC1")
        #expect(withContents.allParagraphs[1].properties.styleID == "TOC2")
        #expect(withContents.allParagraphs[1].inlines.first?.hyperlink?.anchor?.hasPrefix("_Toc") == true)
        let xml = Fixtures.text(try Fixtures.written(withContents), "word/document.xml")
        #expect(xml.contains(" TOC \\o &quot;1-3&quot; \\h \\z \\u "))
        #expect(xml.contains("w:anchor=\"_Toc"))

        // The heading is renamed; building the contents afresh follows it.
        let headingStart = (controller.textView.textStorage.string as NSString).range(of: "Detail", options: .backwards).location
        controller.textView.selectedRange = NSRange(location: headingStart, length: 6)
        controller.textView.insertText("Findings")
        controller.updateTableOfContents()
        #expect(latest?.allParagraphs.prefix(2).map(\.plainText) == ["Introduction\t1", "Findings\t2"])
    }

    @Test("Fields read from a file are worked out afresh, and others are left as they are")
    func fromFile() throws {
        let document = try Fixtures.document()
        let controller = DocumentTextController(document: document, scheme: .light)
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        // The fixture's PAGE field still says 1, which it is: nothing changes.
        controller.updateFields()
        #expect(latest == nil)
        let updated = Fields.update(document.body, environment: FieldEnvironment(pageOfParagraph: { _ in 7 }))
        guard case .paragraph(let paragraph) = updated[1] else { return }
        #expect(paragraph.plainText.hasSuffix("on page 7."))
    }
}
