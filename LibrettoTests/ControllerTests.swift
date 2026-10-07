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
