import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Navigation and bookmarks")
struct NavigationTests {
    private func makeController(_ document: WordDocument) -> (DocumentTextController, () -> WordDocument?) {
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, { latest })
    }

    @Test("Headings are found by their style, and the reader is taken to them")
    func headings() throws {
        let (controller, _) = makeController(try Fixtures.document())
        let headings = controller.headings
        #expect(headings.map(\.text) == ["Annual Report"])
        #expect(headings.first?.level == 1)
        controller.goTo(headings[0].location)
        #expect(controller.textView.selectedRange.location == 0)
    }

    @Test("A bookmark marks the selection, is written by name, and can be taken away")
    func bookmarks() throws {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: "See the summary below."))]
        let (controller, latest) = makeController(document)
        controller.textView.selectedRange = NSRange(location: 8, length: 7)
        let name = controller.addBookmark("the summary")
        #expect(name == "the_summary")
        #expect(controller.bookmarkRanges[name] == NSRange(location: 8, length: 7))

        let saved = try #require(latest())
        let xml = Fixtures.text(try Fixtures.written(saved), "word/document.xml")
        #expect(xml.contains("<w:bookmarkStart w:id=\"0\" w:name=\"the_summary\"/><w:r><w:t xml:space=\"preserve\">summary</w:t></w:r><w:bookmarkEnd w:id=\"0\"/>"))
        #expect(BookmarkAnchors.names(in: try DOCXReader.document(fromParts: try Fixtures.written(saved)).body) == [name])

        // The fixture's own bookmark is found too, read from the file.
        let (fixture, _) = makeController(try Fixtures.document())
        #expect(fixture.bookmarkRanges["summary"] != nil)

        controller.deleteBookmark(name)
        #expect(controller.bookmarkRanges.isEmpty)
        guard case .paragraph(let paragraph)? = latest()?.body.first else { return }
        #expect(paragraph.inlines.allSatisfy { BookmarkAnchors.marker($0) == nil })
    }
}
