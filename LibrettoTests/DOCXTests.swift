import Foundation
import Testing
@testable import Libretto

@Suite("Reading DOCX")
struct DOCXReadingTests {
    @Test("Paragraphs, tables and the page come through")
    func structure() throws {
        let document = try Fixtures.document()
        #expect(document.body.count == 8)
        guard case .paragraph(let heading) = document.body[0],
              case .table(let table) = document.body[4] else {
            Issue.record("unexpected block kinds")
            return
        }
        #expect(heading.plainText == "Annual Report")
        #expect(heading.properties.styleID == "Heading1")
        #expect(document.styles.headingLevel(ofStyle: "Heading1") == 1)
        #expect(table.rows.count == 2)
        #expect(table.columnCount == 2)
        #expect(table.hasBorders)
        #expect(table.rows[0].cells[1].shadingHex == "DDEEFF")
        #expect(document.pageSetup.width == 12240)
        #expect(document.pageSetup.marginLeft == 1080)
    }

    @Test("Runs keep their formatting, and links their address")
    func runs() throws {
        let document = try Fixtures.document()
        guard case .paragraph(let paragraph) = document.body[1] else { return }
        #expect(paragraph.plainText == "Revenue was strong this year; see the site on page 1.")
        let bold = paragraph.inlines.first { $0.plainText == "strong" }
        #expect(bold?.format.style.isBold == true)
        let link = paragraph.inlines.first { $0.hyperlink != nil }
        #expect(link?.hyperlink?.url == URL(string: "https://example.com/"))
        #expect(paragraph.properties.alignment == .justified)
        // The bookmark and the field's parts are kept, taking no room.
        #expect(paragraph.inlines.filter(\.content.isMarker).count == 6)
    }

    @Test("Headers resolve page number fields per page")
    func header() throws {
        let document = try Fixtures.document()
        #expect(document.header?.alignment == .trailing)
        #expect(document.header?.resolved(page: 3, of: 9) == "Page 3")
    }

    @Test("Lists are numbered as Word numbers them")
    func listLabels() throws {
        let document = try Fixtures.document()
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        var labeler = ListLabeler(context: context)
        let labels = document.body.compactMap { block -> String? in
            guard case .paragraph(let paragraph) = block else { return nil }
            return labeler.label(for: paragraph.properties)?.text
        }
        #expect(labels == ["1.", "2."])
        #expect(ListLabeler.format(4, as: "lowerRoman") == "iv")
        #expect(ListLabeler.format(28, as: "upperLetter") == "BB")
        #expect(ListLabeler.bullet("\u{F0B7}") == "\u{2022}")
    }

    @Test("Macros are noticed, and never anything more")
    func macros() throws {
        let document = try Fixtures.document(macroEnabled: true)
        #expect(document.hasMacros)
        #expect(document.unsupportedFeatures.features.contains(.macros))
    }
}

@Suite("Writing DOCX")
struct DOCXWritingTests {
    @Test("Untouched content is written back exactly as it was read")
    func verbatim() throws {
        let document = try Fixtures.document()
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("w14:paraId=\"1A2B3C4D\""))
        #expect(xml.contains("<w:bookmarkStart w:id=\"0\" w:name=\"summary\"/>"))
        #expect(xml.contains("<w:instrText xml:space=\"preserve\"> PAGE </w:instrText>"))
        #expect(xml.contains("w:fill=\"DDEEFF\""))
        #expect(xml.contains("<w:headerReference r:id=\"rIdHeader\" w:type=\"default\"/>"))
        #expect(xml.contains("mc:Ignorable=\"w14\""))
    }

    @Test("Every written part is well-formed, and reads back the same")
    func wellFormed() throws {
        let original = try Fixtures.document()
        let parts = try Fixtures.written(original)
        for (path, data) in parts where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            #expect(throws: Never.self, "\(path) is not well-formed") { _ = try XMLLite.parse(data) }
        }
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.body.map(\.paragraphs).map { $0.map(\.plainText) }
                == original.body.map(\.paragraphs).map { $0.map(\.plainText) })
        #expect(reread.pageSetup.values == original.pageSetup.values)
    }

    @Test("Changing a run patches its properties, keeping the rest")
    func patchesRuns() throws {
        var document = try Fixtures.document()
        guard case .paragraph(var paragraph) = document.body[1] else { return }
        let index = try #require(paragraph.inlines.firstIndex { $0.plainText == "Revenue was " })
        paragraph.inlines[index].format.style.isItalic = true
        paragraph.inlines[index].format.style.colorHex = "FF0000"
        document.body[1] = .paragraph(paragraph)

        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        // In schema order: italics before colour before language.
        #expect(xml.contains("<w:rPr><w:i/><w:iCs/><w:color w:val=\"FF0000\"/><w:lang w:val=\"en-GB\"/></w:rPr>"))
        // The paragraph's own properties were not touched, so stay as they were.
        #expect(xml.contains("<w:pPr><w:spacing w:after=\"120\"/><w:jc w:val=\"both\"/></w:pPr>"))
        #expect(xml.contains("w14:paraId=\"1A2B3C4D\""))
    }

    @Test("Changing a paragraph patches its properties in schema order")
    func patchesParagraphs() throws {
        var document = try Fixtures.document()
        guard case .paragraph(var paragraph) = document.body[1] else { return }
        paragraph.properties.alignment = .center
        paragraph.properties.styleID = "Heading1"
        paragraph.properties.indentFirstLine = -360
        document.body[1] = .paragraph(paragraph)

        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("""
            <w:pPr><w:pStyle w:val="Heading1"/><w:spacing w:after="120"/><w:ind w:hanging="360"/>\
            <w:jc w:val="center"/></w:pPr>
            """))
    }

    @Test("Page setup changes keep the section's header")
    func pageSetup() throws {
        var document = try Fixtures.document()
        document.pageSetup.width = 16838
        document.pageSetup.height = 11906
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("w:orient=\"landscape\""))
        #expect(xml.contains("<w:headerReference r:id=\"rIdHeader\" w:type=\"default\"/><w:pgSz"))
    }

    @Test("A list in a document without numbering adds the numbering part")
    func addsNumbering() throws {
        var document = try Fixtures.document(includeNumbering: false)
        let id = document.numbering.numberingID(for: .bulleted)
        guard case .paragraph(var paragraph) = document.body[7] else { return }
        paragraph.properties.list = ListReference(numberingID: id, level: 0)
        document.body[7] = .paragraph(paragraph)

        let parts = try Fixtures.written(document)
        let numbering = Fixtures.text(parts, "word/numbering.xml")
        #expect(numbering.contains("<w:numFmt w:val=\"bullet\"/>"))
        #expect(numbering.contains("<w:num w:numId=\"\(id)\">"))
        #expect(Fixtures.text(parts, "word/_rels/document.xml.rels").contains("Target=\"numbering.xml\""))
        #expect(Fixtures.text(parts, "[Content_Types].xml").contains("/word/numbering.xml"))
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.numbering.kind(of: id) == .bulleted)
    }

    @Test("A style the document lacks is added to its styles part")
    func addsStyles() throws {
        var document = try Fixtures.document()
        let id = document.styles.ensureStyle(.quote)
        #expect(id == "Quote")
        let styles = Fixtures.text(try Fixtures.written(document), "word/styles.xml")
        #expect(styles.contains("w:styleId=\"Quote\""))
        #expect(styles.contains("<w:name w:val=\"Quote\"/>"))
    }

    @Test("Inserted pictures are written as parts with relationships")
    func addsPictures() throws {
        var document = WordDocument()
        let id = document.package.unusedRelationshipID()
        document.package.addedMedia[id] = DocumentPackage.AddedMedia(
            path: "word/media/picture.png", data: Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png",
            contentType: "image/png"
        )
        document.body = [.paragraph(Paragraph(inlines: [
            Inline(.image(InlineImage(relationshipID: id, width: 100, height: 50))),
        ]))]
        let parts = try Fixtures.written(document)
        #expect(parts["word/media/picture.png"] != nil)
        #expect(Fixtures.text(parts, "word/_rels/document.xml.rels").contains("Id=\"\(id)\""))
        #expect(Fixtures.text(parts, "word/document.xml").contains("r:embed=\"\(id)\""))
        #expect(Fixtures.text(parts, "word/document.xml").contains("cx=\"1270000\""))
    }

    @Test("Saving as .docx takes the macros out")
    func removesMacros() throws {
        let document = try Fixtures.document(macroEnabled: true).withoutMacros
        let parts = try Fixtures.written(document)
        #expect(parts["word/vbaProject.bin"] == nil)
        #expect(!Fixtures.text(parts, "[Content_Types].xml").contains("macroEnabled"))
        #expect(!Fixtures.text(parts, "word/_rels/document.xml.rels").contains("vbaProject"))
        #expect(!document.hasMacros)
    }

    @Test("A new document is a valid package")
    func blank() throws {
        let document = WordDocument()
        let parts = try Fixtures.written(document)
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.body.count == 1)
        #expect(reread.styles.styleID(for: .heading2) == "Heading2")
        #expect(reread.unsupportedFeatures.isEmpty)
    }
}

@Suite("Fields")
struct FieldTests {
    private func field(_ type: String) -> Inline {
        Inline(.runChild(xml: "<w:fldChar w:fldCharType=\"\(type)\"/>", display: nil))
    }

    @Test("A field missing its beginning loses the rest of itself")
    func dropsOrphans() {
        let body: [Block] = [.paragraph(Paragraph(inlines: [
            field("separate"), Inline(.text("1")), field("end"),
            field("begin"), Inline(.runChild(xml: "<w:instrText>PAGE</w:instrText>", display: nil)),
            field("separate"), Inline(.text("2")), field("end"),
        ]))]
        let balanced = FieldBalancer.balanced(body)
        guard case .paragraph(let paragraph) = balanced[0] else { return }
        #expect(paragraph.inlines.count == 6)
        #expect(paragraph.plainText == "12")
    }
}
