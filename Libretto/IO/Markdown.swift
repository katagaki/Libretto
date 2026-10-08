import Foundation

/// Markdown, as far as Libretto's model reaches: headings, quotes, lists and
/// code, and bold, italic, struck-through, code and linked text.
///
/// Anything else, such as tables, pictures and HTML, reads as the text it was
/// written as, and is saved back as that same text. Code blocks read as
/// their lines, fences and all, so they too save back exactly as they were.
enum Markdown {
    static let codeFont = PlainText.codeFont

    /// What a line opens, if it opens anything.
    enum LineStart: Equatable {
        case heading(level: Int, text: String)
        case quote(text: String)
        /// `contentOffset` is the column the item's text starts at, which
        /// lines inside the item are indented to.
        case item(ListKind, indent: Int, contentOffset: Int, text: String)
        case fence(Character, length: Int)
    }

    /// The columns of whitespace a line starts with, a tab reaching the next stop of four.
    static func indentation(of line: some StringProtocol) -> Int {
        var column = 0
        for character in line {
            switch character {
            case " ": column += 1
            case "\t": column += 4 - column % 4
            default: return column
            }
        }
        return column
    }

    /// List items may be indented any amount, since the reader judges their
    /// nesting itself. Anything else must be indented no more than `maxIndent`.
    static func lineStart(_ line: some StringProtocol, maxIndent: Int = 3) -> LineStart? {
        let indent = indentation(of: line)
        let rest = Array(line.drop { $0 == " " || $0 == "\t" })
        guard let first = rest.first, !isThematicBreak(rest) else { return nil }
        let isGap = { (index: Int) in index == rest.count || rest[index] == " " || rest[index] == "\t" }
        let text = { (index: Int) in String(rest[min(index, rest.count)...].drop { $0 == " " || $0 == "\t" }) }

        if "-+*".contains(first), isGap(1) {
            return .item(.bulleted, indent: indent, contentOffset: indent + 2, text: text(1))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }.count
        if (1...9).contains(digits), digits < rest.count, ".)".contains(rest[digits]), isGap(digits + 1) {
            return .item(.numbered, indent: indent, contentOffset: indent + digits + 2, text: text(digits + 1))
        }

        guard indent <= maxIndent else { return nil }
        let hashes = rest.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), isGap(hashes) {
            var heading = text(hashes).trimmed
            // A closing run of hashes is not part of the heading.
            let closing = heading.reversed().prefix { $0 == "#" }.count
            if closing == heading.count || heading.dropLast(closing).last == " " {
                heading = String(heading.dropLast(closing)).trimmed
            }
            return .heading(level: hashes, text: heading)
        }
        if first == ">" {
            return .quote(text: String(rest.dropFirst(rest.count > 1 && rest[1] == " " ? 2 : 1)))
        }
        let fence = rest.prefix { $0 == first }.count
        if "`~".contains(first), fence >= 3, first == "~" || !rest[fence...].contains("`") {
            return .fence(first, length: fence)
        }
        return nil
    }

    /// Whether `line` ends a code block its fence opened.
    static func closesFence(_ line: String, character: Character, length: Int) -> Bool {
        let rest = line.drop { $0 == " " || $0 == "\t" }
        let run = rest.prefix { $0 == character }.count
        return run >= length && rest.dropFirst(run).allSatisfy(\.isWhitespace)
    }

    /// `---`, `***` and the like, which read as their text rather than as list items.
    private static func isThematicBreak(_ characters: [Character]) -> Bool {
        guard let first = characters.first, "-*_".contains(first) else { return false }
        let marks = characters.filter { $0 != " " && $0 != "\t" }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }
}

// MARK: - Inline formatting

/// The formatting Markdown can give a stretch of text.
struct MarkdownMarks: Equatable {
    var bold = false
    var italic = false
    var struckThrough = false
    var code = false
    var link: URL?

    init(bold: Bool = false, italic: Bool = false, struckThrough: Bool = false, code: Bool = false, link: URL? = nil) {
        self.bold = bold
        self.italic = italic
        self.struckThrough = struckThrough
        self.code = code
        self.link = link
    }

    init(_ inline: Inline) {
        let style = inline.format.style
        self.init(
            bold: style.isBold == true, italic: style.isItalic == true, struckThrough: style.isStruckThrough == true,
            code: style.fontName == Markdown.codeFont, link: inline.hyperlink?.url
        )
    }

    var format: RunFormat {
        var style = RunStyle()
        if bold { style.isBold = true }
        if italic { style.isItalic = true }
        if struckThrough { style.isStruckThrough = true }
        if code { style.fontName = Markdown.codeFont }
        return RunFormat(style: style)
    }

    var hyperlink: Hyperlink? {
        link.map { Hyperlink(url: $0, attributesXML: "") }
    }
}

/// A stretch of text in one format.
struct MarkdownSpan: Equatable {
    var text: String
    var marks: MarkdownMarks
}

/// Reads the inline formatting of a block's text.
enum MarkdownInlineReader {
    static func inlines(_ text: String) -> [Inline] {
        spans(text).flatMap { span in
            PlainText.inlines(span.text, format: span.marks.format, hyperlink: span.marks.hyperlink)
        }
    }

    /// The text's spans, neighbours in the same format merged.
    static func spans(_ text: String) -> [MarkdownSpan] {
        var result: [MarkdownSpan] = []
        for span in spans(Array(text)) where !span.text.isEmpty {
            if result.last?.marks == span.marks {
                result[result.count - 1].text += span.text
            } else {
                result.append(span)
            }
        }
        return result
    }

    private struct Piece {
        var text: String
        var marks = MarkdownMarks()
        var delimiter: Delimiter?

        var resolvedText: String {
            delimiter.map { String(repeating: $0.character, count: $0.count) } ?? text
        }
    }

    /// A run of `*`, `_` or `~` that may open or close emphasis.
    private struct Delimiter {
        var character: Character
        var count: Int
        let length: Int
        var canOpen: Bool
        var canClose: Bool
    }

    private static func spans(_ characters: [Character]) -> [MarkdownSpan] {
        var pieces: [Piece] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { pieces.append(Piece(text: literal)) }
            literal = ""
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "\\", let next, next.isASCIIPunctuation {
                literal.append(next)
                index += 2
            } else if character == "`" {
                let run = runLength(of: characters, at: index)
                if let close = closingBackticks(in: characters, from: index + run, length: run) {
                    flush()
                    pieces.append(Piece(text: codeText(characters[(index + run)..<close]), marks: MarkdownMarks(code: true)))
                    index = close + run
                } else {
                    literal += String(repeating: "`", count: run)
                    index += run
                }
            } else if character == "!", next == "[", let link = link(in: characters, at: index + 1) {
                // Pictures cannot be shown, so they stay as they were written.
                literal += String(characters[index..<link.end])
                index = link.end
            } else if character == "[", let link = link(in: characters, at: index) {
                if let url = link.url {
                    flush()
                    for span in spans(link.text) {
                        var marks = span.marks
                        marks.link = url
                        pieces.append(Piece(text: span.text, marks: marks))
                    }
                } else {
                    literal += String(characters[index..<link.end])
                }
                index = link.end
            } else if character == "<", let end = tagEnd(in: characters, at: index) {
                literal += String(characters[index..<end])
                index = end
            } else if "*_~".contains(character) {
                let run = runLength(of: characters, at: index)
                guard character != "~" || run == 2 else {
                    literal += String(repeating: character, count: run)
                    index += run
                    continue
                }
                let before = index > 0 ? characters[index - 1] : " "
                let after = index + run < characters.count ? characters[index + run] : " "
                let leftFlanking = !after.isWhitespace
                    && (!after.isMarkdownPunctuation || before.isWhitespace || before.isMarkdownPunctuation)
                let rightFlanking = !before.isWhitespace
                    && (!before.isMarkdownPunctuation || after.isWhitespace || after.isMarkdownPunctuation)
                let isUnderscore = character == "_"
                flush()
                pieces.append(Piece(text: "", delimiter: Delimiter(
                    character: character, count: run, length: run,
                    canOpen: leftFlanking && (!isUnderscore || !rightFlanking || before.isMarkdownPunctuation),
                    canClose: rightFlanking && (!isUnderscore || !leftFlanking || after.isMarkdownPunctuation)
                )))
                index += run
            } else {
                literal.append(character)
                index += 1
            }
        }
        flush()
        resolveEmphasis(&pieces)
        return pieces.map { MarkdownSpan(text: $0.resolvedText, marks: $0.marks) }
    }

    /// Pairs openers with closers, as CommonMark does, and formats what lies between.
    private static func resolveEmphasis(_ pieces: inout [Piece]) {
        var closer = 0
        while closer < pieces.count {
            guard let closing = pieces[closer].delimiter, closing.canClose, closing.count > 0 else {
                closer += 1
                continue
            }
            let opener = pieces[..<closer].lastIndex { piece in
                guard let opening = piece.delimiter, opening.canOpen, opening.count > 0,
                      opening.character == closing.character else { return false }
                // A run that could both open and close only pairs with one
                // whose length does not make the two add to a multiple of three.
                let mixed = opening.canClose || closing.canOpen
                let sum = opening.length + closing.length
                return !(mixed && sum % 3 == 0 && !(opening.length % 3 == 0 && closing.length % 3 == 0))
            }
            guard let opener else {
                if !closing.canOpen { pieces[closer].delimiter?.canClose = false }
                closer += 1
                continue
            }
            let used = closing.character == "~" || min(closing.count, pieces[opener].delimiter!.count) >= 2 ? 2 : 1
            pieces[opener].delimiter!.count -= used
            pieces[closer].delimiter!.count -= used
            for inner in (opener + 1)..<closer {
                switch (closing.character, used) {
                case ("~", _): pieces[inner].marks.struckThrough = true
                case (_, 2): pieces[inner].marks.bold = true
                default: pieces[inner].marks.italic = true
                }
                // What lies inside can no longer pair with anything outside.
                pieces[inner].delimiter?.canOpen = false
                pieces[inner].delimiter?.canClose = false
            }
            if pieces[closer].delimiter!.count == 0 { closer += 1 }
        }
    }

    private static func runLength(of characters: [Character], at index: Int) -> Int {
        characters[index...].prefix { $0 == characters[index] }.count
    }

    private static func closingBackticks(in characters: [Character], from start: Int, length: Int) -> Int? {
        var index = start
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            let run = runLength(of: characters, at: index)
            if run == length { return index }
            index += run
        }
        return nil
    }

    private static func codeText(_ characters: ArraySlice<Character>) -> String {
        let text = String(characters)
        guard text.count >= 2, text.first == " ", text.last == " ", !text.allSatisfy({ $0 == " " }) else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// `[text](destination)` starting at `start`. The URL is `nil` for a link
    /// Libretto keeps as written: one with a title, or whose destination
    /// would not be written back the same.
    private static func link(in characters: [Character], at start: Int) -> (text: [Character], url: URL?, end: Int)? {
        var depth = 0
        var index = start
        var close: Int?
        while index < characters.count, close == nil {
            switch characters[index] {
            case "\\": index += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { close = index }
            default: break
            }
            index += 1
        }
        guard let close, close + 1 < characters.count, characters[close + 1] == "(" else { return nil }
        var end = close + 2
        var parentheses = 0
        while end < characters.count {
            let character = characters[end]
            if character == "\n" { return nil }
            if character == "\\" {
                end += 2
                continue
            }
            if character == "(" { parentheses += 1 }
            if character == ")" {
                if parentheses == 0 { break }
                parentheses -= 1
            }
            end += 1
        }
        guard end < characters.count else { return nil }
        let destination = String(characters[(close + 2)..<end])
        let url = destination.isEmpty || destination.contains(where: \.isWhitespace) ? nil
            : URL(string: destination).flatMap { $0.absoluteString == destination ? $0 : nil }
        return (Array(characters[(start + 1)..<close]), url, end + 1)
    }

    /// The end of an HTML tag or an autolink, which are kept as they were written.
    private static func tagEnd(in characters: [Character], at start: Int) -> Int? {
        guard start + 1 < characters.count,
              characters[start + 1].isASCII && characters[start + 1].isLetter || "/!?".contains(characters[start + 1])
        else { return nil }
        var index = start + 1
        while index < characters.count {
            if characters[index] == ">" { return index + 1 }
            if characters[index] == "<" { return nil }
            index += 1
        }
        return nil
    }
}

extension Character {
    var isASCIIPunctuation: Bool { isASCII && (isPunctuation || isSymbol) }
    fileprivate var isMarkdownPunctuation: Bool { isPunctuation || isSymbol }
}

// MARK: - Reading

enum MarkdownReader {
    static func document(from data: Data) -> WordDocument {
        document(from: PlainText.string(from: data))
    }

    static func document(from text: String) -> WordDocument {
        var document = WordDocument()
        var parser = Parser(numbering: document.numbering)
        parser.parse(text.components(separatedBy: "\n"))
        if !parser.blocks.isEmpty { document.body = parser.blocks.map(block(from:)) }
        document.numbering = parser.numbering
        return document
    }

    private static func block(from pending: Parser.Pending) -> Block {
        var properties = ParagraphProperties()
        switch pending.kind {
        case .paragraph:
            break
        case .heading(let level):
            properties.styleID = [ParagraphStyleChoice.heading1, .heading2, .heading3][min(level, 3) - 1].defaultID
        case .quote:
            properties.styleID = ParagraphStyleChoice.quote.defaultID
        case .item(let list):
            properties.list = list
        case .code:
            // Lines of code follow one another as closely as they do in the file.
            properties.spacingAfter = 0
            let format = MarkdownMarks(code: true).format
            return .paragraph(Paragraph(inlines: PlainText.inlines(pending.text, format: format), properties: properties))
        }
        return .paragraph(Paragraph(inlines: MarkdownInlineReader.inlines(pending.text), properties: properties))
    }

    /// Reads blocks line by line, still as their Markdown text.
    private struct Parser {
        enum Kind {
            case paragraph
            case heading(Int)
            case quote
            case item(ListReference)
            /// One line of a code block, kept exactly.
            case code
        }

        struct Pending {
            var kind: Kind
            var text: String
        }

        /// What the next line may carry on.
        private enum Open {
            case none
            case paragraph
            case quote
            case item
        }

        var numbering: NumberingDefinitions
        private(set) var blocks: [Pending] = []
        private var open = Open.none
        /// The columns each open list item's text starts at, outermost first.
        private var items: [Int] = []
        private var lists: [ListKind: Int] = [:]

        init(numbering: NumberingDefinitions) {
            self.numbering = numbering
        }

        mutating func parse(_ lines: [String]) {
            var index = 0
            var afterBlank = false
            while index < lines.count {
                let line = lines[index]
                index += 1
                if line.allSatisfy(\.isWhitespace) {
                    afterBlank = true
                    // A list item can go on after a gap, if what follows is indented to it.
                    if open != .item { open = .none }
                    continue
                }
                let wasAfterBlank = afterBlank
                afterBlank = false
                let indent = Markdown.indentation(of: line)
                let text = String(line.drop { $0 == " " || $0 == "\t" })

                if items.isEmpty, indent >= 4 {
                    if open != .none, !wasAfterBlank {
                        continueBlock(with: text)
                    } else {
                        // Indented code, up to the next line that is not.
                        var gap: [String] = []
                        blocks.append(Pending(kind: .code, text: line))
                        while index < lines.count {
                            let next = lines[index]
                            if next.allSatisfy(\.isWhitespace) {
                                gap.append(next)
                            } else if Markdown.indentation(of: next) >= 4 {
                                blocks += (gap + [next]).map { Pending(kind: .code, text: $0) }
                                gap = []
                            } else {
                                break
                            }
                            index += 1
                        }
                        afterBlank = !gap.isEmpty
                        open = .none
                    }
                    continue
                }

                switch Markdown.lineStart(line, maxIndent: (items.last ?? 0) + 3) {
                case .fence(let character, let length):
                    if let last = items.last, indent < last { endList() }
                    blocks.append(Pending(kind: .code, text: line))
                    while index < lines.count {
                        let next = lines[index]
                        index += 1
                        blocks.append(Pending(kind: .code, text: next))
                        if Markdown.closesFence(next, character: character, length: length) { break }
                    }
                    open = .none
                case .heading(let level, let heading):
                    endList()
                    blocks.append(Pending(kind: .heading(level), text: heading))
                    open = .none
                case .quote(let quote):
                    endList()
                    if quote.allSatisfy(\.isWhitespace) {
                        // An empty quoted line parts the paragraphs of a quote.
                        open = .none
                    } else if open == .quote, !wasAfterBlank {
                        blocks[blocks.count - 1].text += "\n" + quote
                    } else {
                        blocks.append(Pending(kind: .quote, text: quote))
                        open = .quote
                    }
                case .item(let kind, let itemIndent, let contentOffset, let item):
                    while let last = items.last, itemIndent < last { items.removeLast() }
                    let level = min(items.count, 8)
                    items.append(contentOffset)
                    let numberingID = lists[kind] ?? numbering.addList(kind)
                    lists[kind] = numberingID
                    blocks.append(Pending(kind: .item(ListReference(numberingID: numberingID, level: level)), text: item))
                    open = .item
                case nil:
                    if let last = items.last {
                        if case .item? = blocks.last?.kind, indent >= last || (open == .item && !wasAfterBlank) {
                            blocks[blocks.count - 1].text += "\n" + text
                            open = .item
                            continue
                        }
                        endList()
                    }
                    if open != .none, !wasAfterBlank {
                        continueBlock(with: text)
                    } else {
                        blocks.append(Pending(kind: .paragraph, text: text))
                        open = .paragraph
                    }
                }
            }
        }

        /// Adds a line to the paragraph or quote before it.
        private mutating func continueBlock(with text: String) {
            blocks[blocks.count - 1].text += "\n" + text
        }

        private mutating func endList() {
            items = []
            lists = [:]
            if open == .item { open = .none }
        }
    }
}

// MARK: - Writing

enum MarkdownWriter {
    static func data(from document: WordDocument) -> Data {
        Data(string(from: document).utf8)
    }

    private enum Kind: Equatable {
        case paragraph
        case heading
        case quote
        case item
        case code
        case table
    }

    static func string(from document: WordDocument) -> String {
        var output = ""
        var previous: Kind?
        /// Each list level's list, its count so far, and the column its items' text starts at.
        var lists: [Int] = []
        var counters: [Int] = []
        var offsets: [Int] = []

        for block in document.body {
            let entry: (kind: Kind, text: String)
            // Whether an item starts a list apart from the one before it.
            var startsList = false
            switch block {
            case .paragraph(let paragraph):
                let properties = paragraph.properties
                let list = properties.list.flatMap { list in
                    document.numbering.kind(of: list.numberingID).map { (reference: list, kind: $0) }
                }
                if isCode(paragraph) {
                    entry = (.code, paragraph.plainText)
                } else if let level = headingLevel(of: properties.styleID, in: document.styles) {
                    let spans = spans(of: paragraph.inlines).map { span in
                        MarkdownSpan(text: span.text.replacingOccurrences(of: "\n", with: " "), marks: span.marks)
                    }
                    entry = (.heading, String(repeating: "#", count: min(level, 6)) + " " + markdown(spans))
                } else if properties.styleID == ParagraphStyleChoice.quote.defaultID {
                    let lines = markdown(spans(of: paragraph.inlines)).components(separatedBy: "\n")
                    entry = (.quote, lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
                } else if let list {
                    let level = list.reference.level
                    let numberingID = list.reference.numberingID
                    if previous != .item {
                        lists = []
                        counters = []
                        offsets = []
                    }
                    let sameList = lists.indices.contains(level) && lists[level] == numberingID
                    startsList = level == 0 && !lists.isEmpty && !sameList
                    // Deeper levels count afresh, and so does this one when its list changes.
                    counters = Array(counters.prefix(sameList ? level + 1 : level))
                    counters += Array(repeating: 0, count: level + 1 - counters.count)
                    counters[level] += 1
                    lists = Array(lists.prefix(level))
                    lists += Array(repeating: numberingID, count: level + 1 - lists.count)
                    let marker = list.kind == .bulleted ? "-" : "\(counters[level])."
                    let indent = level == 0 ? 0 : offsets.prefix(level).last ?? 0
                    offsets = Array(offsets.prefix(level)) + [indent + marker.count + 1]
                    let lines = blockLines(markdown(spans(of: paragraph.inlines)))
                    let first = String(repeating: " ", count: indent) + marker + (lines.first.map { " " + $0 } ?? "")
                    let rest = lines.dropFirst().map { String(repeating: " ", count: indent + marker.count + 1) + $0 }
                    entry = (.item, ([first] + rest).joined(separator: "\n"))
                } else {
                    let lines = blockLines(markdown(spans(of: paragraph.inlines)))
                    guard !lines.isEmpty else { continue }
                    entry = (.paragraph, lines.joined(separator: "\n"))
                }
            case .table(let table):
                entry = (.table, self.table(table))
            case .preserved(let preserved):
                let lines = blockLines(markdown([MarkdownSpan(text: preserved.displayText, marks: MarkdownMarks())]))
                guard !lines.isEmpty else { continue }
                entry = (.paragraph, lines.joined(separator: "\n"))
            }

            if let previous {
                switch (previous, entry.kind) {
                case (.item, .item): output += startsList ? "\n\n" : "\n"
                case (.code, .code): output += "\n"
                case (.quote, .quote): output += "\n>\n"
                default: output += "\n\n"
                }
            }
            output += entry.text
            previous = entry.kind
        }
        return output.isEmpty ? "" : output + "\n"
    }

    /// Whether a paragraph is a line of a code block: all code, set close.
    private static func isCode(_ paragraph: Paragraph) -> Bool {
        let properties = paragraph.properties
        guard properties.spacingAfter == 0, properties.styleID == nil, properties.list == nil else { return false }
        return paragraph.inlines.allSatisfy { inline in
            guard case .text = inline.content else { return true }
            return inline.format.style.fontName == Markdown.codeFont
        }
    }

    private static func headingLevel(of styleID: String?, in styles: StyleSheet) -> Int? {
        if styleID == ParagraphStyleChoice.title.defaultID { return 1 }
        return styles.headingLevel(ofStyle: styleID)
    }

    /// The lines of a block's text, each made safe to stand at the start of a
    /// line without reading as the start of some other block.
    private static func blockLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            let trimmed = String(line.drop { $0 == " " || $0 == "\t" })
            guard !trimmed.isEmpty else { return nil }
            guard Markdown.lineStart(trimmed) != nil else { return trimmed }
            // Escape the list number's full stop, or else the first character.
            let digits = trimmed.prefix { $0.isASCII && $0.isNumber }.count
            let index = trimmed.index(trimmed.startIndex, offsetBy: digits)
            return String(trimmed[..<index]) + "\\" + String(trimmed[index...])
        }
    }

    private static func table(_ table: Table) -> String {
        let rows = table.rows.map { row in
            "| " + row.cells.map { cell in
                cell.plainText.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
            }.joined(separator: " | ") + " |"
        }
        guard let header = rows.first else { return "" }
        let separator = "|" + String(repeating: " --- |", count: max(1, table.rows[0].cells.count))
        return ([header, separator] + rows.dropFirst()).joined(separator: "\n")
    }

    // MARK: Inline formatting

    static func spans(of inlines: [Inline]) -> [MarkdownSpan] {
        var result: [MarkdownSpan] = []
        for inline in inlines {
            let text: String
            switch inline.content {
            case .text(let string): text = string
            case .tab: text = "\t"
            case .lineBreak: text = "\n"
            case .runChild(_, let display), .paragraphChild(_, let display): text = display ?? ""
            case .pageBreak, .image, .note: text = ""
            }
            guard !text.isEmpty else { continue }
            let marks = MarkdownMarks(inline)
            if result.last?.marks == marks {
                result[result.count - 1].text += text
            } else {
                result.append(MarkdownSpan(text: text, marks: marks))
            }
        }
        return result
    }

    private enum Escaping {
        /// Only what the text would otherwise lose, so text written as
        /// Markdown is saved back as it was written.
        case minimal
        /// Every character that could mark anything up.
        case full
    }

    /// The spans as Markdown: written as plainly as reads back the same,
    /// or failing that, with every mark escaped, or at the last, without
    /// the formatting that could not be written.
    static func markdown(_ spans: [MarkdownSpan]) -> String {
        let expected = signature(spans)
        for escaping in [Escaping.minimal, .full] {
            let candidate = markdown(spans, escaping: escaping, formatted: true)
            if signature(MarkdownInlineReader.spans(candidate)) == expected { return candidate }
        }
        return markdown(spans, escaping: .full, formatted: false)
    }

    /// Each character with its formatting, ignoring emphasis on whitespace,
    /// which Markdown cannot always place.
    private static func signature(_ spans: [MarkdownSpan]) -> [MarkdownSpan] {
        spans.flatMap { span in
            span.text.map { character in
                var marks = span.marks
                if character.isWhitespace && !marks.code {
                    marks.bold = false
                    marks.italic = false
                    marks.struckThrough = false
                }
                return MarkdownSpan(text: String(character), marks: marks)
            }
        }
    }

    private static func markdown(_ spans: [MarkdownSpan], escaping: Escaping, formatted: Bool) -> String {
        var output = ""
        var index = 0
        while index < spans.count {
            let link = formatted ? spans[index].marks.link : nil
            let end = spans[index...].firstIndex { (formatted ? $0.marks.link : nil) != link } ?? spans.count
            let text = emphasized(Array(spans[index..<end]), escaping: escaping, formatted: formatted)
            output += link.map { "[\(text)](\($0.absoluteString))" } ?? text
            index = end
        }
        return output
    }

    private static func emphasized(_ spans: [MarkdownSpan], escaping: Escaping, formatted: Bool) -> String {
        let markers: [(WritableKeyPath<MarkdownMarks, Bool>, String)] = [
            (\.struckThrough, "~~"), (\.bold, "**"), (\.italic, "*"),
        ]
        var output = ""
        var open: [String] = []
        // Whitespace held back, to go after any markers that close before it.
        var pending = ""
        var previous = MarkdownMarks()

        for span in spans {
            var marks = formatted ? span.marks : MarkdownMarks()
            if !marks.code, span.text.allSatisfy(\.isWhitespace) {
                // Whitespace takes on the emphasis around it, saving a needless close and reopen.
                for (keyPath, _) in markers { marks[keyPath: keyPath] = previous[keyPath: keyPath] }
            }
            previous = marks
            let wanted = markers.filter { marks[keyPath: $0.0] }.map(\.1)
            let kept = zip(open, wanted).prefix { $0 == $1 }.count

            var text = Substring(span.text)
            if kept < open.count || kept < wanted.count {
                output += open[kept...].reversed().joined()
                open.removeSubrange(kept...)
                output += pending
                pending = ""
                // Markers only open on text, so whitespace goes before them.
                if !marks.code {
                    let leading = text.prefix(while: \.isWhitespace)
                    output += leading
                    text = text.dropFirst(leading.count)
                }
                output += wanted[kept...].joined()
                open += wanted[kept...]
            } else {
                output += pending
                pending = ""
            }

            if marks.code {
                output += codeSpan(String(text))
            } else {
                let trailing = text.reversed().prefix(while: \.isWhitespace).count
                output += escaped(text.dropLast(trailing), escaping)
                pending = String(text.suffix(trailing))
            }
        }
        return output + open.reversed().joined() + pending
    }

    private static func escaped(_ text: Substring, _ escaping: Escaping) -> String {
        var output = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            switch escaping {
            case .minimal:
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if character == "\\", next?.isASCIIPunctuation == true { output += "\\" }
            case .full:
                if "\\`*_[]~<".contains(character) { output += "\\" }
            }
            output.append(character)
        }
        return output
    }

    private static func codeSpan(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let padded = text.first == "`" || text.last == "`"
            || (text.first == " " && text.last == " " && !text.allSatisfy { $0 == " " })
        return padded ? "\(fence) \(text) \(fence)" : fence + text + fence
    }
}
