import UIKit

extension DocumentTextController {
    // MARK: - Recording

    /// Turns tracking changes on or off, a setting saved with the document.
    func setTracking(_ isOn: Bool) {
        flush()
        document.trackRevisions = isOn
        state?.pendingScope = .review
        onChange?(document)
        selectionDidChange()
    }

    /// Takes out or replaces text while changes are tracked: rather than
    /// going, it is marked deleted, apart from what this reviewer inserted in
    /// the first place, which simply goes. The replacement goes in after it.
    func trackedChange(in range: NSRange, replacement: String) {
        let deletion = Revision(kind: .deletion, author: Reviewer.name, date: revisionDate)
        let selection = textView.selectedRange
        let isBackspace = replacement.isEmpty && selection.length == 0 && selection.location == NSMaxRange(range)
        var removed = 0
        storage.beginEditing()
        // Back to front, so the characters still to come stay where they are.
        var index = NSMaxRange(range) - 1
        while index >= range.location {
            let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
            index = character.location - 1
            if storage.attribute(.librettoBlock, at: character.location, effectiveRange: nil) != nil
                || storage.attribute(.attachment, at: character.location, effectiveRange: nil) is BlockAttachment {
                continue
            }
            let box = storage.attribute(.librettoRun, at: character.location, effectiveRange: nil) as? RunBox
            switch box?.revision?.kind {
            case .insertion? where box?.revision?.author == Reviewer.name:
                storage.deleteCharacters(in: character)
                removed += character.length
            case .deletion?, .moveFrom?:
                continue
            default:
                storage.addAttribute(
                    .librettoRun,
                    value: RunBox(box?.format ?? RunFormat(), hyperlink: box?.hyperlink, revision: deletion),
                    range: character
                )
            }
        }
        let end = NSMaxRange(range) - removed
        var caret = isBackspace ? range.location : end
        if !replacement.isEmpty {
            let attributes = typingAttributes(at: end)
            storage.insert(NSAttributedString(string: replacement, attributes: attributes), at: end)
            caret = end + (replacement as NSString).length
        }
        DocumentRenderer.restyle(
            storage, paragraphsIn: NSRange(location: range.location, length: max(0, caret - range.location)),
            finalParagraph: finalParagraph, context: context
        )
        storage.endEditing()
        textView.selectedRange = NSRange(location: min(caret, storage.length), length: 0)
        textDidChange(touchingParagraphs: true)
    }

    // MARK: - Reviewing

    /// The tracked change at the selection: the whole run of text marked as the same change.
    func revisionRange(around location: Int) -> NSRange? {
        for index in [location, location - 1] where index >= 0 && index < storage.length {
            guard let revision = (storage.attribute(.librettoRun, at: index, effectiveRange: nil) as? RunBox)?.revision
            else { continue }
            func same(_ at: Int) -> Bool {
                (storage.attribute(.librettoRun, at: at, effectiveRange: nil) as? RunBox)?.revision == revision
            }
            var start = index
            var end = index + 1
            while start > 0, same(start - 1) { start -= 1 }
            while end < storage.length, same(end) { end += 1 }
            return NSRange(location: start, length: end - start)
        }
        return nil
    }

    /// Accepts or rejects the changes in the selection, or the change at the caret.
    func resolveChange(accept: Bool) {
        let selection = textView.selectedRange
        guard let range = selection.length > 0 ? selection : revisionRange(around: selection.location) else { return }
        storage.beginEditing()
        var index = NSMaxRange(range) - 1
        var end = NSMaxRange(range)
        while index >= range.location {
            let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
            index = character.location - 1
            guard let box = storage.attribute(.librettoRun, at: character.location, effectiveRange: nil) as? RunBox,
                  let revision = box.revision else { continue }
            if accept == revision.kind.adds {
                storage.addAttribute(.librettoRun, value: RunBox(box.format, hyperlink: box.hyperlink), range: character)
            } else {
                storage.deleteCharacters(in: character)
                end -= character.length
            }
        }
        DocumentRenderer.restyle(
            storage, paragraphsIn: NSRange(location: range.location, length: max(0, end - range.location)),
            finalParagraph: finalParagraph, context: context
        )
        storage.endEditing()
        textView.selectedRange = NSRange(location: min(end, storage.length), length: 0)
        relayout()
        sync(scope: .review)
        selectionDidChange()
    }

    /// Accepts or rejects every change in the document, tables and formatting changes among them.
    func resolveAllChanges(accept: Bool) {
        flush()
        document.body = Revisions.resolve(document.body, accept: accept)
        state?.pendingScope = .review
        render()
        onChange?(document)
    }

    /// Selects the next tracked change after the selection, or the one before it.
    func selectChange(forward: Bool) {
        let selection = textView.selectedRange
        var found: NSRange?
        storage.enumerateAttribute(
            .librettoRun, in: NSRange(location: 0, length: storage.length), options: forward ? [] : [.reverse]
        ) { value, range, stop in
            guard (value as? RunBox)?.revision != nil else { return }
            let isAhead = forward ? range.location >= NSMaxRange(selection) && range.location > selection.location
                : NSMaxRange(range) <= selection.location
            guard isAhead else { return }
            found = revisionRange(around: forward ? range.location : NSMaxRange(range) - 1)
            stop.pointee = true
        }
        guard let found else { return }
        textView.selectedRange = found
        selectionDidChange()
        if let start = textView.position(from: textView.beginningOfDocument, offset: found.location) {
            view.scrollToVisible(textView.caretRect(for: start))
        }
    }

    /// How many tracked changes the document has, counting each run of one as one.
    var changeCount: Int {
        var count = 0
        var last: Revision?
        storage.enumerateAttribute(.librettoRun, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            let revision = (value as? RunBox)?.revision
            if let revision, revision != last { count += 1 }
            last = revision
        }
        return count
    }
}
