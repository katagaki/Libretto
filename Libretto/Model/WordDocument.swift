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
    /// Plain text of the default header and footer, drawn in the page margins.
    var header: HeaderFooterText?
    var footer: HeaderFooterText?
    /// Body-level elements after the last block, before the section properties.
    var trailingXML: [String] = []
    /// The original package, part by part, for writing back what is not modelled.
    var package: DocumentPackage
    var unsupportedFeatures: UnsupportedFeatureReport

    /// Whether the file carries a VBA project. Libretto keeps it but never runs it.
    var hasMacros: Bool { package.parts.keys.contains { $0.lowercased().hasSuffix("vbaproject.bin") } }

    init(
        body: [Block], pageSetup: PageSetup, styles: StyleSheet, numbering: NumberingDefinitions,
        header: HeaderFooterText? = nil, footer: HeaderFooterText? = nil,
        package: DocumentPackage, unsupportedFeatures: UnsupportedFeatureReport = UnsupportedFeatureReport()
    ) {
        self.body = body
        self.pageSetup = pageSetup
        self.styles = styles
        self.numbering = numbering
        self.header = header
        self.footer = footer
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

    /// Overlays `other`'s set values onto these, as a style inherits.
    func merged(with other: ParagraphProperties) -> ParagraphProperties {
        ParagraphProperties(
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
            outlineLevel: other.outlineLevel ?? outlineLevel
        )
    }
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

    init(_ content: InlineContent, format: RunFormat = RunFormat(), hyperlink: Hyperlink? = nil) {
        self.content = content
        self.format = format
        self.hyperlink = hyperlink
    }

    var plainText: String {
        switch content {
        case .text(let text): return text
        case .tab: return "\t"
        case .lineBreak: return "\n"
        case .pageBreak: return ""
        case .image: return ""
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
            allCaps: other.allCaps ?? allCaps
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

/// A header or footer, reduced to the text it shows. `{PAGE}` stands for the
/// page number field, which is filled in per page.
struct HeaderFooterText: Equatable, Sendable {
    var text: String
    var alignment: ParagraphAlignment = .leading

    static let pageNumberPlaceholder = "{PAGE}"
    static let pageCountPlaceholder = "{NUMPAGES}"

    func resolved(page: Int, of count: Int) -> String {
        text.replacingOccurrences(of: Self.pageNumberPlaceholder, with: String(page))
            .replacingOccurrences(of: Self.pageCountPlaceholder, with: String(count))
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
        var index = relationships.count + addedMedia.count + 1
        while relationships["rId\(index)"] != nil || addedMedia["rId\(index)"] != nil { index += 1 }
        return "rId\(index)"
    }
}
