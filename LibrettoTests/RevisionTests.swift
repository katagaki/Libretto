import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Tracked changes")
struct RevisionTests {
    private static let changes = """
        <w:p><w:r><w:t xml:space="preserve">The </w:t></w:r>\
        <w:del w:id="1" w:author="Ada" w:date="2026-01-01T00:00:00Z"><w:r><w:delText>old</w:delText></w:r></w:del>\
        <w:ins w:id="2" w:author="Ada" w:date="2026-01-01T00:00:00Z"><w:r><w:t>new</w:t></w:r></w:ins>\
        <w:r><w:rPr><w:b/><w:rPrChange w:id="3" w:author="Ada"><w:rPr/></w:rPrChange></w:rPr>\
        <w:t xml:space="preserve"> plan</w:t></w:r></w:p>\
        <w:p><w:pPr><w:rPr><w:del w:id="4" w:author="Ada"/></w:rPr></w:pPr><w:r><w:t>Joined</w:t></w:r></w:p>\
        <w:p><w:r><w:t xml:space="preserve"> here.</w:t></w:r></w:p>
        """

    private func document() throws -> WordDocument {
        try DOCXReader.document(fromParts: Fixtures.parts(body: Self.changes))
    }

    private func paragraphs(_ blocks: [Block]) -> [Paragraph] {
        blocks.compactMap { if case .paragraph(let paragraph) = $0 { return paragraph } else { return nil } }
    }

    @Test("Insertions and deletions read as text marked as the change, and write back as they were")
    func reads() throws {
        let document = try document()
        let first = paragraphs(document.body)[0]
        #expect(first.plainText == "The oldnew plan")
        #expect(first.inlines.first { $0.plainText == "old" }?.revision?.kind == .deletion)
        #expect(first.inlines.first { $0.plainText == "new" }?.revision?.author == "Ada")
        #expect(paragraphs(document.body)[1].markRevision?.kind == .deletion)
        #expect(document.unsupportedFeatures.isEmpty)

        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<w:del w:author=\"Ada\" w:date=\"2026-01-01T00:00:00Z\" w:id=\"1\"><w:r><w:delText>old</w:delText></w:r></w:del>"))
    }

    @Test("A paragraph rewritten keeps its changes, deleted text as deleted text")
    func rewrites() throws {
        var document = try document()
        var paragraph = paragraphs(document.body)[0]
        paragraph.inlines[0].content = .text("A ")
        document.body[0] = .paragraph(paragraph)
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<w:del w:author=\"Ada\" w:date=\"2026-01-01T00:00:00Z\" w:id=\"1\"><w:r><w:delText xml:space=\"preserve\">old</w:delText></w:r></w:del>"))
        #expect(xml.contains("<w:ins w:author=\"Ada\" w:date=\"2026-01-01T00:00:00Z\" w:id=\"2\"><w:r><w:t xml:space=\"preserve\">new</w:t></w:r></w:ins>"))
    }

    @Test("Accepting keeps insertions and drops deletions, joining at a deleted mark")
    func acceptsAll() throws {
        let resolved = paragraphs(Revisions.resolve(try document().body, accept: true))
        #expect(resolved.map(\.plainText) == ["The new plan", "Joined here."])
        #expect(resolved.allSatisfy { $0.markRevision == nil && $0.inlines.allSatisfy { $0.revision == nil } })
        // The bold stays, its record of having been made bold goes.
        let plan = try #require(resolved[0].inlines.first { $0.plainText == " plan" })
        #expect(plan.format.style.isBold == true)
        #expect(plan.format.preservedPropertiesXML?.contains("rPrChange") == false)
    }

    @Test("Rejecting drops insertions and keeps deletions, and undoes formatting changes")
    func rejectsAll() throws {
        let resolved = paragraphs(Revisions.resolve(try document().body, accept: false))
        #expect(resolved.map(\.plainText) == ["The old plan", "Joined", " here."])
        let plan = try #require(resolved[0].inlines.first { $0.plainText == " plan" })
        #expect(plan.format.style.isBold == nil)
    }

    private func trackingController(text: String) -> (DocumentTextController, () -> WordDocument?) {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: text))]
        document.trackRevisions = true
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, { latest })
    }

    private func type(_ text: String, into controller: DocumentTextController) {
        let textView = controller.textView
        for character in text {
            let string = String(character)
            if controller.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: string) {
                textView.insertText(string)
            }
        }
    }

    private func backspace(_ controller: DocumentTextController) {
        let textView = controller.textView
        let range = NSRange(location: textView.selectedRange.location - 1, length: 1)
        if controller.textView(textView, shouldChangeTextIn: range, replacementText: "") {
            textView.textStorage.deleteCharacters(in: range)
        }
    }

    @Test("While tracking, typing is an insertion and deleting marks text deleted")
    func records() throws {
        let (controller, latest) = trackingController(text: "Hello world")
        controller.textView.selectedRange = NSRange(location: 11, length: 0)
        type("!!", into: controller)
        backspace(controller)
        // Deleting what this reviewer just typed takes it away for good.
        controller.textView.selectedRange = NSRange(location: 5, length: 0)
        backspace(controller)
        controller.flush()

        let document = try #require(latest())
        let paragraph = paragraphs(document.body)[0]
        #expect(paragraph.plainText == "Hello world!")
        #expect(paragraph.inlines.map(\.plainText) == ["Hell", "o", " world", "!"])
        #expect(paragraph.inlines[1].revision?.kind == .deletion)
        #expect(paragraph.inlines[3].revision?.kind == .insertion)
        #expect(paragraph.inlines[3].revision?.author == Reviewer.name)
        #expect(controller.textView.selectedRange.location == 4)

        let parts = try Fixtures.written(document)
        let xml = Fixtures.text(parts, "word/document.xml")
        #expect(xml.contains("<w:del w:id=\"900001\" w:author=\"\(Reviewer.name)\""))
        #expect(xml.contains("<w:delText xml:space=\"preserve\">o</w:delText>"))
        #expect(xml.contains("<w:ins w:id=\"900002\""))
        #expect(Fixtures.text(parts, "word/settings.xml").contains("<w:trackRevisions/>"))
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.trackRevisions)
        #expect(paragraphs(reread.body)[0].inlines[1].revision?.kind == .deletion)
    }

    @Test("A new paragraph while tracking is an inserted mark")
    func recordsMarks() throws {
        let (controller, latest) = trackingController(text: "One")
        controller.textView.selectedRange = NSRange(location: 3, length: 0)
        type("\nTwo", into: controller)
        controller.flush()

        let document = try #require(latest())
        let all = paragraphs(document.body)
        #expect(all.map(\.plainText) == ["One", "Two"])
        #expect(all[0].markRevision?.kind == .insertion)
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<w:pPr><w:rPr><w:ins w:author=\"\(Reviewer.name)\""))

        // Rejecting everything takes the new paragraph back out.
        controller.resolveAllChanges(accept: false)
        #expect(paragraphs(try #require(latest()).body).map(\.plainText) == ["One"])
    }

    @Test("Accepting the change at the caret settles just that change")
    func acceptsOne() throws {
        let (controller, latest) = trackingController(text: "Keep this")
        controller.textView.selectedRange = NSRange(location: 4, length: 5)
        type("X", into: controller)
        // On the deleted " this".
        controller.textView.selectedRange = NSRange(location: 6, length: 0)
        controller.resolveChange(accept: true)
        let paragraph = paragraphs(try #require(latest()).body)[0]
        #expect(paragraph.plainText == "KeepX")
        #expect(paragraph.inlines.last?.revision?.kind == .insertion)
    }
}
