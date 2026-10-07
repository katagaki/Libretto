import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Libretto

@MainActor
@Suite("Code editor")
struct CodeEditorTests {
    private func makeEditor(_ source: String) -> (CodeEditorController, () -> WordDocument?) {
        var document = PlainText.document(from: Data(source.utf8), format: PlainText.codeFormat)
        document.sourceLanguage = .swift
        let controller = CodeEditorController(document: document, language: .swift, scheme: .light)
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        controller.view.layoutIfNeeded()
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, { latest })
    }

    @Test("Return keeps the line's indent, and typing reaches the document as lines")
    func typing() throws {
        let (controller, latest) = makeEditor("func f() {\n\tlet a = 1\n}")
        let textView = controller.view.textView
        textView.selectedRange = NSRange(location: ("func f() {\n\tlet a = 1" as NSString).length, length: 0)
        if controller.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: "\n") {
            textView.insertText("\n")
        }
        textView.insertText("let b = 2")
        controller.textViewDidChange(textView)
        controller.flush()

        let document = try #require(latest())
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == "func f() {\n\tlet a = 1\n\tlet b = 2\n}\n")
        #expect(document.sourceLanguage == .swift)
    }

    @Test("A long line makes the text wider than the screen rather than wrapping")
    func longLines() {
        let (controller, _) = makeEditor("let short = 1\nlet long = \"" + String(repeating: "x", count: 200) + "\"")
        let textView = controller.view.textView
        #expect(textView.frame.width > controller.view.bounds.width)
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        var fragments = 0
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, _, _ in
            fragments += 1
        }
        #expect(fragments == 2)
    }

    @Test("A document changed elsewhere, as by an undo, replaces the text")
    func update() {
        let (controller, _) = makeEditor("let a = 1")
        var changed = controller.document
        changed.body = PlainText.body(from: "let b = 2\nlet c = 3", format: PlainText.codeFormat)
        controller.update(document: changed, scheme: .light)
        #expect(controller.view.textView.text == "let b = 2\nlet c = 3")
        let keyword = controller.view.textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(keyword == SyntaxHighlighter.color(for: .keyword, scheme: .light))
    }
}
