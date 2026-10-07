import Foundation

/// Reads and writes plain text files: a paragraph for each line, and no
/// formatting kept.
enum PlainText {
    /// The file's text, in the encoding its byte order mark names or else
    /// UTF-8, falling back to Latin-1, with every line ending made `\n`.
    static func string(from data: Data) -> String {
        var text: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: data.dropFirst(3), as: UTF8.self)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func document(from data: Data) -> WordDocument {
        var lines = string(from: data).components(separatedBy: "\n")
        // The newline ending the last line does not start another.
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        var document = WordDocument()
        document.body = lines.map { line in
            // Lines follow one another as closely as they do in the file.
            .paragraph(Paragraph(inlines: inlines(line), properties: ParagraphProperties(spacingAfter: 0)))
        }
        return document
    }

    static func data(from document: WordDocument) -> Data {
        let text = document.body.flatMap(lines(of:)).joined(separator: "\n")
        return Data((text.isEmpty ? "" : text + "\n").utf8)
    }

    private static func lines(of block: Block) -> [String] {
        switch block {
        case .paragraph(let paragraph):
            return [paragraph.plainText]
        case .table(let table):
            return table.rows.map { row in
                row.cells.map { $0.plainText.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
            }
        case .preserved(let block):
            return [block.displayText]
        }
    }

    /// `text` as inlines in one format, with its tabs and line breaks as
    /// inlines of their own, as Word has them.
    static func inlines(_ text: String, format: RunFormat = RunFormat(), hyperlink: Hyperlink? = nil) -> [Inline] {
        var result: [Inline] = []
        var run = ""
        func add(_ content: InlineContent) {
            result.append(Inline(content, format: format, hyperlink: hyperlink))
        }
        for character in text {
            switch character {
            case "\t", "\n":
                if !run.isEmpty { add(.text(run)) }
                run = ""
                add(character == "\t" ? .tab : .lineBreak)
            default:
                run.append(character)
            }
        }
        if !run.isEmpty { add(.text(run)) }
        return result
    }
}
