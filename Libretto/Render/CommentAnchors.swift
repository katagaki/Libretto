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

/// Where bookmarks are in the editor's text, read from the `w:bookmarkStart`
/// and `w:bookmarkEnd` markers that bound them.
enum BookmarkAnchors {
    nonisolated(unsafe) private static let startPattern = #/^<(?:[\w.\-]+:)?bookmarkStart\b[^>]*?\s(?:[\w.\-]+:)?id="([^"]*)"/#
    nonisolated(unsafe) private static let endPattern = #/^<(?:[\w.\-]+:)?bookmarkEnd\b[^>]*?\s(?:[\w.\-]+:)?id="([^"]*)"/#
    nonisolated(unsafe) private static let namePattern = #/\s(?:[\w.\-]+:)?name="([^"]*)"/#

    /// Which bookmark marker an inline is: its ID, and for a start, the bookmark's name.
    static func marker(_ inline: Inline) -> (isStart: Bool, id: String, name: String?)? {
        guard case .paragraphChild(let xml, _) = inline.content else { return nil }
        if let match = xml.firstMatch(of: startPattern) {
            let name = xml.firstMatch(of: namePattern).map { XMLLite.unescape(String($0.output.1)) }
            return (true, String(match.output.1), name)
        }
        if let match = xml.firstMatch(of: endPattern) { return (false, String(match.output.1), nil) }
        return nil
    }

    /// Each bookmark's range of text, by name.
    static func ranges(in text: NSAttributedString, trailing: [Inline]) -> [String: NSRange] {
        var starts: [String: (name: String, location: Int)] = [:]
        var result: [String: NSRange] = [:]
        func visit(_ markers: [Inline], at location: Int) {
            for inline in markers {
                guard let marker = marker(inline) else { continue }
                if marker.isStart, let name = marker.name {
                    starts[marker.id] = (name, location)
                    result[name] = NSRange(location: location, length: 0)
                } else if !marker.isStart, let start = starts[marker.id] {
                    result[start.name] = NSRange(location: start.location, length: max(0, location - start.location))
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

    /// Bookmark names across a document's blocks, in reading order.
    static func names(in blocks: [Block]) -> [String] {
        blocks.flatMap(\.paragraphs).flatMap(\.inlines).compactMap { marker($0)?.name }
    }

    static func start(id: String, name: String) -> Inline {
        Inline(.paragraphChild(xml: "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(XMLLite.escape(name))\"/>", display: nil))
    }

    static func end(id: String) -> Inline {
        Inline(.paragraphChild(xml: "<w:bookmarkEnd w:id=\"\(id)\"/>", display: nil))
    }

    /// Whether Word made it for its own use: a table of contents' heading, a cross-reference's target, where it left off.
    static func isHidden(_ name: String) -> Bool { name.hasPrefix("_") }

    /// A name Word accepts: a letter first, then letters, digits and underscores, forty at most.
    static func validName(_ name: String) -> String {
        var result = String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(40))
        // Word's own hidden ones start with an underscore; the rest, with a letter.
        if let first = result.first, !first.isLetter, !(first == "_" && name.hasPrefix("_")) {
            result = "B" + result.dropFirst()
        }
        return result.isEmpty ? "Bookmark" : result
    }
}
