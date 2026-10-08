import UIKit

extension DocumentTextController {
    /// Puts a table of contents in before the paragraph at the selection,
    /// built from the headings, and numbers its pages.
    func insertTableOfContents() {
        flush()
        let location = textView.selectedRange.location
        let id = paragraphModel(for: paragraphRange(at: location)).id
        let entries = contentsEntries()
        let index = document.body.firstIndex { $0.id == id } ?? document.body.count
        document.body.insert(contentsOf: TableOfContents.paragraphs(entries, styles: &document.styles, pages: [:], width: Int(context.contentWidth * 20)), at: index)
        state?.pendingScope = .insertion
        render()
        onChange?(document)
        updateTableOfContents()
    }

    /// Builds the table of contents afresh from the headings, with the pages they are on now.
    func updateTableOfContents() {
        flush()
        let entries = contentsEntries()
        // Twice: the contents' own length can move the headings on to other pages.
        for _ in 0..<2 {
            let environment = fieldEnvironment()
            var pages: [String: Int] = [:]
            for entry in entries { pages[entry.bookmark] = environment.pageOfBookmark(entry.bookmark) }
            guard let replaced = TableOfContents.replacing(
                in: document.body, with: entries, styles: &document.styles, pages: pages, width: Int(context.contentWidth * 20)
            ),
                  replaced != document.body else { break }
            document.body = replaced
            state?.pendingScope = .other
            render()
            onChange?(document)
        }
    }

    /// The headings to list, levels one to three, each with the hidden bookmark the contents link to.
    private func contentsEntries() -> [TableOfContents.Entry] {
        headings.filter { $0.level <= 3 }.map { heading in
            let range = paragraphRange(at: heading.location)
            let existing = bookmarkRanges.first { $0.key.hasPrefix("_Toc") && $0.value.location == range.location }?.key
            let selection = textView.selectedRange
            var name = existing
            if name == nil {
                textView.selectedRange = NSRange(location: range.location, length: range.length - (hasMark(range) ? 1 : 0))
                name = addBookmark("_Toc" + String(Int.random(in: 100_000_000...999_999_999)))
                textView.selectedRange = selection
            }
            return TableOfContents.Entry(level: heading.level, text: heading.text, bookmark: name ?? "")
        }
    }
}
