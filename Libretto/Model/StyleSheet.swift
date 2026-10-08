import Foundation

/// The document's style definitions, from `word/styles.xml`.
struct StyleSheet: Equatable, Sendable {
    var styles: [String: Style] = [:]
    var defaultParagraphProperties = ParagraphProperties()
    var defaultRunStyle = RunStyle()
    /// The paragraph style a paragraph with no `w:pStyle` uses, usually "Normal".
    var defaultParagraphStyleID: String?
    var defaultCharacterStyleID: String?
    /// The body and heading fonts the theme names, which runs refer to by role.
    var minorFont: String?
    var majorFont: String?
    /// Built-in styles Libretto added because the document used one it did
    /// not define, to be written into the styles part on save.
    var added: [ParagraphStyleChoice] = []

    struct Style: Equatable, Sendable {
        var id: String
        var name: String
        var kind: Kind
        var basedOn: String?
        var next: String?
        var paragraphProperties = ParagraphProperties()
        var runStyle = RunStyle()
        /// Whether the table style draws borders.
        var hasTableBorders = false
        /// Six-digit RGB of the table style's borders.
        var tableBorderColorHex: String?
        /// A table style's formatting for parts of the table, by `w:tblStylePr`
        /// type, with what the style says of the whole table as `wholeTable`.
        var tableConditions: [TableCondition.Kind: TableCondition] = [:]
        /// `w:qFormat`: offered among the quick styles. `w:semiHidden`: not offered at all.
        var isQuick = false
        var isHidden = false
        /// The style's properties as read, and their elements, so a changed
        /// style has only what changed patched. `nil` for a style made in Libretto.
        var originalParagraphProperties: ParagraphProperties?
        var originalRunStyle: RunStyle?
        var paragraphPropertiesXML: String?
        var runPropertiesXML: String?
        /// Made in Libretto, to be added to the styles part on save.
        var isCreated = false

        /// Whether it differs from the definition it was read with.
        var isModified: Bool {
            !isCreated && (paragraphProperties != (originalParagraphProperties ?? ParagraphProperties())
                || runStyle != (originalRunStyle ?? RunStyle()))
        }

        enum Kind: String, Sendable {
            case paragraph, character, table, numbering
        }
    }

    // MARK: - Resolution

    /// Paragraph properties a paragraph ends up with: document defaults, then
    /// its style and everything that style is based on, then its own.
    func resolvedParagraphProperties(_ direct: ParagraphProperties) -> ParagraphProperties {
        var result = defaultParagraphProperties
        for style in chain(from: direct.styleID ?? defaultParagraphStyleID) {
            result = result.merged(with: style.paragraphProperties)
        }
        return result.merged(with: direct)
    }

    /// Character formatting a run ends up with, in the same order Word
    /// applies it: defaults, paragraph style, character style, direct.
    func resolvedRunStyle(_ direct: RunStyle, paragraphStyleID: String?) -> RunStyle {
        var result = defaultRunStyle
        for style in chain(from: paragraphStyleID ?? defaultParagraphStyleID) {
            result = result.merged(with: style.runStyle)
        }
        for style in chain(from: direct.characterStyleID ?? defaultCharacterStyleID) {
            result = result.merged(with: style.runStyle)
        }
        var own = direct
        own.characterStyleID = nil
        return result.merged(with: own)
    }

    /// A style and its ancestors, root first.
    private func chain(from id: String?) -> [Style] {
        var result: [Style] = []
        var seen: Set<String> = []
        var current = id
        while let key = current, !seen.contains(key), let style = styles[key] {
            seen.insert(key)
            result.insert(style, at: 0)
            current = style.basedOn
        }
        return result
    }

    func tableHasBorders(styleID: String?) -> Bool {
        chain(from: styleID).contains { $0.hasTableBorders }
    }

    func tableBorderColor(styleID: String?) -> String? {
        chain(from: styleID).reversed().lazy.compactMap(\.tableBorderColorHex).first
    }

    /// A table style's conditional formatting, with what a style inherits
    /// from the one it is based on.
    func tableConditions(styleID: String?) -> [TableCondition.Kind: TableCondition] {
        var result: [TableCondition.Kind: TableCondition] = [:]
        for style in chain(from: styleID) {
            for (kind, condition) in style.tableConditions {
                result[kind] = result[kind].map { $0.merged(with: condition) } ?? condition
            }
        }
        return result
    }

    // MARK: - Choosing styles

    /// The heading level a paragraph style stands for, if it is a heading.
    func headingLevel(ofStyle id: String?) -> Int? {
        guard let id else { return nil }
        let resolved = resolvedParagraphProperties(ParagraphProperties(styleID: id))
        if let level = resolved.outlineLevel, level < 9 { return level + 1 }
        let name = (styles[id]?.name ?? id).lowercased()
        guard name.hasPrefix("heading") else { return nil }
        return Int(String(name.dropFirst("heading".count)).trimmed)
    }

    /// The style ID for one of the paragraph styles the style menu offers,
    /// matched by Word's built-in names, which do not change with the language
    /// Word runs in, whatever the file chose to call the IDs.
    func styleID(for choice: ParagraphStyleChoice) -> String? {
        let wanted = choice.builtInName.lowercased()
        if let match = styles.values.first(where: { $0.kind == .paragraph && $0.name.lowercased() == wanted }) {
            return match.id
        }
        let compact = wanted.replacingOccurrences(of: " ", with: "")
        return styles.values.first { $0.kind == .paragraph && $0.id.lowercased() == compact }?.id
    }

    /// The style ID for a menu choice, adding the built-in definition first
    /// if the document has none.
    mutating func ensureStyle(_ choice: ParagraphStyleChoice) -> String {
        if let existing = styleID(for: choice) { return existing }
        var id = choice.defaultID
        while styles[id] != nil { id += "1" }
        guard var style = BuiltInStyles.style(for: choice) else { return id }
        style.id = id
        if style.basedOn.map({ styles[$0] == nil }) ?? false {
            style.basedOn = defaultParagraphStyleID
        }
        styles[id] = style
        added.append(choice)
        return id
    }

    /// Paragraph styles to offer: the quick styles, those the document uses,
    /// and those made in Libretto, by name.
    func offeredParagraphStyles(using used: Set<String>) -> [Style] {
        styles.values.filter { style in
            style.kind == .paragraph && !style.isHidden && (style.isQuick || used.contains(style.id) || style.isCreated)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A new paragraph style, returning its ID: one made from its name, unlike any other.
    mutating func createParagraphStyle(
        name: String, basedOn: String?, paragraph: ParagraphProperties, run: RunStyle
    ) -> String {
        let stem = name.filter { $0.isLetter || $0.isNumber }
        var id = stem.isEmpty ? "Style" : stem
        var number = 1
        while styles[id] != nil {
            number += 1
            id = (stem.isEmpty ? "Style" : stem) + String(number)
        }
        var properties = paragraph
        properties.styleID = nil
        var runStyle = run
        runStyle.characterStyleID = nil
        var style = Style(id: id, name: name, kind: .paragraph, basedOn: basedOn, next: nil)
        style.paragraphProperties = properties
        style.runStyle = runStyle
        style.isQuick = true
        style.isCreated = true
        styles[id] = style
        return id
    }

    /// Which of the menu's styles a paragraph is in.
    func choice(forStyle id: String?) -> ParagraphStyleChoice? {
        let resolvedID = id ?? defaultParagraphStyleID
        return ParagraphStyleChoice.allCases.first { styleID(for: $0) == resolvedID }
    }
}

/// The paragraph styles the style menu offers. Every document Word makes can
/// use these, and Libretto adds their definitions to any that lacks one.
enum ParagraphStyleChoice: String, CaseIterable, Identifiable, Sendable {
    case title
    case subtitle
    case heading1
    case heading2
    case heading3
    case body
    case quote

    var id: String { rawValue }

    var builtInName: String {
        switch self {
        case .title: return "Title"
        case .subtitle: return "Subtitle"
        case .heading1: return "heading 1"
        case .heading2: return "heading 2"
        case .heading3: return "heading 3"
        case .body: return "Normal"
        case .quote: return "Quote"
        }
    }

    /// The ID Libretto gives the style when it has to add it.
    var defaultID: String {
        switch self {
        case .title: return "Title"
        case .subtitle: return "Subtitle"
        case .heading1: return "Heading1"
        case .heading2: return "Heading2"
        case .heading3: return "Heading3"
        case .body: return "Normal"
        case .quote: return "Quote"
        }
    }

    var label: String {
        switch self {
        case .title: return String(localized: "Style.Title")
        case .subtitle: return String(localized: "Style.Subtitle")
        case .heading1: return String(localized: "Style.Heading1")
        case .heading2: return String(localized: "Style.Heading2")
        case .heading3: return String(localized: "Style.Heading3")
        case .body: return String(localized: "Style.Body")
        case .quote: return String(localized: "Style.Quote")
        }
    }
}

// MARK: - Table styles

/// What a table style does to one part of a table: its header row, its
/// banded rows, its first column and so on.
struct TableCondition: Equatable, Sendable {
    var runStyle = RunStyle()
    var paragraphProperties = ParagraphProperties()
    /// Six-digit RGB cell shading.
    var fillHex: String?

    /// `w:tblStylePr` types, in the order Word applies them, each over the
    /// ones before it.
    enum Kind: String, CaseIterable, Sendable {
        case wholeTable
        case band1Vert, band2Vert, band1Horz, band2Horz
        case firstCol, lastCol, firstRow, lastRow
        case neCell, nwCell, seCell, swCell
    }

    func merged(with other: TableCondition) -> TableCondition {
        TableCondition(
            runStyle: runStyle.merged(with: other.runStyle),
            paragraphProperties: paragraphProperties.merged(with: other.paragraphProperties),
            fillHex: other.fillHex ?? fillHex
        )
    }
}

/// Which of its style's conditional formats a table turns on, from `w:tblLook`.
struct TableLook: Equatable, Sendable {
    var firstRow = true
    var lastRow = false
    var firstColumn = true
    var lastColumn = false
    var bandedRows = true
    var bandedColumns = false
}

// MARK: - Numbering

/// List definitions, from `word/numbering.xml`.
struct NumberingDefinitions: Equatable, Sendable {
    /// `w:num` instances: numbering ID to the abstract definition it uses.
    var instances: [Int: Int] = [:]
    var abstracts: [Int: [Int: ListLevel]] = [:]
    /// Where an instance starts its levels over, from `w:lvlOverride/w:startOverride`:
    /// numbering ID to level to the number it starts at.
    var overrides: [Int: [Int: Int]] = [:]
    /// Lists Libretto created, to be added to the numbering part on save.
    var added: [AddedList] = []

    struct ListLevel: Equatable, Sendable {
        var format: String
        /// `%1.` and the like.
        var text: String
        var start = 1
        /// Twips.
        var indentLeft: Int?
        var hanging: Int?
    }

    struct AddedList: Equatable, Sendable {
        var numberingID: Int
        var abstractID: Int
        var kind: ListKind
        /// Whether the abstract definition is new too, rather than one this
        /// instance numbers afresh.
        var isNewDefinition = true
    }

    func level(_ level: Int, of numberingID: Int) -> ListLevel? {
        guard let abstract = instances[numberingID] else { return nil }
        return abstracts[abstract]?[level]
    }

    func kind(of numberingID: Int) -> ListKind? {
        guard let level = level(0, of: numberingID) else { return nil }
        return level.format == "bullet" ? .bulleted : .numbered
    }

    /// A list of `kind` to put paragraphs in: one Libretto already made, or a new one.
    mutating func numberingID(for kind: ListKind) -> Int {
        if let existing = added.first(where: { $0.kind == kind }) { return existing.numberingID }
        return addList(kind)
    }

    /// A new list of `kind`, numbered from its own start.
    mutating func addList(_ kind: ListKind) -> Int {
        addList(levels: Self.levels(for: kind), kind: kind)
    }

    /// A new list with its own definition.
    mutating func addList(levels: [Int: ListLevel], kind: ListKind) -> Int {
        let numberingID = (instances.keys.max() ?? 0) + 1
        let abstractID = (abstracts.keys.max() ?? -1) + 1
        instances[numberingID] = abstractID
        abstracts[abstractID] = levels
        added.append(AddedList(numberingID: numberingID, abstractID: abstractID, kind: kind))
        return numberingID
    }

    /// A new instance of an existing list's definition, starting `level` over at `start`.
    mutating func restartList(_ numberingID: Int, level: Int, at start: Int) -> Int? {
        guard let abstractID = instances[numberingID], let kind = kind(of: numberingID) else { return nil }
        let restarted = (instances.keys.max() ?? 0) + 1
        instances[restarted] = abstractID
        overrides[restarted] = [level: start]
        added.append(AddedList(numberingID: restarted, abstractID: abstractID, kind: kind, isNewDefinition: false))
        return restarted
    }

    static func levels(for kind: ListKind) -> [Int: ListLevel] {
        let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        let formats = ["decimal", "lowerLetter", "lowerRoman"]
        return Dictionary(uniqueKeysWithValues: (0..<9).map { level in
            let left = 720 * (level + 1)
            switch kind {
            case .bulleted:
                return (level, ListLevel(
                    format: "bullet", text: bullets[level % bullets.count], indentLeft: left, hanging: 360
                ))
            case .numbered:
                return (level, ListLevel(
                    format: formats[level % formats.count], text: "%\(level + 1).", indentLeft: left, hanging: 360
                ))
            }
        })
    }
}

enum ListKind: String, Sendable {
    case bulleted
    case numbered
}

// MARK: - Unsupported features

/// What an opened file uses that Libretto shows or keeps, but cannot edit.
struct UnsupportedFeatureReport: Equatable, Sendable {
    var features: Set<Feature> = []

    enum Feature: String, CaseIterable, Sendable {
        case macros
        case trackedChanges
        case comments
        case footnotes
        case shapes
        case equations
        case contentControls
        case sections
        case embeddedObjects

        var label: String {
            switch self {
            case .macros: return String(localized: "Unsupported.Macros")
            case .trackedChanges: return String(localized: "Unsupported.TrackedChanges")
            case .comments: return String(localized: "Unsupported.Comments")
            case .footnotes: return String(localized: "Unsupported.Footnotes")
            case .shapes: return String(localized: "Unsupported.Shapes")
            case .equations: return String(localized: "Unsupported.Equations")
            case .contentControls: return String(localized: "Unsupported.ContentControls")
            case .sections: return String(localized: "Unsupported.Sections")
            case .embeddedObjects: return String(localized: "Unsupported.EmbeddedObjects")
            }
        }
    }

    var isEmpty: Bool { features.isEmpty }

    mutating func insert(_ feature: Feature) {
        features.insert(feature)
    }

    var orderedFeatures: [Feature] {
        Feature.allCases.filter(features.contains)
    }
}
