import UIKit

extension DocumentTextController {
    /// The section the selection is in: where it is among the document's,
    /// its page setup, and whether it is the last, whose setup is the document's own.
    var currentSection: (index: Int, setup: PageSetup, isLast: Bool) {
        let spans = SectionLayout.spans(in: storage, final: document.pageSetup)
        let location = textView.selectedRange.location
        let index = spans.firstIndex { location <= $0.end } ?? spans.count - 1
        return (index, spans[index].setup, index == spans.count - 1)
    }

    /// Changes the page setup of the section the selection is in.
    func updateSection(_ change: (inout PageSetup) -> Void) {
        flush()
        let spans = SectionLayout.spans(in: storage, final: document.pageSetup)
        let location = textView.selectedRange.location
        let index = spans.firstIndex { location <= $0.end } ?? spans.count - 1
        updateSection(at: index, spans: spans, change)
    }

    private func updateSection(at index: Int, spans: [PageLayoutManager.SectionSpan], _ change: (inout PageSetup) -> Void) {
        guard spans.indices.contains(index) else { return }
        if index == spans.count - 1 {
            change(&document.pageSetup)
            state?.pendingScope = .pageSetup
            onChange?(document)
            render()
            return
        }
        // The section's own setup rides on the paragraph whose mark is its break.
        let range = paragraphRange(at: spans[index].end)
        var paragraph = paragraphModel(for: range)
        guard var section = paragraph.section else { return }
        change(&section)
        paragraph.section = section
        storage.addAttribute(.librettoParagraph, value: ParagraphBox(paragraph), range: range)
        commit(restyling: range, scope: .pageSetup)
    }

    /// Breaks the section at the selection: the text before the break keeps
    /// the section's setup, and what follows starts as asked.
    func insertSectionBreak(_ start: SectionStart) {
        let before = currentSection
        let selection = textView.selectedRange
        storage.beginEditing()
        storage.replaceCharacters(in: selection, with: NSAttributedString(string: "\n", attributes: typingAttributes(at: selection.location)))
        let range = paragraphRange(at: selection.location)
        var ending = paragraphModel(for: range).splitCopy()
        var setup = before.setup
        setup.start = before.setup.start
        ending.section = setup
        storage.addAttribute(.librettoParagraph, value: ParagraphBox(ending), range: range)
        storage.endEditing()
        textView.selectedRange = NSRange(location: selection.location + 1, length: 0)
        // The section after the break is the one that was there; it now starts as asked.
        if before.isLast {
            document.pageSetup.start = start
        } else {
            let spans = SectionLayout.spans(in: storage, final: document.pageSetup)
            if spans.indices.contains(before.index + 1) {
                let following = paragraphRange(at: spans[before.index + 1].end)
                var paragraph = paragraphModel(for: following)
                paragraph.section?.start = start
                storage.addAttribute(.librettoParagraph, value: ParagraphBox(paragraph), range: following)
            }
        }
        commit(restyling: NSRange(location: range.location, length: range.length + 1), scope: .insertion)
    }

    func insertColumnBreak() {
        let selection = textView.selectedRange
        let text = NSAttributedString(string: TextCharacters.columnBreak, attributes: typingAttributes(at: selection.location))
        insert(text, at: selection, selecting: selection.location + 1)
    }
}
