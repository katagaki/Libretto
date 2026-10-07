import Foundation

/// Where comments sit in the editor's text, read from the markers that
/// bound them: `w:commentRangeStart` before the first character,
/// `w:commentRangeEnd` and the run holding `w:commentReference` after the last.
enum CommentAnchors {
    nonisolated(unsafe) private static let pattern = #/^<(?:[\w.\-]+:)?(commentRangeStart|commentRangeEnd|commentReference)\b[^>]*?\s(?:[\w.\-]+:)?id="([^"]*)"/#

    /// Which comment marker an inline is, and the comment it belongs to.
    static func marker(_ inline: Inline) -> (kind: String, id: String)? {
        switch inline.content {
        case .runChild(let xml, _), .paragraphChild(let xml, _):
            guard let match = xml.firstMatch(of: pattern) else { return nil }
            return (String(match.output.1), String(match.output.2))
        default:
            return nil
        }
    }

    /// Each comment's range of text, by comment ID.
    static func ranges(in text: NSAttributedString, trailing: [Inline]) -> [String: NSRange] {
        var starts: [String: Int] = [:]
        var result: [String: NSRange] = [:]
        func visit(_ markers: [Inline], at location: Int) {
            for inline in markers {
                guard let (kind, id) = marker(inline) else { continue }
                if kind == "commentRangeStart" {
                    starts[id] = location
                } else if kind == "commentRangeEnd", let start = starts[id] {
                    result[id] = NSRange(location: start, length: max(0, location - start))
                }
            }
        }
        text.enumerateAttribute(.librettoMarkers, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let box = value as? MarkersBox else { return }
            visit(box.markers, at: range.location)
        }
        visit(trailing, at: text.length)
        return result
    }

    static func start(_ id: String) -> Inline {
        Inline(.paragraphChild(xml: "<w:commentRangeStart w:id=\"\(XMLLite.escape(id))\"/>", display: nil))
    }

    /// The end of a comment's range, and the reference that ties the comment to it.
    static func end(_ id: String, referenceStyleID: String?) -> [Inline] {
        var format = RunFormat()
        format.style.characterStyleID = referenceStyleID
        return [
            Inline(.paragraphChild(xml: "<w:commentRangeEnd w:id=\"\(XMLLite.escape(id))\"/>", display: nil)),
            Inline(.runChild(xml: "<w:commentReference w:id=\"\(XMLLite.escape(id))\"/>", display: nil), format: format),
        ]
    }
}
