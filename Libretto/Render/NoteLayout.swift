import UIKit

/// Footnotes and endnotes as the page layout sets them: each footnote at
/// the foot of the page its reference is on, the endnotes at the end.
enum NoteLayout {
    static func notes(
        in text: NSAttributedString, document: WordDocument, context: RenderContext
    ) -> [(location: Int, text: NSAttributedString)] {
        guard !document.notes.isEmpty else { return [] }
        let notes = Dictionary(document.notes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var footnotes: [(location: Int, text: NSAttributedString)] = []
        var endnotes: [NSAttributedString] = []
        var seen: Set<String> = []
        text.enumerateAttribute(.librettoToken, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let box = value as? InlineBox, case .note(let reference) = box.inline.content else { return }
            let key = "\(reference.kind.rawValue):\(reference.id)"
            guard seen.insert(key).inserted, let note = notes[key] else { return }
            let drawn = attributed(note, number: context.noteNumbers[key] ?? "", context: context)
            if reference.kind == .footnote {
                footnotes.append((range.location, drawn))
            } else {
                endnotes.append(drawn)
            }
        }
        // Endnotes end the document, on its last page.
        return footnotes + endnotes.map { (max(0, text.length - 1), $0) }
    }

    /// A note as drawn: its number raised, then its text, in the document's note style.
    static func attributed(_ note: Note, number: String, context: RenderContext) -> NSAttributedString {
        let styleName = "\(note.kind.rawValue) text"
        let styleID = context.styles.styles.values.first { $0.kind == .paragraph && $0.name.lowercased() == styleName }?.id
        var style = context.styles.resolvedRunStyle(RunStyle(), paragraphStyleID: styleID)
        if styleID == nil { style.fontSize = 20 }
        let font = Typography.font(for: style, styles: context.styles)
        let color = context.defaultTextColor
        let result = NSMutableAttributedString(string: number, attributes: [
            .font: font.withSize(font.pointSize * 0.7), .foregroundColor: color, .baselineOffset: font.pointSize * 0.35,
        ])
        result.append(NSAttributedString(string: " " + note.text, attributes: [.font: font, .foregroundColor: color]))
        return result
    }
}

/// The document's sections as the layout needs them: where each ends in the
/// text, at its section break's paragraph mark, and its page setup.
enum SectionLayout {
    static func spans(in text: NSAttributedString, final: PageSetup) -> [PageLayoutManager.SectionSpan] {
        var spans: [PageLayoutManager.SectionSpan] = []
        let string = text.string as NSString
        text.enumerateAttribute(.librettoParagraph, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let box = value as? ParagraphBox, let section = box.paragraph.section else { return }
            // The paragraph's mark: the last character of its range that ends a paragraph.
            let end = NSMaxRange(range) - 1
            guard end >= 0, end < string.length, string.character(at: end) == TextCharacters.paragraphBreakUnit,
                  spans.last?.end != end else { return }
            spans.append(PageLayoutManager.SectionSpan(end: end, setup: section))
        }
        return spans + [PageLayoutManager.SectionSpan(end: Int.max, setup: final)]
    }
}
