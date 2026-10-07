import Foundation
import Testing
@testable import Libretto

@Suite("Headers and footers")
struct HeaderFooterTests {
    @Test("An edited header is written over its part, its page number a field")
    func editsHeader() throws {
        var document = try Fixtures.document()
        let id = try #require(document.pageSetup.headerFooters.headers[.default])
        document.headerFooters[id]?.text = "Draft\tPage {PAGE} of {NUMPAGES}"
        document.headerFooters[id]?.alignment = .center
        document.headerFooters[id]?.isEdited = true

        let parts = try Fixtures.written(document)
        let header = Fixtures.text(parts, "word/header1.xml")
        #expect(header.contains("<w:jc w:val=\"center\"/>"))
        #expect(header.contains("<w:fldSimple w:instr=\" PAGE \">"))
        #expect(header.contains("<w:fldSimple w:instr=\" NUMPAGES \">"))
        #expect(header.contains("<w:tab/>"))
        #expect(!header.contains(">7<"))
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.header?.resolved(page: 2, of: 5) == "Draft\tPage 2 of 5")
        #expect(reread.header?.alignment == .center)
    }

    @Test("A first-page footer gets a part, a relationship and a reference of its own")
    func addsFirstPageFooter() throws {
        var document = try Fixtures.document()
        let id = document.unusedHeaderFooterID(isFooter: true)
        document.headerFooters[id] = HeaderFooterText(text: "Confidential", isFooter: true, isEdited: true)
        document.pageSetup.headerFooters.footers[.first] = id
        document.pageSetup.headerFooters.titlePage = true

        let parts = try Fixtures.written(document)
        #expect(Fixtures.text(parts, "word/footer1.xml").contains("<w:ftr"))
        #expect(Fixtures.text(parts, "word/_rels/document.xml.rels").contains("Target=\"footer1.xml\""))
        #expect(Fixtures.text(parts, "[Content_Types].xml").contains("/word/footer1.xml"))
        let xml = Fixtures.text(parts, "word/document.xml")
        #expect(xml.contains("<w:footerReference r:id=\"\(id)\" w:type=\"first\"/>"))
        #expect(xml.contains("<w:titlePg/>"))
        // The header the section had is still referred to.
        #expect(xml.contains("<w:headerReference r:id=\"rIdHeader\" w:type=\"default\"/>"))

        let reread = try DOCXReader.document(fromParts: parts)
        let texts = WordDocumentHeaderFooter(document: reread)
        #expect(texts.footer(forPage: 0)?.text == "Confidential")
        #expect(texts.footer(forPage: 1) == nil)
        // The first page has its own header, which it has not been given.
        #expect(texts.header(forPage: 0) == nil)
        #expect(texts.header(forPage: 1)?.resolved(page: 2, of: 2) == "Page 2")
    }

    @Test("Odd and even headers are a setting of the whole document")
    func evenAndOdd() throws {
        var document = try Fixtures.document()
        document.evenAndOddHeaders = true
        let parts = try Fixtures.written(document)
        #expect(Fixtures.text(parts, "word/settings.xml").contains("<w:evenAndOddHeaders/>"))
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.evenAndOddHeaders)
        // Even pages have no header of their own yet.
        #expect(WordDocumentHeaderFooter(document: reread).header(forPage: 1) == nil)
        #expect(WordDocumentHeaderFooter(document: reread).header(forPage: 2) != nil)
    }
}
