import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Equations")
struct EquationTests {
    @Test("A line of math reads into Office Math, and back")
    func linear() throws {
        let omml = LinearMath.omml("x^2 + y_1 = sqrt(a/b)")
        #expect(omml == "<m:oMath><m:sSup><m:e><m:r><m:t>x</m:t></m:r></m:e><m:sup><m:r><m:t>2</m:t></m:r></m:sup></m:sSup>"
            + "<m:r><m:t>+</m:t></m:r><m:sSub><m:e><m:r><m:t>y</m:t></m:r></m:e><m:sub><m:r><m:t>1</m:t></m:r></m:sub></m:sSub>"
            + "<m:r><m:t>=</m:t></m:r><m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e><m:f><m:num><m:r><m:t>a</m:t></m:r></m:num>"
            + "<m:den><m:r><m:t>b</m:t></m:r></m:den></m:f></m:e></m:rad></m:oMath>")
        #expect(LinearMath.linear(fromXML: omml) == "x^2+y_1=sqrt(a/b)")
        #expect(LinearMath.omml("sum_(i=1)^n i").contains("<m:chr m:val=\"∑\"/>"))
        #expect(LinearMath.omml("\\alpha").contains("<m:t>α</m:t>"))
        #expect(MathRenderer.image(forXML: omml, fontSize: 12, color: .black).map { $0.image.size.width > 30 } == true)
    }

    @Test("An equation goes in as a drawing in its line, and is written as Office Math")
    func inserts() throws {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: "Area: "))]
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        controller.textView.selectedRange = NSRange(location: 6, length: 0)
        controller.insertEquation("\\pi r^2")
        #expect(controller.textView.textStorage.attribute(.attachment, at: 6, effectiveRange: nil) != nil)
        controller.textView.selectedRange = NSRange(location: 7, length: 0)
        #expect(state.isOnEquation)

        let saved = try #require(latest)
        let xml = Fixtures.text(try Fixtures.written(saved), "word/document.xml")
        #expect(xml.contains("xmlns:m=\"\(MathRenderer.namespace)\""))
        #expect(xml.contains("<m:oMath><m:r><m:t>π</m:t></m:r><m:sSup>"))
        let reread = try DOCXReader.document(fromParts: try Fixtures.written(saved))
        #expect(reread.unsupportedFeatures.isEmpty)
        guard case .paragraphChild(let kept, _)? = reread.allParagraphs.first?.inlines.last?.content else {
            Issue.record("the equation went missing")
            return
        }
        #expect(MathRenderer.isEquation(kept))

        // Edited in place.
        controller.insertEquation("\\pi r^3")
        #expect(Fixtures.text(try Fixtures.written(try #require(latest)), "word/document.xml").contains("<m:t>3</m:t>"))
    }
}
