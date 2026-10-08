import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Footnotes and endnotes")
struct NoteTests {
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

    @Test("Notes in a file are read, numbered in the order the text refers to them")
    func reads() throws {
        var parts = Fixtures.parts(body: """
            <w:p><w:r><w:t>First</w:t></w:r><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr>\
            <w:footnoteReference w:id="5"/></w:r><w:r><w:t xml:space="preserve"> and second</w:t></w:r>\
            <w:r><w:footnoteReference w:id="2"/></w:r></w:p>
            """)
        parts["word/footnotes.xml"] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:footnotes xmlns:w="\(Fixtures.w)"><w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p>\
            </w:footnote><w:footnote w:id="2"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> Two.</w:t></w:r>\
            </w:p></w:footnote><w:footnote w:id="5"><w:p><w:r><w:footnoteRef/></w:r>\
            <w:r><w:t xml:space="preserve"> Five.</w:t></w:r></w:p></w:footnote></w:footnotes>
            """.utf8)
        var rels = String(decoding: parts["word/_rels/document.xml.rels"]!, as: UTF8.self)
        rels = rels.replacingOccurrences(of: "</Relationships>", with: """
            <Relationship Id="rIdNotes" Type="\(OOXML.notesType(.footnote))" Target="footnotes.xml"/></Relationships>
            """)
        parts["word/_rels/document.xml.rels"] = Data(rels.utf8)

        let document = try DOCXReader.document(fromParts: parts)
        #expect(document.notes.map(\.text) == ["Two.", "Five."])
        let numbers = NoteNumbering.numbers(in: document)
        #expect(numbers["footnote:5"] == "1")
        #expect(numbers["footnote:2"] == "2")
        #expect(document.unsupportedFeatures.isEmpty)

        let controller = DocumentTextController(document: document, scheme: .light)
        #expect(controller.textView.text == "First1 and second2")
        // Untouched, the part is written back as it was.
        let saved = try ZipArchive.entries(in: DOCXWriter.data(from: document))
        #expect(saved["word/footnotes.xml"] == parts["word/footnotes.xml"])
    }

    @Test("A footnote inserted in a new document makes its part, separators and all")
    func inserts() throws {
        let (controller, latest) = makeController(text: "Claim. Another.")
        controller.textView.selectedRange = NSRange(location: 15, length: 0)
        let second = controller.insertNote(.footnote)
        controller.textView.selectedRange = NSRange(location: 6, length: 0)
        let first = controller.insertNote(.footnote)
        #expect(controller.textView.text == "Claim.1 Another.2")

        var document = try #require(latest())
        let numbers = NoteNumbering.numbers(in: document)
        #expect(numbers[first] == "1")
        #expect(numbers[second] == "2")
        let index = try #require(document.notes.firstIndex { $0.key == first })
        document.notes[index].text = "See the appendix."

        let parts = try ZipArchive.entries(in: DOCXWriter.data(from: document))
        let notes = String(decoding: try #require(parts["word/footnotes.xml"]), as: UTF8.self)
        #expect(notes.contains("w:type=\"separator\""))
        #expect(notes.contains("<w:t xml:space=\"preserve\"> See the appendix.</w:t>"))
        #expect(String(decoding: parts["word/settings.xml"]!, as: UTF8.self).contains("<w:footnotePr>"))
        let xml = String(decoding: parts["word/document.xml"]!, as: UTF8.self)
        #expect(xml.contains("<w:vertAlign w:val=\"superscript\"/></w:rPr><w:footnoteReference w:id=\""))

        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.notes.first { $0.key == first }?.text == "See the appendix.")
        #expect(NoteNumbering.references(in: reread.body).count == 2)
    }

    @Test("The page a footnote is referred to on keeps room at its foot for it")
    func footOfPage() throws {
        let (controller, latest) = makeController(text: "A claim.")
        controller.textView.selectedRange = NSRange(location: 8, length: 0)
        let key = controller.insertNote(.footnote)
        var document = try #require(latest())
        let index = try #require(document.notes.firstIndex { $0.key == key })
        document.notes[index].text = "The source."
        controller.update(document: document, scheme: .light)

        let notes = try #require(controller.layoutManager.notesByPage[0])
        #expect(notes.map(\.string) == ["1 The source."])
        #expect((controller.layoutManager.noteHeights[0] ?? 0) > PageLayoutManager.noteSeparatorSpace)
        // The PDF draws them too, on its one page.
        #expect(!PDFExporter.data(from: document).isEmpty)
    }

    @Test("Deleting a reference takes its note, and the rest renumber")
    func deletes() throws {
        let (controller, latest) = makeController(text: "A B")
        controller.textView.selectedRange = NSRange(location: 1, length: 0)
        let first = controller.insertNote(.footnote)
        controller.textView.selectedRange = NSRange(location: 4, length: 0)
        let second = controller.insertNote(.endnote)
        controller.deleteNote(first)

        let document = try #require(latest())
        #expect(document.notes.map(\.key) == [second])
        #expect(controller.textView.text == "A Bi")
    }
}
