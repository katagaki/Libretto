import Foundation

/// A table of contents as Word makes one: a `TOC` field whose result is a
/// paragraph per heading, in the `toc 1` to `toc 3` styles, each linking to
/// its heading's bookmark and ending in its page number after a dotted tab.
enum TableOfContents {
    struct Entry: Equatable {
        var level: Int
        var text: String
        var bookmark: String
    }

    static let code = "TOC \\o \"1-3\" \\h \\z \\u"

    /// The contents' paragraphs, page numbers by bookmark.
    static func paragraphs(_ entries: [Entry], styles: inout StyleSheet, pages: [String: Int], width: Int) -> [Block] {
        let listed = entries.isEmpty ? [Entry(level: 1, text: String(localized: "Contents.Empty"), bookmark: "")] : entries
        return listed.enumerated().map { index, entry in
            var paragraph = Paragraph()
            paragraph.properties.styleID = styles.ensureContentsStyle(level: entry.level, width: width)
            var inlines: [Inline] = []
            let field = Fields.inlines(code: code, result: "", format: RunFormat())
            if index == 0 { inlines += field[0..<3] }
            let link = entry.bookmark.isEmpty ? nil : Hyperlink(
                relationshipID: nil, anchor: entry.bookmark, url: nil,
                attributesXML: " w:anchor=\"\(XMLLite.escape(entry.bookmark))\" w:history=\"1\""
            )
            var entryInlines: [Inline] = [Inline(.text(entry.text)), Inline(.tab)]
            if !entry.bookmark.isEmpty {
                let page = pages[entry.bookmark].map(String.init) ?? "1"
                entryInlines += Fields.inlines(code: "PAGEREF \(entry.bookmark) \\h", result: page, format: RunFormat())
            }
            inlines += entryInlines.map { inline in
                var inline = inline
                inline.hyperlink = link
                return inline
            }
            if index == listed.count - 1 { inlines.append(field[4]) }
            paragraph.inlines = inlines
            return .paragraph(paragraph)
        }
    }

    /// The blocks with their table of contents built afresh, or `nil` if they have none.
    static func replacing(
        in blocks: [Block], with entries: [Entry], styles: inout StyleSheet, pages: [String: Int], width: Int
    ) -> [Block]? {
        // A table of contents Word wrapped in a content control is kept as a block of its own.
        if let index = blocks.firstIndex(where: { block in
            guard case .preserved(let preserved) = block else { return false }
            return preserved.xml.contains("Table of Contents") || preserved.xml.contains(" TOC ")
        }) {
            var result = blocks
            result.replaceSubrange(index...index, with: paragraphs(entries, styles: &styles, pages: pages, width: width))
            return result
        }
        // Otherwise, from the paragraph its field begins in to the one it ends in.
        var start: Int?
        var depth = 0
        for (index, block) in blocks.enumerated() {
            guard case .paragraph(let paragraph) = block else { continue }
            var code = ""
            for inline in paragraph.inlines {
                switch Fields.part(of: inline) {
                case .begin?:
                    if start != nil { depth += 1 }
                    code = ""
                case .code(let text)?:
                    code += text
                    if start == nil, code.trimmed.uppercased().hasPrefix("TOC") {
                        start = index
                        depth = 1
                    }
                case .end?:
                    guard start != nil else { continue }
                    depth -= 1
                    if depth == 0, let first = start {
                        var result = blocks
                        result.replaceSubrange(first...index, with: paragraphs(entries, styles: &styles, pages: pages, width: width))
                        return result
                    }
                default:
                    continue
                }
            }
        }
        return nil
    }
}
