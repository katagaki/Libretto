import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Pictures")
struct PictureTests {
    private func makeController() -> (DocumentTextController, () -> WordDocument?) {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: String(repeating: "Words flow around the picture beside them. ", count: 12)))]
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, { latest })
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("A picture floats where it is put, cropped and sized, with text going round it")
    func floats() throws {
        let (controller, latest) = makeController()
        controller.textView.selectedRange = NSRange(location: 0, length: 0)
        controller.insertImage(png(width: 200, height: 100))
        controller.textView.selectedRange = NSRange(location: 0, length: 1)
        #expect(controller.selectedImage != nil)
        controller.updateSelectedImage { picture in
            picture.wrap = .square
            picture.alignment = .trailing
            picture.width = 100
            picture.height = 50
            picture.crop.left = 0.2
        }

        let document = try #require(latest())
        guard case .image(let picture)? = document.allParagraphs.first?.inlines.first?.content else {
            Issue.record("the picture went missing")
            return
        }
        #expect(picture.isEdited)
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<wp:anchor "))
        #expect(xml.contains("<wp:positionH relativeFrom=\"margin\"><wp:align>right</wp:align></wp:positionH>"))
        #expect(xml.contains("<wp:wrapSquare wrapText=\"bothSides\"/>"))
        #expect(xml.contains("<a:srcRect l=\"20000\"/>"))
        #expect(xml.contains("<wp:extent cx=\"1270000\" cy=\"635000\"/>"))

        let reread = try DOCXReader.document(fromParts: try Fixtures.written(document))
        guard case .image(let back)? = reread.allParagraphs.first?.inlines.first?.content else { return }
        #expect(back.wrap == .square)
        #expect(back.alignment == .trailing)
        #expect(abs(back.crop.left - 0.2) < 0.001)

        // Set at the right margin, and the first lines stop short of it.
        let layout = controller.layoutManager
        let placed = try #require(layout.placedFloats.first)
        #expect(abs(placed.frame.maxX - controller.geometry.contentWidth) < 1)
        let firstLine = layout.lineFragmentUsedRect(forGlyphAt: 1, effectiveRange: nil)
        #expect(firstLine.maxX <= placed.frame.minX)
    }

    @Test("A picture in line keeps to the line, and goes back in line from floating")
    func backInLine() throws {
        let (controller, latest) = makeController()
        controller.insertImage(png(width: 40, height: 40))
        controller.textView.selectedRange = NSRange(location: controller.textView.selectedRange.location - 1, length: 1)
        controller.updateSelectedImage { $0.wrap = .behindText }
        controller.updateSelectedImage { $0.wrap = .inline }
        let xml = Fixtures.text(try Fixtures.written(try #require(latest())), "word/document.xml")
        #expect(xml.contains("<wp:inline "))
        #expect(controller.layoutManager.placedFloats.isEmpty)
    }
}
