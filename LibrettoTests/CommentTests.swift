import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Comments")
struct CommentTests {
    private func makeController(text: String) -> (DocumentTextController, () -> WordDocument?) {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: text))]
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, { latest })
    }

    private func written(_ document: WordDocument) throws -> [String: Data] {
        try ZipArchive.entries(in: DOCXWriter.data(from: document))
    }

    @Test("A comment on a selection is bounded by markers and written to a comments part")
    func adds() throws {
        let (controller, latest) = makeController(text: "The budget is final.")
        controller.textView.selectedRange = NSRange(location: 4, length: 6)
        controller.addComment("Which year?")
        #expect(controller.commentRanges["0"] == NSRange(location: 4, length: 6))
        #expect(controller.commentQuote("0") == "budget")

        let document = try #require(latest())
        #expect(document.comments.map(\.text) == ["Which year?"])
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        #expect(paragraph.plainText == "The budget is final.")
        let markers = paragraph.inlines.compactMap { CommentAnchors.marker($0)?.kind }
        #expect(markers == ["commentRangeStart", "commentRangeEnd", "commentReference"])

        let parts = try written(document)
        let comments = String(decoding: try #require(parts["word/comments.xml"]), as: UTF8.self)
        #expect(comments.contains("<w:t xml:space=\"preserve\">Which year?</w:t>"))
        #expect(comments.contains("<w:annotationRef/>"))
        let rels = String(decoding: try #require(parts["word/_rels/document.xml.rels"]), as: UTF8.self)
        #expect(rels.contains("Target=\"comments.xml\""))
        let xml = String(decoding: try #require(parts["word/document.xml"]), as: UTF8.self)
        #expect(xml.contains("<w:commentRangeStart w:id=\"0\"/><w:r><w:t xml:space=\"preserve\">budget</w:t></w:r><w:commentRangeEnd w:id=\"0\"/>"))

        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.comments.first?.text == "Which year?")
        #expect(reread.comments.first?.author == Reviewer.name)
        #expect(reread.unsupportedFeatures.isEmpty)
    }

    @Test("Replies and resolving are written to Word's comment extensions")
    func threads() throws {
        let (controller, latest) = makeController(text: "Ship it on Friday.")
        controller.textView.selectedRange = NSRange(location: 11, length: 6)
        controller.addComment("Too soon?")
        controller.reply(to: "0", text: "It's fine.")
        controller.setCommentDone("0", true)

        let document = try #require(latest())
        #expect(document.comments.count == 2)
        #expect(document.comments.allSatisfy { $0.isDone })
        #expect(document.comments[1].parentParaID == document.comments[0].paraID)
        #expect(controller.commentRanges["1"] == controller.commentRanges["0"])

        let parts = try written(document)
        let extended = String(decoding: try #require(parts["word/commentsExtended.xml"]), as: UTF8.self)
        #expect(extended.contains("w15:done=\"1\""))
        #expect(extended.contains("w15:paraIdParent=\"\(document.comments[0].paraID!)\""))
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.comments.map(\.isDone) == [true, true])
        #expect(reread.comments[1].parentParaID == reread.comments[0].paraID)
    }

    @Test("Deleting a comment takes its replies and markers with it")
    func deletes() throws {
        let (controller, latest) = makeController(text: "Keep this text.")
        controller.textView.selectedRange = NSRange(location: 5, length: 4)
        controller.addComment("Why?")
        controller.reply(to: "0", text: "Because.")
        controller.deleteComment("0")

        let document = try #require(latest())
        #expect(document.comments.isEmpty)
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        #expect(paragraph.inlines.allSatisfy { CommentAnchors.marker($0) == nil })
        #expect(paragraph.plainText == "Keep this text.")
        #expect(controller.commentRanges.isEmpty)
    }

    @Test("Comments in a file are read with their ranges")
    func reads() throws {
        var parts = Fixtures.parts(body: """
            <w:p><w:r><w:t xml:space="preserve">See </w:t></w:r><w:commentRangeStart w:id="7"/>\
            <w:r><w:t>here</w:t></w:r><w:commentRangeEnd w:id="7"/>\
            <w:r><w:commentReference w:id="7"/></w:r></w:p>
            """)
        parts["word/comments.xml"] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:comments xmlns:w="\(Fixtures.w)" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml">\
            <w:comment w:id="7" w:author="Ada" w:date="2026-01-02T03:04:05Z"><w:p w14:paraId="0ABCDEF1">\
            <w:r><w:annotationRef/></w:r><w:r><w:t>Look</w:t></w:r></w:p></w:comment></w:comments>
            """.utf8)
        var rels = String(decoding: parts["word/_rels/document.xml.rels"]!, as: UTF8.self)
        rels = rels.replacingOccurrences(of: "</Relationships>", with: """
            <Relationship Id="rIdComments" Type="\(OOXML.commentsType)" Target="comments.xml"/></Relationships>
            """)
        parts["word/_rels/document.xml.rels"] = Data(rels.utf8)
        let document = try DOCXReader.document(fromParts: parts)
        #expect(document.comments.first?.author == "Ada")
        #expect(document.comments.first?.paraID == "0ABCDEF1")
        #expect(document.comments.first?.dateValue != nil)

        let controller = DocumentTextController(document: document, scheme: .light)
        #expect(controller.commentRanges["7"] == NSRange(location: 4, length: 4))
        // Untouched, the comments part is written back as it was.
        let saved = try written(document)
        #expect(saved["word/comments.xml"] == parts["word/comments.xml"])
    }
}
