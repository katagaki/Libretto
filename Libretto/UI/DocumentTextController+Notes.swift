import UIKit

extension DocumentTextController {
    /// Inserts a reference to a new, empty footnote or endnote at the caret,
    /// returning the note's key.
    @discardableResult
    func insertNote(_ kind: NoteKind) -> String {
        let id = document.unusedNoteID(kind)
        let styleName = "\(kind.rawValue) reference"
        let referenceStyle = document.styles.styles.values
            .first { $0.kind == .character && $0.name.lowercased() == styleName }?.id
        let selection = textView.selectedRange
        var format = runBox(forTypingAt: selection.location).format
        if let referenceStyle {
            format.style.characterStyleID = referenceStyle
        } else {
            format.style.verticalAlignment = .superscript
        }
        let inline = Inline(.note(NoteReference(kind: kind, id: id)), format: format, revision: insertionRevision)
        let note = Note(kind: kind, id: id, text: "")
        document.notes.append(note)

        var attributes = typingAttributes(at: selection.location)
        let paragraph = paragraphModel(for: paragraphRange(at: selection.location))
        attributes.merge(DocumentRenderer.runAttributes(
            format, hyperlink: nil, revision: inline.revision, paragraph: paragraph, context: context
        )) { _, run in run }
        // Numbered properly once it is in, when the document is laid out afresh.
        attributes[.librettoToken] = InlineBox(inline, display: "*")
        insert(NSAttributedString(string: "*", attributes: attributes), at: selection, selecting: selection.location + 1)
        return note.key
    }

    /// The text range of a note's reference.
    func noteReferenceRange(_ key: String) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(.librettoToken, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let box = value as? InlineBox, case .note(let reference) = box.inline.content,
                  "\(reference.kind.rawValue):\(reference.id)" == key else { return }
            found = range
            stop.pointee = true
        }
        return found
    }

    /// Puts the caret just after a note's reference and brings it into view.
    func selectNoteReference(_ key: String) {
        guard let range = noteReferenceRange(key) else { return }
        textView.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
        selectionDidChange()
        if let start = textView.position(from: textView.beginningOfDocument, offset: range.location) {
            view.scrollToVisible(textView.caretRect(for: start))
        }
    }

    /// Deletes a note and its reference.
    func deleteNote(_ key: String) {
        if let range = noteReferenceRange(key) {
            storage.deleteCharacters(in: range)
            textView.selectedRange = NSRange(location: min(range.location, storage.length), length: 0)
        }
        document.notes.removeAll { $0.key == key }
        relayout()
        sync(scope: .notes)
        selectionDidChange()
    }
}
