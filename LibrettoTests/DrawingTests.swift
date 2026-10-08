import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Shapes, charts and diagrams")
struct DrawingTests {
    private static let wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"

    /// The fixture package with a body of its own, extra parts, and relationships to them.
    private func parts(body: String, extra: [String: String], relationships: String) -> [String: Data] {
        var parts = Fixtures.parts(body: body)
        for (path, xml) in extra { parts[path] = Data(xml.utf8) }
        var rels = String(decoding: parts["word/_rels/document.xml.rels"]!, as: UTF8.self)
        rels = rels.replacingOccurrences(of: "</Relationships>", with: relationships + "</Relationships>")
        parts["word/_rels/document.xml.rels"] = Data(rels.utf8)
        // The drawing prefixes the body uses.
        var document = String(decoding: parts["word/document.xml"]!, as: UTF8.self)
        let declarations = [
            "xmlns:wp=\"\(OOXML.drawingNamespace)\"", "xmlns:a=\"\(OOXML.drawingMainNamespace)\"",
            "xmlns:wps=\"\(Self.wps)\"", "xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"",
            "xmlns:dgm=\"http://schemas.openxmlformats.org/drawingml/2006/diagram\"",
            "xmlns:mc2=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"",
        ].joined(separator: " ")
        document = document.replacingOccurrences(of: "<w:document ", with: "<w:document \(declarations) ")
        parts["word/document.xml"] = Data(document.utf8)
        return parts
    }

    private func drawing(_ graphic: String) -> String {
        """
        <w:p><w:r><w:drawing><wp:inline><wp:extent cx="1905000" cy="1270000"/><wp:docPr id="7" name="Thing"/>\
        \(graphic)</wp:inline></w:drawing></w:r></w:p>
        """
    }

    private func object(_ document: WordDocument) -> (InlineImage, DrawingObject)? {
        for inline in document.allParagraphs.flatMap(\.inlines) {
            if case .image(let image) = inline.content, let object = image.object { return (image, object) }
        }
        return nil
    }

    @Test("A text box goes in floating, its text is written into it, and it reads back")
    func textBox() throws {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: "Around the box"))]
        let controller = DocumentTextController(document: document, scheme: .light)
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        controller.textView.selectedRange = NSRange(location: 0, length: 0)
        controller.insertShape("rect", isTextBox: true)
        controller.updateSelectedShape { $0.text = "Note\nwell" }

        let written = try Fixtures.written(try #require(latest))
        let xml = Fixtures.text(written, "word/document.xml")
        #expect(xml.contains("<wps:cNvSpPr txBox=\"1\"/>"))
        #expect(xml.contains("<w:txbxContent><w:p><w:r><w:t xml:space=\"preserve\">Note</w:t></w:r></w:p><w:p><w:r><w:t xml:space=\"preserve\">well</w:t></w:r></w:p></w:txbxContent>"))
        #expect(xml.contains("xmlns:wps=\"\(Self.wps)\""))
        let (image, object) = try #require(object(try DOCXReader.document(fromParts: written)))
        #expect(object == .shape(ShapeSpec(geometry: "rect", fillHex: "FFFFFF", lineHex: "000000", lineWidth: 0.75,
                                           text: "Note\nwell", isTextBox: true, originalText: "Note\nwell")))
        #expect(image.wrap == .square)
        #expect(controller.layoutManager.placedFloats.count == 1)
    }

    @Test("A shape Word wrote with a fallback is drawn, kept whole, and its text can change")
    func shapeWithFallback() throws {
        let body = """
            <w:p><w:r><mc2:AlternateContent><mc2:Choice Requires="wps"><w:drawing><wp:anchor behindDoc="0">\
            <wp:positionH relativeFrom="margin"><wp:align>center</wp:align></wp:positionH>\
            <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>\
            <wp:extent cx="1270000" cy="635000"/><wp:wrapTopAndBottom/><wp:docPr id="3" name="Oval 3"/>\
            <a:graphic><a:graphicData uri="\(Self.wps)"><wps:wsp><wps:spPr><a:prstGeom prst="ellipse"/>\
            <a:solidFill><a:schemeClr val="accent2"/></a:solidFill></wps:spPr><wps:txbx><w:txbxContent><w:p><w:r>\
            <w:t>Hi</w:t></w:r></w:p></w:txbxContent></wps:txbx><wps:bodyPr/></wps:wsp></a:graphicData></a:graphic>\
            </wp:anchor></w:drawing></mc2:Choice><mc2:Fallback><w:pict/></mc2:Fallback></mc2:AlternateContent></w:r></w:p>
            """
        let document = try DOCXReader.document(fromParts: parts(body: body, extra: [:], relationships: ""))
        let (image, object) = try #require(object(document))
        guard case .shape(let shape) = object else { Issue.record("not a shape"); return }
        #expect(shape.geometry == "ellipse")
        #expect(shape.fillHex == "ED7D31")
        #expect(shape.text == "Hi")
        #expect(image.wrap == .topAndBottom)
        #expect(image.alignment == .center)
        #expect(!document.unsupportedFeatures.features.contains(.shapes))
        #expect(Fixtures.text(try Fixtures.written(document), "word/document.xml").contains("<mc2:Fallback><w:pict/></mc2:Fallback>"))

        var edited = document
        guard case .paragraph(var paragraph) = edited.body[0], case .image(var picture) = paragraph.inlines[0].content else { return }
        var changed = shape
        changed.text = "Hello"
        picture.object = .shape(changed)
        picture.isEdited = true
        paragraph.inlines[0].content = .image(picture)
        edited.body[0] = .paragraph(paragraph)
        let xml = Fixtures.text(try Fixtures.written(edited), "word/document.xml")
        #expect(xml.contains("<w:t xml:space=\"preserve\">Hello</w:t>"))
        #expect(xml.contains("<a:schemeClr val=\"accent2\"/>"))
    }

    @Test("A chart is read from its part's cached values and drawn")
    func chart() throws {
        let chartXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:title><c:tx><c:rich><a:p><a:r>\
            <a:t>Sales</a:t></a:r></a:p></c:rich></c:tx></c:title><c:plotArea><c:barChart><c:barDir val="col"/>\
            <c:grouping val="clustered"/><c:ser><c:tx><c:strRef><c:strCache><c:pt idx="0"><c:v>2025</c:v></c:pt></c:strCache>\
            </c:strRef></c:tx><c:cat><c:strRef><c:strCache><c:ptCount val="3"/><c:pt idx="0"><c:v>North</c:v></c:pt>\
            <c:pt idx="1"><c:v>South</c:v></c:pt><c:pt idx="2"><c:v>West</c:v></c:pt></c:strCache></c:strRef></c:cat>\
            <c:val><c:numRef><c:numCache><c:ptCount val="3"/><c:pt idx="0"><c:v>4</c:v></c:pt><c:pt idx="1"><c:v>7.5</c:v></c:pt>\
            <c:pt idx="2"><c:v>2</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:barChart></c:plotArea></c:chart></c:chartSpace>
            """
        let body = drawing("""
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">\
            <c:chart r:id="rIdChart"/></a:graphicData></a:graphic>
            """)
        let document = try DOCXReader.document(fromParts: parts(
            body: body, extra: ["word/charts/chart1.xml": chartXML],
            relationships: "<Relationship Id=\"rIdChart\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart\" Target=\"charts/chart1.xml\"/>"
        ))
        let (image, object) = try #require(object(document))
        #expect(object == .chart(ChartSpec(kind: .column, title: "Sales", categories: ["North", "South", "West"],
                                           series: [ChartSpec.Series(name: "2025", values: [4, 7.5, 2])])))
        let drawn = try #require(ImageStore().image(for: image, in: document.package))
        #expect(drawn.size == CGSize(width: 150, height: 100))
    }

    @Test("A SmartArt diagram is drawn from the shapes Word last laid it out as")
    func diagram() throws {
        let data = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <dgm:dataModel xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" \
            xmlns:dsp="http://schemas.microsoft.com/office/drawing/2008/diagram" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dgm:ptLst/><dgm:extLst><a:ext>\
            <dsp:dataModelExt relId="rIdDrawing"/></a:ext></dgm:extLst></dgm:dataModel>
            """
        let shapes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <dsp:drawing xmlns:dsp="http://schemas.microsoft.com/office/drawing/2008/diagram" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dsp:spTree>\
            <dsp:sp><dsp:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="635000" cy="635000"/></a:xfrm><a:prstGeom prst="roundRect"/>\
            <a:solidFill><a:srgbClr val="4472C4"/></a:solidFill></dsp:spPr><dsp:txBody><a:p><a:r><a:rPr sz="1800"/><a:t>Plan</a:t></a:r></a:p></dsp:txBody></dsp:sp>\
            <dsp:sp><dsp:spPr><a:xfrm><a:off x="1270000" y="0"/><a:ext cx="635000" cy="635000"/></a:xfrm><a:prstGeom prst="roundRect"/></dsp:spPr>\
            <dsp:txBody><a:p><a:r><a:t>Do</a:t></a:r></a:p></dsp:txBody></dsp:sp></dsp:spTree></dsp:drawing>
            """
        let body = drawing("""
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram">\
            <dgm:relIds r:dm="rIdData" r:lo="rIdLayout" r:qs="rIdStyle" r:cs="rIdColors"/></a:graphicData></a:graphic>
            """)
        let document = try DOCXReader.document(fromParts: parts(
            body: body, extra: ["word/diagrams/data1.xml": data, "word/diagrams/drawing1.xml": shapes],
            relationships: """
                <Relationship Id="rIdData" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/diagramData" Target="diagrams/data1.xml"/>\
                <Relationship Id="rIdDrawing" Type="\(DrawingObjectReader.diagramDrawingType)" Target="diagrams/drawing1.xml"/>
                """
        ))
        guard case .diagram(let parts)? = object(document)?.1 else { Issue.record("no diagram"); return }
        #expect(parts.map(\.text) == ["Plan", "Do"])
        #expect(parts[1].frame == ShapeFrame(x: 100, y: 0, width: 50, height: 50))
        #expect(parts[0].fontSize == 18)
    }
}
