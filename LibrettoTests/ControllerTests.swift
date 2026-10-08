import Foundation
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Page view editing")
struct ControllerTests {
    /// A controller on a new document, with what it hands over captured.
    private func makeController() -> (DocumentTextController, EditorState, () -> WordDocument?) {
        let controller = DocumentTextController(document: WordDocument(), scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, state, { latest })
    }

    /// Types as the keyboard does: the delegate is asked first, and may make
    /// the change itself. Inserting text from code skips the asking.
    private func type(_ text: String, into controller: DocumentTextController) {
        let textView = controller.textView
        for character in text {
            let string = String(character)
            if controller.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: string) {
                textView.insertText(string)
            }
        }
    }

    @Test("Bold chosen with nothing selected applies to what is typed next")
    func typingBold() throws {
        let (controller, _, latest) = makeController()
        type("Plain ", into: controller)
        controller.toggleBold()
        type("bold", into: controller)
        controller.flush()

        let document = try #require(latest())
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        #expect(paragraph.plainText == "Plain bold")
        let bold = paragraph.inlines.first { $0.plainText == "bold" }
        #expect(bold?.format.style.isBold == true)
    }

    @Test("Bold applied to a selection changes just that text")
    func selectionBold() throws {
        let (controller, state, latest) = makeController()
        type("One two three", into: controller)
        controller.textView.selectedRange = NSRange(location: 4, length: 3)
        controller.toggleBold()
        #expect(state.selectionFormat.isBold)

        let document = try #require(latest())
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        #expect(paragraph.inlines.map(\.plainText) == ["One ", "two", " three"])
        #expect(paragraph.inlines[1].format.style.isBold == true)
    }

    @Test("Replacing found text keeps that text's formatting, wherever the caret is")
    func replaceFound() throws {
        let (controller, _, latest) = makeController()
        type("One two three", into: controller)
        controller.textView.selectedRange = NSRange(location: 4, length: 3)
        controller.toggleBold()
        // Find and Replace replaces away from the selection.
        controller.textView.selectedRange = NSRange(location: 0, length: 0)
        let textView = controller.textView
        if controller.textView(textView, shouldChangeTextIn: NSRange(location: 4, length: 3), replacementText: "2") {
            textView.textStorage.replaceCharacters(in: NSRange(location: 4, length: 3), with: "2")
        }
        controller.flush()

        let document = try #require(latest())
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        #expect(paragraph.plainText == "One 2 three")
        #expect(paragraph.inlines.first { $0.plainText == "2" }?.format.style.isBold == true)
    }

    @Test("A font chosen for a selection is the run's, and written as its fonts")
    func font() throws {
        let (controller, state, latest) = makeController()
        type("One two three", into: controller)
        controller.textView.selectedRange = NSRange(location: 4, length: 3)
        controller.setFont("Georgia")
        #expect(state.selectionFormat.fontName == "Georgia")

        let document = try #require(latest())
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        #expect(paragraph.inlines[1].format.style.fontName == "Georgia")
        let xml = String(decoding: try ZipArchive.entries(in: DOCXWriter.data(from: document))["word/document.xml"]!,
                         as: UTF8.self)
        #expect(xml.contains("w:ascii=\"Georgia\""))
    }

    @Test("A link made of a selection is written with its address, and can be taken away")
    func links() throws {
        let (controller, state, latest) = makeController()
        type("Visit the site today", into: controller)
        controller.textView.selectedRange = NSRange(location: 6, length: 8)
        controller.makeLink(address: "example.com", text: "the site")
        controller.textView.selectedRange = NSRange(location: 9, length: 0)
        #expect(state.isOnLink)

        let document = try #require(latest())
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        let link = try #require(paragraph.inlines.first { $0.hyperlink != nil })
        #expect(link.plainText == "the site")
        #expect(link.hyperlink?.url == URL(string: "https://example.com"))
        let parts = try ZipArchive.entries(in: DOCXWriter.data(from: document))
        let rels = String(decoding: try #require(parts["word/_rels/document.xml.rels"]), as: UTF8.self)
        #expect(rels.contains("Target=\"https://example.com\" TargetMode=\"External\""))
        let reread = try DOCXReader.document(fromParts: parts)
        guard case .paragraph(let readBack) = reread.body[0] else { return }
        #expect(readBack.inlines.first { $0.hyperlink != nil }?.hyperlink?.url == URL(string: "https://example.com"))

        controller.removeLink()
        guard case .paragraph(let unlinked)? = latest()?.body[0] else { return }
        #expect(unlinked.inlines.allSatisfy { $0.hyperlink == nil })
        #expect(unlinked.plainText == "Visit the site today")
    }

    @Test("With nothing selected, a link goes in as its text")
    func insertedLink() throws {
        let (controller, _, latest) = makeController()
        type("See ", into: controller)
        controller.makeLink(address: "#summary", text: "the summary")
        let document = try #require(latest())
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        #expect(paragraph.plainText == "See the summary")
        #expect(paragraph.inlines.last?.hyperlink?.anchor == "summary")
        #expect(DocumentTextController.linkTarget("me@example.com").url == "mailto:me@example.com")
    }

    @Test("A cell edited on the page keeps its formatting, and Tab goes on to the next")
    func editsCellInPlace() throws {
        let (controller, _, latest) = makeController()
        controller.insertTable(rows: 2, columns: 3)
        var table = try #require(latest()?.body.compactMap { if case .table(let table) = $0 { return table } else { return nil } }.first)
        TableEditing.setText("Bold", row: 0, cell: 1, in: &table)
        table.rows[0].cells[1].blocks = table.rows[0].cells[1].blocks.map { block in
            guard case .paragraph(var paragraph) = block else { return block }
            paragraph.inlines[0].format.style.isBold = true
            return .paragraph(paragraph)
        }
        controller.replaceTable(table)

        controller.beginCellEditing(table: table, at: CellPosition(row: 0, column: 1))
        let editor = try #require(controller.cellSession?.editor)
        #expect(editor.text == "Bold")
        editor.selectedRange = NSRange(location: 4, length: 0)
        editor.insertText(" text")
        controller.endCellEditing(thenMove: 1)
        #expect(controller.cellSession?.position == CellPosition(row: 0, column: 2))
        controller.endCellEditing()

        let edited = try #require(latest()?.body.compactMap { if case .table(let table) = $0 { return table } else { return nil } }.first)
        let cell = edited.rows[0].cells[1]
        #expect(cell.plainText == "Bold text")
        #expect(cell.blocks.first?.paragraphs.first?.inlines.first?.format.style.isBold == true)
    }

    @Test("Symbols go in as typed, and Word's own hyphens are written as Word writes them")
    func symbols() throws {
        let (controller, _, latest) = makeController()
        type("well", into: controller)
        controller.insertSymbol("\u{2011}")
        type("known", into: controller)
        controller.insertSymbol("\u{2014}")
        controller.flush()
        let document = try #require(latest())
        guard case .paragraph(let paragraph) = document.body[0] else { return }
        #expect(paragraph.plainText == "well\u{2011}known\u{2014}")
        let xml = String(decoding: try ZipArchive.entries(in: DOCXWriter.data(from: document))["word/document.xml"]!, as: UTF8.self)
        #expect(xml.contains("<w:t xml:space=\"preserve\">well</w:t><w:noBreakHyphen/><w:t xml:space=\"preserve\">known\u{2014}</w:t>"))
        let reread = try DOCXReader.document(from: DOCXWriter.data(from: document))
        #expect(reread.allParagraphs.first?.plainText == "well\u{2011}known\u{2014}")
    }

    @Test("Return after a heading starts a body paragraph")
    func nextStyle() throws {
        let (controller, _, latest) = makeController()
        controller.applyParagraphStyle(.heading1)
        type("Title\nBody", into: controller)
        controller.flush()

        let document = try #require(latest())
        let paragraphs = document.body.compactMap { block -> Paragraph? in
            if case .paragraph(let paragraph) = block { return paragraph } else { return nil }
        }
        #expect(paragraphs.map(\.plainText) == ["Title", "Body"])
        #expect(paragraphs.first?.properties.styleID == "Heading1")
        #expect(paragraphs.last?.properties.styleID == nil)
    }

    @Test("Lists number as they are typed, and Return on an empty item ends them")
    func lists() throws {
        let (controller, state, latest) = makeController()
        controller.toggleList(.numbered)
        type("One\nTwo\n\n", into: controller)
        controller.flush()
        #expect(state.selectionFormat.listKind == nil)

        let document = try #require(latest())
        let lists = document.body.compactMap { block -> ListReference?? in
            if case .paragraph(let paragraph) = block { return paragraph.properties.list } else { return nil }
        }
        #expect(lists.count == 3)
        #expect(lists[0] != nil && lists[1] != nil)
        #expect(lists[2] == nil)
    }

    @Test("A table goes in and comes out")
    func tables() throws {
        let (controller, state, latest) = makeController()
        type("Before", into: controller)
        controller.insertTable(rows: 2, columns: 3)
        let inserted = try #require(latest())
        #expect(inserted.body.contains { if case .table = $0 { return true } else { return false } })

        // The caret sits after the table; step back onto its line.
        controller.textView.selectedRange = NSRange(location: controller.textView.selectedRange.location - 2, length: 0)
        #expect(state.selectedTableID != nil)
        var table = try #require(controller.selectedTable)
        TableEditing.setText("Hello", row: 0, cell: 0, in: &table)
        controller.replaceTable(table)
        guard case .table(let edited)? = latest()?.body.first(where: { $0.id == table.id }) else {
            Issue.record("the table went missing")
            return
        }
        #expect(edited.rows[0].cells[0].plainText == "Hello")

        controller.deleteSelectedTable()
        #expect(latest()?.body.contains { if case .table = $0 { return true } else { return false } } == false)
    }
}
