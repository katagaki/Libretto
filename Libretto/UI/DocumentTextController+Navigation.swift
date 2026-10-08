import UIKit

/// A heading, for finding one's way about the document.
struct HeadingEntry: Identifiable, Equatable {
    var id: Int { location }
    var level: Int
    var text: String
    /// Where its paragraph starts in the text.
    var location: Int
}

extension DocumentTextController {
    // MARK: - Headings

    /// The document's headings, in order: paragraphs in a heading style, or with an outline level of their own.
    var headings: [HeadingEntry] {
        let string = storage.string as NSString
        var result: [HeadingEntry] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(range) }
            guard range.length > 0, !isBlockLine(range) else { continue }
            let paragraph = paragraphModel(for: range)
            let resolved = document.styles.resolvedParagraphProperties(paragraph.properties)
            guard let level = document.styles.headingLevel(ofStyle: paragraph.properties.styleID)
                ?? resolved.outlineLevel.flatMap({ $0 < 9 ? $0 + 1 : nil }) else { continue }
            let text = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: TextCharacters.lineBreak, with: " ")
            guard !text.isEmpty else { continue }
            result.append(HeadingEntry(level: level, text: text, location: range.location))
        }
        return result
    }

    /// Puts the caret at `location` and brings it into view.
    func goTo(_ location: Int, length: Int = 0) {
        let clamped = min(location, storage.length)
        textView.selectedRange = NSRange(location: clamped, length: min(length, storage.length - clamped))
        selectionDidChange()
        if let position = textView.position(from: textView.beginningOfDocument, offset: clamped) {
            view.scrollToVisible(textView.caretRect(for: position))
        }
    }

    // MARK: - Bookmarks

    /// Each bookmark's text, by name.
    var bookmarkRanges: [String: NSRange] {
        BookmarkAnchors.ranges(in: storage, trailing: trailingMarkers)
    }

    /// Marks the selection, or the caret's place, with a bookmark, returning
    /// its name as Word will have it. A bookmark of the same name moves here.
    @discardableResult
    func addBookmark(_ requested: String) -> String {
        let name = BookmarkAnchors.validName(requested)
        removeBookmarkMarkers { $0 == name }
        var ids: [Int] = []
        storage.enumerateAttribute(.librettoMarkers, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            for inline in (value as? MarkersBox)?.markers ?? [] {
                if let marker = BookmarkAnchors.marker(inline), let id = Int(marker.id) { ids.append(id) }
            }
        }
        for inline in trailingMarkers { if let marker = BookmarkAnchors.marker(inline), let id = Int(marker.id) { ids.append(id) } }
        let id = String((ids.max() ?? -1) + 1)
        let range = textView.selectedRange
        storage.beginEditing()
        attach([BookmarkAnchors.start(id: id, name: name)], at: range.location, nearText: true)
        attach([BookmarkAnchors.end(id: id)], at: NSMaxRange(range), nearText: false)
        storage.endEditing()
        relayout()
        sync(scope: .other)
        return name
    }

    func deleteBookmark(_ name: String) {
        removeBookmarkMarkers { $0 == name }
        relayout()
        sync(scope: .other)
    }

    /// Takes away the markers of the bookmarks whose names pass `matches`.
    private func removeBookmarkMarkers(_ matches: (String) -> Bool) {
        var ids: Set<String> = []
        func collect(_ markers: [Inline]) {
            for inline in markers {
                if let marker = BookmarkAnchors.marker(inline), marker.isStart, let name = marker.name, matches(name) {
                    ids.insert(marker.id)
                }
            }
        }
        storage.enumerateAttribute(.librettoMarkers, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            collect((value as? MarkersBox)?.markers ?? [])
        }
        collect(trailingMarkers)
        guard !ids.isEmpty else { return }
        func keeps(_ inline: Inline) -> Bool { BookmarkAnchors.marker(inline).map { !ids.contains($0.id) } ?? true }
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
    }
}
