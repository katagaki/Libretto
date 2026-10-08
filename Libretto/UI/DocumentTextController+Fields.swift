import UIKit

extension DocumentTextController {
    /// Where things are on the pages as laid out, for fields to give.
    func fieldEnvironment() -> FieldEnvironment {
        var pages: [Paragraph.ID: Int] = [:]
        func page(at location: Int) -> Int? {
            guard location < storage.length else { return nil }
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            guard glyph < layoutManager.numberOfGlyphs else { return nil }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return geometry.page(containing: line.midY) + 1
        }
        storage.enumerateAttribute(.librettoParagraph, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let box = value as? ParagraphBox, pages[box.paragraph.id] == nil else { return }
            pages[box.paragraph.id] = page(at: range.location)
        }
        let bookmarkPages = bookmarkRanges.compactMapValues { page(at: $0.location) }
        return FieldEnvironment(
            pageOfParagraph: { pages[$0] }, pageOfBookmark: { bookmarkPages[$0] }, pageCount: pageCount
        )
    }

    /// Works out every field's result afresh: dates, page numbers, captions' numbers, cross-references.
    func updateFields() {
        flush()
        let updated = Fields.update(document.body, environment: fieldEnvironment())
        guard updated != document.body else { return }
        document.body = updated
        state?.pendingScope = .other
        render()
        onChange?(document)
    }

    /// Puts a field in at the selection, with its result worked out.
    func insertField(_ code: String) {
        let selection = textView.selectedRange
        let format = runBox(forTypingAt: selection.location).format
        let parts = Fields.inlines(code: code, result: "", format: format)
        // The result stands in the text; the field's other parts ride on it, the end on what follows.
        // Markers on the character here, the end of a field just before say, close before this one opens.
        let carried = NSMaxRange(selection) < storage.length
            ? (storage.attribute(.librettoMarkers, at: NSMaxRange(selection), effectiveRange: nil) as? MarkersBox)?.markers ?? []
            : []
        let result = NSMutableAttributedString(string: " ", attributes: typingAttributes(at: selection.location))
        result.addAttribute(
            .librettoMarkers, value: MarkersBox(carried + Array(parts[0..<3])), range: NSRange(location: 0, length: 1)
        )
        storage.beginEditing()
        if !carried.isEmpty {
            let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(selection))
            storage.removeAttribute(.librettoMarkers, range: character)
        }
        storage.replaceCharacters(in: selection, with: result)
        attach([parts[4]], at: selection.location + 1, nearText: false)
        storage.endEditing()
        // After the field, measured from the end, which a result of another length does not move.
        let fromEnd = storage.length - (selection.location + 1)
        textView.selectedRange = NSRange(location: selection.location + 1, length: 0)
        relayout()
        sync(scope: .insertion)
        updateFields()
        let caret = max(0, storage.length - fromEnd)
        textView.selectedRange = NSRange(location: caret, length: 0)
        selectionDidChange()
    }

    /// A caption's label and its number: "Figure 1".
    func insertCaption(_ label: String) {
        let selection = textView.selectedRange
        insert(
            NSAttributedString(string: label + " ", attributes: typingAttributes(at: selection.location)),
            at: selection, selecting: selection.location + (label as NSString).length + 1
        )
        insertField("SEQ \(label) \\* ARABIC")
    }

    /// A cross-reference to a heading: Word refers to one by a hidden bookmark around it.
    func bookmarkHeading(_ heading: HeadingEntry) -> String {
        let range = paragraphRange(at: heading.location)
        let existing = bookmarkRanges.first { BookmarkAnchors.isHidden($0.key) && $0.value.location == range.location }
        if let existing { return existing.key }
        let selection = textView.selectedRange
        textView.selectedRange = NSRange(location: range.location, length: range.length - (hasMark(range) ? 1 : 0))
        let name = addBookmark("_Ref" + String(Int.random(in: 100_000_000...999_999_999)))
        textView.selectedRange = selection
        return name
    }
}
