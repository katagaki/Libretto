import Foundation

/// An entire word-processing document, as Libretto models it.
///
/// Only the parts Libretto can edit are modelled: paragraphs, their runs of
/// text, tables, inline pictures and the page setup. Everything else in the
/// file is carried as the XML it arrived as, either in place (inside the
/// paragraph or run it belongs to) or as a whole package part, so saving a
/// document writes back what Libretto did not touch byte for byte.
struct WordDocument: Equatable, Sendable {
    var body: [Block]
    var pageSetup: PageSetup
    /// Style definitions, read once from `word/styles.xml`. Libretto applies
    /// styles but does not edit their definitions.
    var styles: StyleSheet
    var numbering: NumberingDefinitions
    /// The header and footer parts, by the relationship ID sections refer to
    /// them by, reduced to their text and drawn in the page margins.
    var headerFooters: [String: HeaderFooterText] = [:]
    /// Whether even pages have headers and footers of their own, from the
    /// settings part, and whether they did when the file was read.
    var evenAndOddHeaders = false
    var originalEvenAndOddHeaders = false
    /// The comments, in the order the comments part lists them, and the IDs
    /// it had when read, to tell what was added and taken away.
    var comments: [Comment] = []
    var originalComments: [Comment] = []
    /// Whether changes are recorded as tracked changes, from the settings
    /// part's `w:trackRevisions`, and whether they were when the file was read.
    var trackRevisions = false
    var originalTrackRevisions = false
    /// Footnotes and endnotes, from their parts, separators left out; and as read.
    var notes: [Note] = []
    var originalNotes: [Note] = []
    /// How footnotes and endnotes are numbered, from the settings' `w:footnotePr` and `w:endnotePr`.
    var footnoteFormat = "decimal"
    var endnoteFormat = "lowerRoman"
    /// Body-level elements after the last block, before the section properties.
    var trailingXML: [String] = []
    /// The original package, part by part, for writing back what is not modelled.
    var package: DocumentPackage
    var unsupportedFeatures: UnsupportedFeatureReport
    /// The language of the source file the document was read from, whose
    /// syntax its text is coloured by. `nil` for anything that is not code.
    var sourceLanguage: SourceLanguage?

    /// Whether the file carries a VBA project. Libretto keeps it but never runs it.
    var hasMacros: Bool { package.parts.keys.contains { $0.lowercased().hasSuffix("vbaproject.bin") } }

    init(
        body: [Block], pageSetup: PageSetup, styles: StyleSheet, numbering: NumberingDefinitions,
        headerFooters: [String: HeaderFooterText] = [:],
        package: DocumentPackage, unsupportedFeatures: UnsupportedFeatureReport = UnsupportedFeatureReport()
    ) {
        self.body = body
        self.pageSetup = pageSetup
        self.styles = styles
        self.numbering = numbering
        self.headerFooters = headerFooters
        self.package = package
        self.unsupportedFeatures = unsupportedFeatures
    }

    /// A new, empty document on the default page.
    init() {
        // The template is ours and always readable.
        // swiftlint:disable:next force_try
        self = try! DOCXReader.document(fromParts: DOCXTemplate.blankPackage())
    }

    /// Every paragraph in reading order, descending into table cells.
    var allParagraphs: [Paragraph] {
        body.flatMap(\.paragraphs)
    }

    /// The document's words, for the word count.
    var wordCount: Int {
        allParagraphs.reduce(0) { total, paragraph in
            var count = 0
            paragraph.plainText.enumerateSubstrings(
                in: paragraph.plainText.startIndex..., options: [.byWords, .substringNotRequired]
            ) { _, _, _, _ in count += 1 }
            return total + count
        }
    }

    /// The default header and footer of the last section.
    var header: HeaderFooterText? { headerFooter(.default, isFooter: false, in: pageSetup) }
    var footer: HeaderFooterText? { headerFooter(.default, isFooter: true, in: pageSetup) }

    func headerFooter(_ kind: HeaderFooterKind, isFooter: Bool, in setup: PageSetup) -> HeaderFooterText? {
        let references = isFooter ? setup.headerFooters.footers : setup.headerFooters.headers
        return references[kind].flatMap { headerFooters[$0] }
    }

    /// Which header or footer a page shows: the first page's, if the section
    /// has one of its own, an even page's, if the document does, or the default.
    func headerFooterKind(forPage index: Int, in setup: PageSetup) -> HeaderFooterKind {
        if index == 0, setup.headerFooters.titlePage { return .first }
        if evenAndOddHeaders, index % 2 == 1 { return .even }
        return .default
    }

    /// A relationship ID for a new header or footer part.
    func unusedHeaderFooterID(isFooter: Bool) -> String {
        let stem = isFooter ? "rIdLibrettoFooter" : "rIdLibrettoHeader"
        var index = 1
        while headerFooters["\(stem)\(index)"] != nil || package.relationships["\(stem)\(index)"] != nil { index += 1 }
        return "\(stem)\(index)"
    }

    func block(withID id: Block.ID) -> Block? {
        body.first { $0.id == id }
    }

    mutating func replaceBlock(_ block: Block) {
        guard let index = body.firstIndex(where: { $0.id == block.id }) else { return }
        body[index] = block
    }
}

// MARK: - Blocks

/// One body-level element: a paragraph, a table, or something Libretto keeps
/// but does not edit, such as a content control holding a table of contents.
enum Block: Equatable, Sendable, Identifiable {
    case paragraph(Paragraph)
    case table(Table)
    case preserved(PreservedBlock)

    var id: UUID {
        switch self {
        case .paragraph(let paragraph): return paragraph.id
        case .table(let table): return table.id
        case .preserved(let block): return block.id
        }
    }

    var paragraphs: [Paragraph] {
        switch self {
        case .paragraph(let paragraph): return [paragraph]
        case .table(let table): return table.rows.flatMap { $0.cells.flatMap { $0.blocks.flatMap(\.paragraphs) } }
        case .preserved: return []
        }
    }

    var leadingXML: [String] {
        switch self {
        case .paragraph(let paragraph): return paragraph.leadingXML
        case .table(let table): return table.leadingXML
        case .preserved(let block): return block.leadingXML
        }
    }
}

/// A body-level element kept exactly as it was read.
struct PreservedBlock: Equatable, Sendable, Identifiable {
    var id = UUID()
    var xml: String
    /// What it reads as, shown in place of the element itself.
    var displayText: String
    var kind: Kind
    var leadingXML: [String] = []

    enum Kind: String, Sendable {
        case contentControl
        case other
    }
}

// MARK: - Paragraphs

struct Paragraph: Equatable, Sendable, Identifiable {
    var id = UUID()
    var inlines: [Inline] = []
    var properties = ParagraphProperties()
    /// The properties as read, so an untouched paragraph's `w:pPr` is written
    /// back verbatim and a touched one only has the changed parts patched.
    var originalProperties: ParagraphProperties?
    var preservedPropertiesXML: String?
    /// Body-level elements such as bookmarks that came just before this paragraph.
    var leadingXML: [String] = []
    /// The `w:p` element's own attributes as the file spelled them, such as
    /// the paragraph IDs comments are anchored by.
    var attributesXML = ""
    /// The paragraph exactly as read, with the content it was read as. While
    /// the content still matches, the paragraph is written back verbatim.
    var originalXML: String?
    var originalInlines: [Inline]?
    /// A tracked insertion or deletion of the paragraph's mark, from its
    /// `w:pPr/w:rPr`, and what it was when read.
    var markRevision: Revision?
    var originalMarkRevision: Revision?

    init(
        id: UUID = UUID(), inlines: [Inline] = [], properties: ParagraphProperties = ParagraphProperties(),
        originalProperties: ParagraphProperties? = nil, preservedPropertiesXML: String? = nil,
        leadingXML: [String] = []
    ) {
        self.id = id
        self.inlines = inlines
        self.properties = properties
        self.originalProperties = originalProperties
        self.preservedPropertiesXML = preservedPropertiesXML
        self.leadingXML = leadingXML
    }

    /// A plain paragraph of text.
    init(text: String, styleID: String? = nil) {
        self.init(
            inlines: text.isEmpty ? [] : [Inline(.text(text))],
            properties: ParagraphProperties(styleID: styleID)
        )
    }

    var plainText: String {
        inlines.map(\.plainText).joined()
    }

    /// The paragraph that results from splitting this one: the same
    /// properties, but none of what belongs to the paragraph mark alone, such
    /// as a section break, which must stay with exactly one of the halves.
    func splitCopy() -> Paragraph {
        var copy = self
        copy.id = UUID()
        copy.leadingXML = []
        copy.originalXML = nil
        copy.originalInlines = nil
        copy.originalMarkRevision = nil
        // Paragraph IDs must be unique; Word assigns the copy fresh ones.
        copy.attributesXML = DOCXPatcher.removingParagraphIDs(fromAttributes: attributesXML)
        copy.preservedPropertiesXML = preservedPropertiesXML.flatMap { DOCXPatcher.removingSectionBreak(fromPPr: $0) }
        return copy
    }
}

struct ParagraphProperties: Equatable, Hashable, Sendable {
    var styleID: String?
    var alignment: ParagraphAlignment?
    var list: ListReference?
    /// Twentieths of a point, as OOXML measures them.
    var spacingBefore: Int?
    var spacingAfter: Int?
    var lineSpacing: LineSpacing?
    var indentLeft: Int?
    var indentRight: Int?
    /// Positive for a first-line indent, negative for a hanging one.
    var indentFirstLine: Int?
    var pageBreakBefore: Bool?
    var outlineLevel: Int?
    var keepNext: Bool?
    var keepLines: Bool?
    var widowControl: Bool?
    /// Six-digit RGB behind the paragraph.
    var shadingHex: String?
    var borders: ParagraphBorders?
    /// Tab stops, in twips from the margin; a style's are added to, or cleared by, a paragraph's own.
    var tabStops: [TabStop]?
    /// A large initial letter, from `w:framePr`'s drop cap: dropped into the text or set in the margin.
    var dropCap: DropCap?

    /// Overlays `other`'s set values onto these, as a style inherits.
    func merged(with other: ParagraphProperties) -> ParagraphProperties {
        var result = ParagraphProperties(
            styleID: other.styleID ?? styleID,
            alignment: other.alignment ?? alignment,
            list: other.list ?? list,
            spacingBefore: other.spacingBefore ?? spacingBefore,
            spacingAfter: other.spacingAfter ?? spacingAfter,
            lineSpacing: other.lineSpacing ?? lineSpacing,
            indentLeft: other.indentLeft ?? indentLeft,
            indentRight: other.indentRight ?? indentRight,
            indentFirstLine: other.indentFirstLine ?? indentFirstLine,
            pageBreakBefore: other.pageBreakBefore ?? pageBreakBefore,
            outlineLevel: other.outlineLevel ?? outlineLevel,
            keepNext: other.keepNext ?? keepNext,
            keepLines: other.keepLines ?? keepLines,
            widowControl: other.widowControl ?? widowControl,
            shadingHex: other.shadingHex ?? shadingHex,
            borders: other.borders ?? borders,
            tabStops: tabStops,
            dropCap: other.dropCap ?? dropCap
        )
        if let added = other.tabStops {
            var stops = tabStops ?? []
            for stop in added {
                stops.removeAll { $0.position == stop.position }
                if stop.alignment != .clear { stops.append(stop) }
            }
            result.tabStops = stops.sorted { $0.position < $1.position }
        }
        return result
    }
}

/// A paragraph's borders, side by side, and the one between it and a like paragraph.
struct ParagraphBorders: Equatable, Hashable, Sendable {
    var top: BorderLine?
    var left: BorderLine?
    var bottom: BorderLine?
    var right: BorderLine?
    var between: BorderLine?

    var isEmpty: Bool { top == nil && left == nil && bottom == nil && right == nil && between == nil }
}

/// One border line, as `w:top` and its siblings spell it.
struct BorderLine: Equatable, Hashable, Sendable {
    /// `w:val`: `single`, `double`, `dotted`, `dashed`, `thick` and the rest.
    var style = "single"
    /// Eighths of a point.
    var size = 4
    /// Six-digit RGB, or `nil` for automatic.
    var colorHex: String?
    /// Points between the line and the text.
    var space = 1
}

struct TabStop: Equatable, Hashable, Sendable {
    enum Alignment: String, CaseIterable, Sendable {
        case left, center, right, decimal, bar, clear

        /// Reads `w:tab`'s `w:val`, which also spells left and right as start and end.
        init?(ooxml value: String) {
            switch value {
            case "left", "start", "num": self = .left
            case "right", "end": self = .right
            default: self.init(rawValue: value)
            }
        }
    }

    /// Twips from the margin.
    var position: Int
    var alignment: Alignment = .left
    /// `w:leader`: `dot`, `hyphen`, `underscore`, `middleDot`, or `nil` for none.
    var leader: String?
}

struct DropCap: Equatable, Hashable, Sendable {
    /// `drop` sets the letter in the text; `margin`, beside it.
    var inMargin = false
    /// How many lines tall the letter is.
    var lines = 3
}

enum ParagraphAlignment: String, CaseIterable, Sendable {
    case leading = "left"
    case center
    case trailing = "right"
    case justified = "both"

    /// Reads `w:jc`, which also spells the leading and trailing edges as start and end.
    init?(ooxml value: String) {
        switch value {
        case "left", "start": self = .leading
        case "center": self = .center
        case "right", "end": self = .trailing
        case "both", "distribute", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute":
            self = .justified
        default: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        case .justified: return "text.justify"
        }
    }

    var label: String {
        switch self {
        case .leading: return String(localized: "Alignment.Left")
        case .center: return String(localized: "Alignment.Center")
        case .trailing: return String(localized: "Alignment.Right")
        case .justified: return String(localized: "Alignment.Justified")
        }
    }
}

struct LineSpacing: Equatable, Hashable, Sendable {
    enum Rule: String, Sendable {
        /// `line` is in 240ths of a line.
        case auto
        /// `line` is in twentieths of a point.
        case exact
        case atLeast
    }

    var line: Int
    var rule: Rule

    /// The multiple of single spacing, for automatic spacing.
    var multiple: Double? { rule == .auto ? Double(line) / 240 : nil }
}

struct ListReference: Equatable, Hashable, Sendable {
    /// `w:numId`; zero means "no list", which a paragraph uses to opt out of
    /// a list its style would otherwise put it in.
    var numberingID: Int
    var level: Int
}

// MARK: - Inlines

/// One piece of a paragraph's content, with the run formatting it carries.
struct Inline: Equatable, Sendable {
    var content: InlineContent
    var format = RunFormat()
    var hyperlink: Hyperlink?
    /// The tracked change it is part of, if any.
    var revision: Revision?

    init(
        _ content: InlineContent, format: RunFormat = RunFormat(), hyperlink: Hyperlink? = nil,
        revision: Revision? = nil
    ) {
        self.content = content
        self.format = format
        self.hyperlink = hyperlink
        self.revision = revision
    }

    var plainText: String {
        switch content {
        case .text(let text): return text
        case .tab: return "\t"
        case .lineBreak: return "\n"
        case .pageBreak: return ""
        case .image, .note: return ""
        case .runChild(_, let display), .paragraphChild(_, let display): return display ?? ""
        }
    }
}

enum InlineContent: Equatable, Sendable {
    case text(String)
    case tab
    case lineBreak
    case pageBreak
    case image(InlineImage)
    /// A child of `w:r` Libretto keeps as it is: a field character, a
    /// footnote reference. `display` is what it reads as, if anything; `nil`
    /// means it takes no room in the text at all.
    case runChild(xml: String, display: String?)
    /// A child of `w:p` that is not a run: a bookmark, a tracked change, an
    /// equation. Written back outside any run.
    case paragraphChild(xml: String, display: String?)
    /// A footnote or endnote's reference, shown as the note's number.
    case note(NoteReference)

    /// Whether this takes no room in the text, so it rides along on the
    /// character after it rather than standing in the text itself.
    var isMarker: Bool {
        switch self {
        case .runChild(_, let display), .paragraphChild(_, let display):
            return display?.isEmpty ?? true
        default:
            return false
        }
    }
}

/// A picture in the flow of text.
struct InlineImage: Equatable, Sendable {
    /// The relationship naming the image part.
    var relationshipID: String
    /// Points.
    var width: Double
    var height: Double
    /// The `w:drawing` element, written back as it was. `nil` for a picture
    /// inserted in Libretto, whose drawing is generated.
    var xml: String?
    /// Floating pictures are shown in line, which is the nearest a reflowing
    /// view can come to where they sit on the page.
    var isFloating = false
}

/// A tracked change: an insertion or deletion of text, or of a paragraph
/// mark, as `w:ins`, `w:del`, `w:moveTo` or `w:moveFrom` record it.
struct Revision: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case insertion = "ins"
        case deletion = "del"
        case moveTo
        case moveFrom

        /// Whether accepting it keeps the text, as for an insertion.
        var adds: Bool { self == .insertion || self == .moveTo }
    }

    var kind: Kind
    var author: String?
    /// As the file spells it, ISO 8601.
    var date: String?
    /// The element's attributes as the file spelled them, `w:id` among them;
    /// empty for a change made in Libretto, which is given an ID when written.
    var attributesXML = ""
}

/// A hyperlink wrapping some of a paragraph's runs.
struct Hyperlink: Equatable, Hashable, Sendable {
    var relationshipID: String?
    var anchor: String?
    /// The resolved address, for opening in the mobile view.
    var url: URL?
    /// The element's attributes as the file spelled them.
    var attributesXML: String
}

/// The formatting of a run: what Libretto edits, plus what it keeps.
struct RunFormat: Equatable, Hashable, Sendable {
    var style = RunStyle()
    var original: RunStyle?
    var preservedPropertiesXML: String?

    init(style: RunStyle = RunStyle(), original: RunStyle? = nil, preservedPropertiesXML: String? = nil) {
        self.style = style
        self.original = original
        self.preservedPropertiesXML = preservedPropertiesXML
    }
}

/// Character formatting Libretto understands. `nil` means "inherit".
struct RunStyle: Equatable, Hashable, Sendable {
    var characterStyleID: String?
    var fontName: String?
    /// Half-points, as `w:sz` measures them.
    var fontSize: Int?
    var isBold: Bool?
    var isItalic: Bool?
    var underline: Bool?
    var isStruckThrough: Bool?
    /// Six-digit RGB.
    var colorHex: String?
    /// A `w:highlight` colour name.
    var highlight: String?
    var verticalAlignment: VerticalPosition?
    var allCaps: Bool?
    /// `w:u`'s kind, when it is not a single line: `double`, `thick`,
    /// `dotted`, `dash`, `wave`, `words` and the rest.
    var underlineStyle: String?
    var isDoubleStruckThrough: Bool?
    var smallCaps: Bool?
    /// Twentieths of a point added between characters, or taken away.
    var characterSpacing: Int?
    /// Half-points the text is raised, or lowered.
    var position: Int?
    var outline: Bool?
    var shadow: Bool?
    var emboss: Bool?
    /// Engraved, as Word calls it.
    var imprint: Bool?

    enum VerticalPosition: String, Sendable {
        case superscript
        case `subscript`
        case baseline
    }

    func merged(with other: RunStyle) -> RunStyle {
        RunStyle(
            characterStyleID: other.characterStyleID ?? characterStyleID,
            fontName: other.fontName ?? fontName,
            fontSize: other.fontSize ?? fontSize,
            isBold: other.isBold ?? isBold,
            isItalic: other.isItalic ?? isItalic,
            underline: other.underline ?? underline,
            isStruckThrough: other.isStruckThrough ?? isStruckThrough,
            colorHex: other.colorHex ?? colorHex,
            highlight: other.highlight ?? highlight,
            verticalAlignment: other.verticalAlignment ?? verticalAlignment,
            allCaps: other.allCaps ?? allCaps,
            underlineStyle: other.underline != nil ? other.underlineStyle : underlineStyle,
            isDoubleStruckThrough: other.isDoubleStruckThrough ?? isDoubleStruckThrough,
            smallCaps: other.smallCaps ?? smallCaps,
            characterSpacing: other.characterSpacing ?? characterSpacing,
            position: other.position ?? position,
            outline: other.outline ?? outline,
            shadow: other.shadow ?? shadow,
            emboss: other.emboss ?? emboss,
            imprint: other.imprint ?? imprint
        )
    }
}

// MARK: - Tables

struct Table: Equatable, Sendable, Identifiable {
    var id = UUID()
    var rows: [TableRow]
    /// Column widths in twips, from `w:tblGrid`.
    var gridColumns: [Int]
    var preservedPropertiesXML: String?
    var styleID: String?
    /// Whether the table draws its own borders, rather than relying on
    /// gridlines that only show on screen.
    var hasBorders: Bool
    /// Six-digit RGB, if the borders have a colour of their own.
    var borderColorHex: String?
    var look = TableLook()
    var leadingXML: [String] = []
    /// The table exactly as read, written back verbatim while its rows and
    /// columns are as they were.
    var originalXML: String?
    var originalRows: [TableRow]?
    var originalGrid: [Int]?

    var isUnchanged: Bool { originalXML != nil && originalRows == rows && originalGrid == gridColumns }

    var columnCount: Int {
        max(gridColumns.count, rows.map { $0.cells.reduce(0) { $0 + $1.gridSpan } }.max() ?? 0)
    }
}

struct TableRow: Equatable, Sendable, Identifiable {
    var id = UUID()
    var cells: [TableCell]
    /// `w:tblPrEx`: table properties this row overrides.
    var exceptionsXML: String?
    var preservedPropertiesXML: String?
    var isHeader = false
}

struct TableCell: Equatable, Sendable, Identifiable {
    var id = UUID()
    var blocks: [Block]
    var preservedPropertiesXML: String?
    var gridSpan = 1
    var verticalMerge: VerticalMerge?
    /// Six-digit RGB background.
    var shadingHex: String?

    enum VerticalMerge: Sendable {
        case restart
        case `continue`
    }

    var plainText: String {
        blocks.flatMap(\.paragraphs).map(\.plainText).joined(separator: "\n")
    }
}

// MARK: - Page setup

/// The page size and margins of the document's last section, which is the one
/// Libretto lays every page out with.
struct PageSetup: Equatable, Sendable {
    /// Twips.
    var width = 11906
    var height = 16838
    var marginTop = 1440
    var marginBottom = 1440
    var marginLeft = 1440
    var marginRight = 1440
    var headerDistance = 708
    var footerDistance = 708
    /// Which header and footer parts the section shows, and whether its first page has its own.
    var headerFooters = HeaderFooterReferences()
    var originalHeaderFooters: HeaderFooterReferences?
    var preservedXML: String?
    var original: PageSetupValues?

    var isLandscape: Bool { width > height }

    struct PageSetupValues: Equatable, Sendable {
        var width, height, marginTop, marginBottom, marginLeft, marginRight: Int
    }

    var values: PageSetupValues {
        PageSetupValues(
            width: width, height: height, marginTop: marginTop, marginBottom: marginBottom,
            marginLeft: marginLeft, marginRight: marginRight
        )
    }

    /// Points, the unit the page view lays out in.
    var size: CGSize { CGSize(width: Double(width) / 20, height: Double(height) / 20) }
    var contentWidth: Double { Double(width - marginLeft - marginRight) / 20 }
    var contentHeight: Double { Double(height - marginTop - marginBottom) / 20 }
}

/// The header and footer parts a section shows on each kind of page, by relationship ID.
struct HeaderFooterReferences: Equatable, Sendable {
    var headers: [HeaderFooterKind: String] = [:]
    var footers: [HeaderFooterKind: String] = [:]
    /// `w:titlePg`: the first page has a header and footer of its own.
    var titlePage = false
}

/// `w:headerReference`'s and `w:footerReference`'s types.
enum HeaderFooterKind: String, CaseIterable, Sendable {
    case `default`
    case first
    case even
}

/// A header or footer, reduced to the text it shows. `{PAGE}` stands for the
/// page number field, which is filled in per page.
struct HeaderFooterText: Equatable, Sendable {
    var text: String
    var alignment: ParagraphAlignment = .leading
    var isFooter = false
    /// The part's first paragraph's and first run's properties, kept when the
    /// text is written afresh, so it keeps its style and font.
    var paragraphPropertiesXML: String?
    var runPropertiesXML: String?
    /// Whether the part holds more than its text, such as a picture or a
    /// table, which writing the text afresh does not keep.
    var hasRichContent = false
    /// Changed in Libretto, so its part is written afresh from the text.
    var isEdited = false

    static let pageNumberPlaceholder = "{PAGE}"
    static let pageCountPlaceholder = "{NUMPAGES}"

    func resolved(page: Int, of count: Int) -> String {
        text.replacingOccurrences(of: Self.pageNumberPlaceholder, with: String(page))
            .replacingOccurrences(of: Self.pageCountPlaceholder, with: String(count))
    }
}

// MARK: - Notes

enum NoteKind: String, CaseIterable, Sendable {
    case footnote
    case endnote
}

/// Where a note is referred to: `w:footnoteReference` or `w:endnoteReference`.
struct NoteReference: Equatable, Hashable, Sendable {
    var kind: NoteKind
    var id: String
    /// The reference element as read, or as made.
    var xml: String

    init(kind: NoteKind, id: String, xml: String? = nil) {
        self.kind = kind
        self.id = id
        self.xml = xml ?? "<w:\(kind.rawValue)Reference w:id=\"\(XMLLite.escape(id))\"/>"
    }
}

/// A footnote or endnote, reduced to its text.
struct Note: Equatable, Sendable, Identifiable {
    var kind: NoteKind
    /// `w:id`, which the reference carries.
    var id: String
    var text: String
    /// The note's first paragraph's and first run's properties, kept when the text is written afresh.
    var paragraphPropertiesXML: String?
    var runPropertiesXML: String?
    /// The `w:footnote` or `w:endnote` as read, written back while the text is unchanged.
    var originalXML: String?
    var originalText: String?

    var key: String { "\(kind.rawValue):\(id)" }
}

extension WordDocument {
    /// A note ID of `kind` not yet in use.
    func unusedNoteID(_ kind: NoteKind) -> String {
        String(max(0, notes.filter { $0.kind == kind }.compactMap { Int($0.id) }.max() ?? 0) + 1)
    }
}

/// Numbers notes as Word does: footnotes and endnotes each counted from one,
/// in the order the text refers to them.
enum NoteNumbering {
    /// The references in reading order, tables' among them.
    static func references(in blocks: [Block]) -> [NoteReference] {
        blocks.flatMap { block -> [NoteReference] in
            switch block {
            case .paragraph(let paragraph):
                return paragraph.inlines.compactMap { if case .note(let reference) = $0.content { return reference } else { return nil } }
            case .table(let table):
                return table.rows.flatMap { $0.cells.flatMap { references(in: $0.blocks) } }
            case .preserved:
                return []
            }
        }
    }

    /// Each reference's number, by `kind:id`, in the document's formats.
    static func numbers(in document: WordDocument) -> [String: String] {
        var counts: [NoteKind: Int] = [:]
        var result: [String: String] = [:]
        for reference in references(in: document.body) {
            let key = "\(reference.kind.rawValue):\(reference.id)"
            guard result[key] == nil else { continue }
            counts[reference.kind, default: 0] += 1
            let format = reference.kind == .footnote ? document.footnoteFormat : document.endnoteFormat
            result[key] = ListLabeler.format(counts[reference.kind]!, as: format)
        }
        return result
    }
}

// MARK: - Comments

/// A comment, from the comments part, with its resolved state and the
/// comment it replies to, from Word's comments extensions.
struct Comment: Equatable, Sendable, Identifiable {
    /// `w:id`, which the comment's range and reference in the body carry.
    var id: String
    var author: String
    var initials: String?
    /// As the file spells it, ISO 8601.
    var date: String?
    /// The comment's paragraphs, a line each.
    var text: String
    /// The `w14:paraId` of the comment's last paragraph, which resolving
    /// and replying refer to.
    var paraID: String?
    var isDone = false
    /// The `paraID` of the comment this one replies to.
    var parentParaID: String?
    /// The `w:comment` element as read, written back while the text is unchanged.
    var originalXML: String?
    var originalText: String?

    var dateValue: Date? {
        date.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

extension WordDocument {
    /// A comment ID not yet in use.
    func unusedCommentID() -> String {
        String((comments.compactMap { Int($0.id) }.max() ?? -1) + 1)
    }

    /// A paragraph ID for a new comment's paragraph: eight hex digits, below
    /// 0x80000000 as Word requires, and unlike any the comments use.
    func unusedCommentParaID() -> String {
        let used = Set(comments.compactMap(\.paraID))
        while true {
            let candidate = String(format: "%08X", UInt32.random(in: 0x1000_0000..<0x7FFF_FFFF))
            if !used.contains(candidate) { return candidate }
        }
    }
}

// MARK: - Package

/// The parts of the original file, keyed by their path in the ZIP.
struct DocumentPackage: Equatable, Sendable {
    var parts: [String: Data]
    /// The main document part, usually `word/document.xml`.
    var documentPath: String
    /// The main part's relationships, by ID.
    var relationships: [String: Relationship]
    /// The main part's root element's attributes, namespace declarations
    /// included, so the rewritten part keeps them all.
    var rootAttributesXML: String
    var namespaces: [String: String]
    /// Pictures added in Libretto, by relationship ID, still to be written as parts.
    var addedMedia: [String: AddedMedia] = [:]
    /// Addresses of links made in Libretto, by relationship ID, still to be
    /// written as relationships.
    var addedLinks: [String: String] = [:]

    struct Relationship: Equatable, Sendable {
        var type: String
        var target: String
        var isExternal: Bool
    }

    struct AddedMedia: Equatable, Sendable {
        var path: String
        var data: Data
        var fileExtension: String
        var contentType: String
    }

    /// The bytes of the part a relationship of the main part points at.
    func data(forRelationship id: String) -> Data? {
        if let added = addedMedia[id] { return added.data }
        guard let relationship = relationships[id], !relationship.isExternal else { return nil }
        return parts[DOCXPaths.resolve(relationship.target, relativeTo: documentPath)]
    }

    /// A relationship ID not yet in use.
    func unusedRelationshipID() -> String {
        var index = relationships.count + addedMedia.count + addedLinks.count + 1
        while relationships["rId\(index)"] != nil || addedMedia["rId\(index)"] != nil
            || addedLinks["rId\(index)"] != nil { index += 1 }
        return "rId\(index)"
    }
}
