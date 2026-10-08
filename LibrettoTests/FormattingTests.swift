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
