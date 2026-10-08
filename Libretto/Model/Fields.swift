import Foundation

/// What updating fields needs to know that the document itself does not say:
/// where things fall on the pages, and how many there are.
struct FieldEnvironment {
    /// The page number, from one, a paragraph is on.
    var pageOfParagraph: (Paragraph.ID) -> Int? = { _ in nil }
    /// The page number a bookmark starts on.
    var pageOfBookmark: (String) -> Int? = { _ in nil }
    var pageCount = 1
    var now = Date()
}

/// Fields: Word's `w:fldChar` begin, code, separator, result and end, and
/// working out a field's result afresh.
enum Fields {
    /// A field within one paragraph: where its parts are among the inlines.
    struct Located {
        var begin: Int
        var separator: Int?
        var end: Int
        var code: String
    }

    enum Part { case begin, separate, end, code(String) }

    nonisolated(unsafe) private static let charType = #/fldCharType="(begin|separate|end)"/#
    nonisolated(unsafe) private static let instruction = #/^<(?:[\w.\-]+:)?instrText\b[^>]*>(.*)</(?:[\w.\-]+:)?instrText>$/#

    static func part(of inline: Inline) -> Part? {
        guard case .runChild(let xml, _) = inline.content else { return nil }
        if let match = xml.firstMatch(of: charType) {
            switch match.output.1 {
            case "begin": return .begin
            case "separate": return .separate
            default: return .end
            }
        }
        if let match = xml.firstMatch(of: instruction) { return .code(XMLLite.unescape(String(match.output.1))) }
        if xml.contains("instrText") { return .code("") }
        return nil
    }

    /// The outermost fields a paragraph holds whole.
    static func fields(in inlines: [Inline]) -> [Located] {
        var result: [Located] = []
        var stack: [(begin: Int, separator: Int?, code: String)] = []
        for (index, inline) in inlines.enumerated() {
            switch part(of: inline) {
            case .begin?: stack.append((index, nil, ""))
            case .code(let text)?:
                if !stack.isEmpty, stack[stack.count - 1].separator == nil { stack[stack.count - 1].code += text }
            case .separate?:
                if !stack.isEmpty, stack[stack.count - 1].separator == nil { stack[stack.count - 1].separator = index }
            case .end?:
                guard let field = stack.popLast() else { continue }
                if stack.isEmpty { result.append(Located(begin: field.begin, separator: field.separator, end: index, code: field.code)) }
            case nil: continue
            }
        }
        return result
    }

    /// A field's code split into words, quoted ones kept whole.
    static func words(_ code: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in code {
            if character == "\"" {
                quoted.toggle()
                if !quoted { words.append(current); current = "" }
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: - Updating

    /// The blocks with every field Libretto can work out given its result afresh.
    static func update(_ blocks: [Block], environment: FieldEnvironment) -> [Block] {
        let bookmarks = bookmarkTexts(in: blocks)
        var sequences: [String: Int] = [:]
        func update(_ blocks: [Block]) -> [Block] {
            blocks.map { block in
                switch block {
                case .paragraph(var paragraph):
                    let before = paragraph.inlines
                    var updated = paragraph.inlines
                    // Each result put in moves the later fields' parts along by its change in length.
                    var offset = 0
                    for field in fields(in: before) {
                        let words = self.words(field.code)
                        guard let result = result(of: words, paragraph: paragraph, environment: environment,
                                                   bookmarks: bookmarks, sequences: &sequences) else { continue }
                        let begin = field.begin + offset
                        let end = field.end + offset
                        let separator = field.separator.map { $0 + offset }
                        let format = separator.flatMap { index in
                            updated[(index + 1)..<end].first { if case .text = $0.content { return true } else { return false } }?.format
                        } ?? updated[begin].format
                        let replacement = result.isEmpty ? [] : [Inline(.text(result), format: format, hyperlink: updated[begin].hyperlink)]
                        if let separator {
                            updated.replaceSubrange((separator + 1)..<end, with: replacement)
                            offset += replacement.count - (end - separator - 1)
                        } else {
                            let separate = Inline(.runChild(xml: "<w:fldChar w:fldCharType=\"separate\"/>", display: nil),
                                                  format: updated[begin].format)
                            updated.insert(contentsOf: [separate] + replacement, at: end)
                            offset += 1 + replacement.count
                        }
                    }
                    if updated != before {
                        paragraph.inlines = updated
                    }
                    return .paragraph(paragraph)
                case .table(var table):
                    for row in table.rows.indices {
                        for cell in table.rows[row].cells.indices {
                            table.rows[row].cells[cell].blocks = update(table.rows[row].cells[cell].blocks)
                        }
                    }
                    return .table(table)
                case .preserved:
                    return block
                }
            }
        }
        return update(blocks)
    }

    /// A field's result, if it is one Libretto works out.
    static func result(
        of words: [String], paragraph: Paragraph, environment: FieldEnvironment, bookmarks: [String: String],
        sequences: inout [String: Int]
    ) -> String? {
        guard let type = words.first?.uppercased() else { return nil }
        let switches = Array(words.dropFirst())
        func value(after flag: String) -> String? {
            guard let index = switches.firstIndex(where: { $0.lowercased() == flag.lowercased() }), index + 1 < switches.count else { return nil }
            return switches[index + 1]
        }
        let format = value(after: "\\*")
        switch type {
        case "PAGE":
            return environment.pageOfParagraph(paragraph.id).map { number($0, format) }
        case "NUMPAGES", "SECTIONPAGES":
            return number(environment.pageCount, format)
        case "DATE", "TIME", "CREATEDATE", "SAVEDATE", "PRINTDATE":
            let picture = value(after: "\\@") ?? (type == "TIME" ? "h:mm am/pm" : "M/d/yyyy")
            return date(environment.now, picture: picture)
        case "SEQ":
            guard let name = switches.first else { return nil }
            if let reset = value(after: "\\r").flatMap({ Int($0) }) {
                sequences[name] = reset
            } else if !switches.contains(where: { $0.lowercased() == "\\c" }) {
                sequences[name, default: 0] += 1
            }
            if switches.contains(where: { $0.lowercased() == "\\h" }) { return "" }
            return number(sequences[name] ?? 1, format)
        case "REF":
            guard let name = switches.first else { return nil }
            return bookmarks[name]
        case "PAGEREF":
            guard let name = switches.first else { return nil }
            return environment.pageOfBookmark(name).map { number($0, format) }
        default:
            return nil
        }
    }

    /// A number in a field's `\*` format.
    static func number(_ value: Int, _ format: String?) -> String {
        switch format {
        case "roman": return ListLabeler.format(value, as: "lowerRoman")
        case "ROMAN": return ListLabeler.format(value, as: "upperRoman")
        case "alphabetic": return ListLabeler.format(value, as: "lowerLetter")
        case "ALPHABETIC": return ListLabeler.format(value, as: "upperLetter")
        default: return String(value)
        }
    }

    /// A date in Word's picture: `d`, `M`, `yy`, `H`, `h`, `mm`, `am/pm` and quoted text.
    static func date(_ date: Date, picture: String) -> String {
        var pattern = ""
        var index = picture.startIndex
        while index < picture.endIndex {
            let rest = picture[index...]
            if rest.lowercased().hasPrefix("am/pm") {
                pattern += "a"
                index = picture.index(index, offsetBy: 5)
                continue
            }
            let character = picture[index]
            switch character {
            case "'":
                // Quoted text stays as it is, as it does in Unicode patterns.
                pattern.append(character)
            case "d", "M", "y", "H", "h", "m", "s":
                pattern.append(character)
            default:
                pattern += character.isLetter ? "'\(character)'" : String(character)
            }
            index = picture.index(after: index)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Each bookmark's text, across the paragraphs it spans.
    static func bookmarkTexts(in blocks: [Block]) -> [String: String] {
        var open: [String: String] = [:]
        var texts: [String: String] = [:]
        for paragraph in blocks.flatMap(\.paragraphs) {
            for inline in paragraph.inlines {
                if let marker = BookmarkAnchors.marker(inline) {
                    if marker.isStart, let name = marker.name {
                        open[marker.id] = name
                        texts[name] = ""
                    } else {
                        open[marker.id] = nil
                    }
                    continue
                }
                guard part(of: inline) == nil else { continue }
                for name in open.values { texts[name, default: ""] += inline.plainText }
            }
            for name in open.values { texts[name, default: ""] += "\n" }
        }
        return texts.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Making fields

    /// A field's parts as inlines, with its result, in a format.
    static func inlines(code: String, result: String, format: RunFormat) -> [Inline] {
        func child(_ xml: String) -> Inline { Inline(.runChild(xml: xml, display: nil), format: format) }
        return [
            child("<w:fldChar w:fldCharType=\"begin\"/>"),
            child("<w:instrText xml:space=\"preserve\"> \(XMLLite.escape(code)) </w:instrText>"),
            child("<w:fldChar w:fldCharType=\"separate\"/>"),
            Inline(.text(result.isEmpty ? " " : result), format: format),
            child("<w:fldChar w:fldCharType=\"end\"/>"),
        ]
    }
}

extension Fields.Part: Equatable {}
