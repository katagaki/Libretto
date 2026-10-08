import UIKit

/// Who is making changes and comments, as Word records them.
enum Reviewer {
    static let nameKey = "authorName"

    static var name: String {
        let stored = UserDefaults.standard.string(forKey: nameKey)?.trimmed ?? ""
        return stored.isEmpty ? String(localized: "Comment.DefaultAuthor") : stored
    }

    static var initials: String {
        String(name.split(separator: " ").prefix(3).compactMap(\.first)).uppercased()
    }

    /// Now, as `w:date` spells it.
    static var now: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

extension DocumentTextController {
    // MARK: - Where comments are

    func refreshCommentRanges() {
        let ranges = CommentAnchors.ranges(in: storage, trailing: trailingMarkers)
        guard ranges != commentRanges else { return }
        let changed = Array(commentRanges.values) + Array(ranges.values)
        commentRanges = ranges
        layoutManager.commentRanges = Array(ranges.values)
        redraw(changed)
    }

    private func redraw(_ ranges: [NSRange]) {
        for range in ranges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            if clamped.length > 0 { layoutManager.invalidateDisplay(forCharacterRange: clamped) }
        }
    }

    /// The comments on the text at the selection, in the comments part's order.
    func publishSelectedComments() {
        guard let state else { return }
        let selection = textView.selectedRange
        let touched = commentRanges.filter { _, range in
            guard range.length > 0 else { return false }
            if selection.length == 0 {
                return selection.location >= range.location && selection.location <= NSMaxRange(range)
            }
            return NSIntersectionRange(range, selection).length > 0
        }
        let order = Dictionary(document.comments.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = touched.keys.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
        if state.selectedCommentIDs != ids { state.selectedCommentIDs = ids }
        let active = Array(touched.values)
        if active != layoutManager.activeCommentRanges {
            let changed = layoutManager.activeCommentRanges + active
            layoutManager.activeCommentRanges = active
            redraw(changed)
        }
    }

    /// The text a comment is on, shortened to a line.
    func commentQuote(_ id: String) -> String? {
        guard let range = commentRanges[id], NSMaxRange(range) <= storage.length else { return nil }
        let text = (storage.string as NSString).substring(with: range)
            .replacingOccurrences(of: TextCharacters.lineBreak, with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: TextCharacters.attachment, with: "")
            .trimmed
        return text.count > 140 ? String(text.prefix(140)) + "…" : text
    }

    /// Selects the text a comment is on and brings it into view.
    func selectComment(_ id: String) {
        guard let range = commentRanges[id] else { return }
        textView.selectedRange = range
        selectionDidChange()
        if let start = textView.position(from: textView.beginningOfDocument, offset: range.location) {
            view.scrollToVisible(textView.caretRect(for: start))
        }
    }

    // MARK: - Adding, changing and removing

    /// Comments on the selection, or on the word at the caret.
    func addComment(_ text: String) {
        var range = textView.selectedRange
        if range.length == 0, let position = textView.selectedTextRange?.start,
           let word = textView.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.backward))
            ?? textView.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward)) {
            range = NSRange(
                location: textView.offset(from: textView.beginningOfDocument, to: word.start),
                length: textView.offset(from: word.start, to: word.end)
            )
        }
        guard range.length > 0 else { return }
        let comment = Comment(
            id: document.unusedCommentID(), author: Reviewer.name, initials: Reviewer.initials, date: Reviewer.now,
            text: text, paraID: document.unusedCommentParaID()
        )
        anchor(comment, to: range)
        textView.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
        finishCommentEdit()
    }

    /// Replies to a comment, on the same text.
    func reply(to parentID: String, text: String) {
        guard let index = document.comments.firstIndex(where: { $0.id == parentID }) else { return }
        if document.comments[index].paraID == nil { document.comments[index].paraID = document.unusedCommentParaID() }
        let parent = document.comments[index]
        var reply = Comment(
            id: document.unusedCommentID(), author: Reviewer.name, initials: Reviewer.initials, date: Reviewer.now,
            text: text, paraID: document.unusedCommentParaID()
        )
        reply.parentParaID = parent.paraID
        anchor(reply, to: commentRanges[parentID] ?? textView.selectedRange)
        finishCommentEdit()
    }

    private func anchor(_ comment: Comment, to range: NSRange) {
        let referenceStyle = document.styles.styles["CommentReference"] != nil ? "CommentReference" : nil
        storage.beginEditing()
        attach([CommentAnchors.start(comment.id)], at: range.location, nearText: true)
        attach(CommentAnchors.end(comment.id, referenceStyleID: referenceStyle), at: NSMaxRange(range), nearText: false)
        storage.endEditing()
        document.comments.append(comment)
    }

    /// Puts markers on the character at `location`, which they come before:
    /// next to it, or before any markers already there.
    func attach(_ markers: [Inline], at location: Int, nearText: Bool) {
        guard location < storage.length else {
            trailingMarkers = nearText ? trailingMarkers + markers : markers + trailingMarkers
            return
        }
        let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: location)
        let existing = (storage.attribute(.librettoMarkers, at: location, effectiveRange: nil) as? MarkersBox)?.markers ?? []
        storage.addAttribute(
            .librettoMarkers, value: MarkersBox(nearText ? existing + markers : markers + existing), range: character
        )
    }

    /// Resolves a comment, and its replies with it, or opens them again.
    func setCommentDone(_ id: String, _ isDone: Bool) {
        guard let index = document.comments.firstIndex(where: { $0.id == id }) else { return }
        if document.comments[index].paraID == nil { document.comments[index].paraID = document.unusedCommentParaID() }
        let paraID = document.comments[index].paraID
        for other in document.comments.indices
        where document.comments[other].id == id || document.comments[other].parentParaID == paraID {
            if document.comments[other].paraID == nil {
                document.comments[other].paraID = document.unusedCommentParaID()
            }
            document.comments[other].isDone = isDone
        }
        finishCommentEdit()
    }

    func editComment(_ id: String, text: String) {
        guard let index = document.comments.firstIndex(where: { $0.id == id }) else { return }
        document.comments[index].text = text
        finishCommentEdit()
    }

    /// Deletes a comment, its replies, and the markers that tie them to the text.
    func deleteComment(_ id: String) {
        guard let comment = document.comments.first(where: { $0.id == id }) else { return }
        var ids: Set<String> = [id]
        if let paraID = comment.paraID {
            for reply in document.comments where reply.parentParaID == paraID { ids.insert(reply.id) }
        }
        document.comments.removeAll { ids.contains($0.id) }
        func keeps(_ inline: Inline) -> Bool {
            CommentAnchors.marker(inline).map { !ids.contains($0.id) } ?? true
        }
        var changes: [(NSRange, [Inline])] = []
        storage.enumerateAttribute(.librettoMarkers, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let box = value as? MarkersBox else { return }
            let kept = box.markers.filter(keeps)
            if kept.count != box.markers.count { changes.append((range, kept)) }
        }
        storage.beginEditing()
        for (range, kept) in changes {
            if kept.isEmpty {
                storage.removeAttribute(.librettoMarkers, range: range)
            } else {
                storage.addAttribute(.librettoMarkers, value: MarkersBox(kept), range: range)
            }
        }
        storage.endEditing()
        trailingMarkers = trailingMarkers.filter(keeps)
        finishCommentEdit()
    }

    private func finishCommentEdit() {
        relayout()
        sync(scope: .comment)
        selectionDidChange()
    }
}
