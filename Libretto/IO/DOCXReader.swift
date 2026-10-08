import Foundation

/// Reads a `.docx` (or `.docm`) package into a `WordDocument`.
enum DOCXReader {
    static func document(from data: Data) throws -> WordDocument {
        try document(fromParts: ZipArchive.entries(in: data))
    }

    static func document(fromParts parts: [String: Data]) throws -> WordDocument {
        let packageRelationships = relationships(at: "_rels/.rels", in: parts)
        let documentPath = packageRelationships.values
            .first { $0.type == OOXML.officeDocumentType || $0.type.hasSuffix("/officeDocument") }
            .map { DOCXPaths.resolve($0.target, relativeTo: "") } ?? "word/document.xml"
        guard let documentData = parts[documentPath] else { throw DOCXError.missingMainDocument }

        let relationships = relationships(at: DOCXPaths.relationshipsPath(for: documentPath), in: parts)
        func part(ofType type: String) -> Data? {
            relationships.values.first { $0.type == type && !$0.isExternal }
                .flatMap { parts[DOCXPaths.resolve($0.target, relativeTo: documentPath)] }
        }

        var styles = part(ofType: OOXML.stylesType).flatMap { try? XMLLite.parse($0) }
            .map(StyleReader.styleSheet(from:)) ?? StyleSheet()
        if let theme = part(ofType: OOXML.themeType).flatMap({ try? XMLLite.parse($0) }) {
            styles.majorFont = theme.firstDescendant(atPath: "themeElements/fontScheme/majorFont/latin")?
                .attribute("typeface")
            styles.minorFont = theme.firstDescendant(atPath: "themeElements/fontScheme/minorFont/latin")?
                .attribute("typeface")
        }
        let numbering = part(ofType: OOXML.numberingType).flatMap { try? XMLLite.parse($0) }
            .map(StyleReader.numbering(from:)) ?? NumberingDefinitions()

        let root = try XMLLite.parse(documentData)
        let bodies = root.children(named: "body")
        guard !bodies.isEmpty else { throw DOCXError.missingBody }

        let context = ReadContext(
            namespaces: root.namespaceDeclarations, relationships: relationships, styles: styles
        )
        // Some writers split the body in two. Rather than lose what the
        // later ones hold, Libretto reads them as one, ending with the last
        // one's section; it writes back the single body the format allows.
        var children = bodies.flatMap(\.children)
        let finalSection = children.last?.name == "sectPr" ? children.removeLast() : nil
        var (blocks, trailing) = context.blocks(from: children)

        var pageSetup = finalSection.map(PageSetupReader.pageSetup(from:)) ?? PageSetup()
        pageSetup.preservedXML = finalSection.flatMap { context.serialize($0) }
        pageSetup.original = pageSetup.values

        // The body ends with a paragraph, which Word adds after a closing
        // table or content control, and the editor needs as well.
        if case .paragraph = blocks.last {} else { blocks.append(.paragraph(Paragraph())) }

        var report = context.report
        if parts.keys.contains(where: { $0.lowercased().hasSuffix("vbaproject.bin") }) { report.insert(.macros) }


        // Every header and footer a section refers to, by relationship.
        var headerFooters: [String: HeaderFooterText] = [:]
        for (id, isFooter) in pageSetup.headerFooters.headers.values.map({ ($0, false) })
            + pageSetup.headerFooters.footers.values.map({ ($0, true) }) where headerFooters[id] == nil {
            guard let relationship = relationships[id],
                  let data = parts[DOCXPaths.resolve(relationship.target, relativeTo: documentPath)],
                  let xml = try? XMLLite.parse(data) else { continue }
            var text = HeaderFooterReader.text(from: xml)
            text.isFooter = isFooter
            headerFooters[id] = text
        }
        let settings = part(ofType: OOXML.settingsType).flatMap { try? XMLLite.parse($0) }
        let evenAndOdd = PropertyReader.isOn(settings?.firstChild(named: "evenAndOddHeaders")) ?? false
        let tracksRevisions = PropertyReader.isOn(settings?.firstChild(named: "trackRevisions")) ?? false

        var document = WordDocument(
            body: blocks, pageSetup: pageSetup, styles: styles, numbering: numbering,
            headerFooters: headerFooters,
            package: DocumentPackage(
                parts: parts, documentPath: documentPath, relationships: relationships,
                rootAttributesXML: root.qualifiedAttributes.sorted { $0.key < $1.key }
                    .map { " \($0.key)=\"\(XMLLite.escape($0.value))\"" }.joined(),
                namespaces: root.namespaceDeclarations
            ),
            unsupportedFeatures: report
        )
        document.trailingXML = trailing
        document.trackRevisions = tracksRevisions
        document.originalTrackRevisions = tracksRevisions
        document.evenAndOddHeaders = evenAndOdd
        document.originalEvenAndOddHeaders = evenAndOdd
        for kind in NoteKind.allCases {
            guard let root = part(ofType: OOXML.notesType(kind)).flatMap({ try? XMLLite.parse($0) }) else { continue }
            document.notes += NoteReader.notes(from: root, kind: kind)
        }
        document.originalNotes = document.notes
        if let format = settings?.firstDescendant(atPath: "footnotePr/numFmt")?.attribute("val") {
            document.footnoteFormat = format
        }
        if let format = settings?.firstDescendant(atPath: "endnotePr/numFmt")?.attribute("val") {
            document.endnoteFormat = format
        }
        if let comments = part(ofType: OOXML.commentsType).flatMap({ try? XMLLite.parse($0) }) {
            let extended = part(ofType: OOXML.commentsExtendedType).flatMap { try? XMLLite.parse($0) }
            document.comments = CommentReader.comments(from: comments, extended: extended)
            document.originalComments = document.comments
        }
        return document
    }

    static func relationships(at path: String, in parts: [String: Data]) -> [String: DocumentPackage.Relationship] {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return [:] }
        var result: [String: DocumentPackage.Relationship] = [:]
        for element in root.children(named: "Relationship") {
            guard let id = element.attribute("Id"), let target = element.attribute("Target") else { continue }
            result[id] = DocumentPackage.Relationship(
                type: element.attribute("Type") ?? "", target: target,
                isExternal: element.attribute("TargetMode") == "External"
            )
        }
        return result
    }
}

// MARK: - Body

/// What reading the body needs to hand around, and what it learns on the way.
private final class ReadContext {
    let namespaces: [String: String]
    let relationships: [String: DocumentPackage.Relationship]
    let styles: StyleSheet
    var report = UnsupportedFeatureReport()

    init(namespaces: [String: String], relationships: [String: DocumentPackage.Relationship], styles: StyleSheet) {
        self.namespaces = namespaces
        self.relationships = relationships
        self.styles = styles
    }

    func serialize(_ element: XMLElement) -> String? {
        XMLLite.serialize(element, inheritedNamespaces: namespaces)
    }

    /// Reads body-level (or cell-level) content. Elements that are not blocks
    /// in their own right, such as bookmarks between paragraphs, ride along
    /// with the block after them; any left at the end are returned separately.
    func blocks(from elements: [XMLElement]) -> (blocks: [Block], trailing: [String]) {
        var blocks: [Block] = []
        var pending: [String] = []
        for element in elements {
            switch element.name {
            case "p":
                var paragraph = paragraph(from: element)
                paragraph.leadingXML = pending
                pending = []
                blocks.append(.paragraph(paragraph))
            case "tbl" where Self.isEditableTable(element):
                var table = table(from: element)
                table.leadingXML = pending
                pending = []
                blocks.append(.table(table))
            case "tbl":
                // Rows inside content controls, tracked row changes and the
                // like: kept whole and shown, rather than rebuilt without them.
                guard let xml = serialize(element) else { continue }
                let text = element.children.filter { $0.name != "tblPr" && $0.name != "tblGrid" }
                    .map { HeaderFooterReader.plainText(of: $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
                blocks.append(.preserved(PreservedBlock(xml: xml, displayText: text, kind: .other, leadingXML: pending)))
                pending = []
            case "sdt":
                report.insert(.contentControls)
                guard let xml = serialize(element) else { continue }
                let text = element.firstChild(named: "sdtContent").map { content in
                    content.children.map { HeaderFooterReader.plainText(of: $0) }
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                } ?? ""
                blocks.append(.preserved(PreservedBlock(
                    xml: xml, displayText: text, kind: .contentControl, leadingXML: pending
                )))
                pending = []
            case "sectPr":
                continue
            default:
                if let xml = serialize(element) { pending.append(xml) }
            }
        }
        return (blocks, pending)
    }

    // MARK: Paragraphs

    func paragraph(from element: XMLElement) -> Paragraph {
        var paragraph = Paragraph()
        paragraph.attributesXML = element.qualifiedAttributes.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(XMLLite.escape($0.value))\"" }.joined()
        if let pPr = element.firstChild(named: "pPr") {
            paragraph.properties = PropertyReader.paragraphProperties(from: pPr)
            paragraph.originalProperties = paragraph.properties
            paragraph.preservedPropertiesXML = serialize(pPr)
            if pPr.firstChild(named: "sectPr") != nil { report.insert(.sections) }
            if let mark = pPr.firstChild(named: "rPr")?.children
                .first(where: { Revision.Kind(rawValue: $0.name) != nil }) {
                paragraph.markRevision = revision(from: mark)
                paragraph.originalMarkRevision = paragraph.markRevision
            }
        }

        var inlines: [Inline] = []
        for child in element.children {
            inlines += self.inlines(from: child, hyperlink: nil, revision: nil)
        }
        paragraph.inlines = InlineNormalizer.normalized(inlines)
        paragraph.originalInlines = paragraph.inlines
        paragraph.originalXML = serialize(element)
        return paragraph
    }

    private func inlines(from child: XMLElement, hyperlink: Hyperlink?, revision: Revision?) -> [Inline] {
        switch child.name {
        case "pPr":
            return []
        case "r":
            return run(from: child, hyperlink: hyperlink, revision: revision)
        case "hyperlink" where hyperlink == nil:
            let link = self.hyperlink(from: child)
            return child.children.flatMap { inlines(from: $0, hyperlink: link, revision: revision) }
        case "bookmarkStart", "bookmarkEnd", "proofErr", "permStart", "permEnd",
             "commentRangeStart", "commentRangeEnd":
            return marker(child, hyperlink: hyperlink, revision: revision)
        case "ins", "moveTo", "del", "moveFrom" where revision == nil:
            // A tracked change's runs are content like any other, marked as the change.
            let change = self.revision(from: child)
            return child.children.flatMap { inlines(from: $0, hyperlink: hyperlink, revision: change) }
        case "oMath", "oMathPara":
            report.insert(.equations)
            return token(child, display: HeaderFooterReader.plainText(of: child), hyperlink: hyperlink, revision: revision)
        case "sdt":
            report.insert(.contentControls)
            return token(child, display: HeaderFooterReader.plainText(of: child), hyperlink: hyperlink, revision: revision)
        default:
            // fldSimple, smartTag, customXml and the like: kept whole, shown as their text.
            return token(child, display: HeaderFooterReader.plainText(of: child), hyperlink: hyperlink, revision: revision)
        }
    }

    private func revision(from element: XMLElement) -> Revision {
        Revision(
            kind: Revision.Kind(rawValue: element.name) ?? .insertion, author: element.attribute("author"),
            date: element.attribute("date"),
            attributesXML: element.qualifiedAttributes.filter { !$0.key.hasPrefix("xmlns") }
                .sorted { $0.key < $1.key }
                .map { " \($0.key)=\"\(XMLLite.escape($0.value))\"" }.joined()
        )
    }

    private func marker(_ element: XMLElement, hyperlink: Hyperlink?, revision: Revision?) -> [Inline] {
        guard let xml = serialize(element) else { return [] }
        return [Inline(.paragraphChild(xml: xml, display: nil), hyperlink: hyperlink, revision: revision)]
    }

    private func token(_ element: XMLElement, display: String?, hyperlink: Hyperlink?, revision: Revision?) -> [Inline] {
        guard let xml = serialize(element) else { return [] }
        let firstRun = firstDescendant(named: "r", in: element)
        let format = firstRun.flatMap { $0.firstChild(named: "rPr") }.map(runFormat) ?? RunFormat()
        // Shown within its paragraph, so its own line breaks must not end it.
        let shown = display.flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "\n", with: "\u{2028}") }
        return [Inline(.paragraphChild(xml: xml, display: shown), format: format, hyperlink: hyperlink, revision: revision)]
    }

    private func hyperlink(from element: XMLElement) -> Hyperlink {
        let id = element.attribute("id")
        let url = id.flatMap { relationships[$0] }.flatMap { $0.isExternal ? URL(string: $0.target) : nil }
        return Hyperlink(
            relationshipID: id, anchor: element.attribute("anchor"), url: url,
            attributesXML: element.qualifiedAttributes.sorted { $0.key < $1.key }
                .map { " \($0.key)=\"\(XMLLite.escape($0.value))\"" }.joined()
        )
    }

    private func runFormat(_ rPr: XMLElement) -> RunFormat {
        let style = PropertyReader.runStyle(from: rPr)
        return RunFormat(style: style, original: style, preservedPropertiesXML: serialize(rPr))
    }

    private func run(from element: XMLElement, hyperlink: Hyperlink?, revision: Revision?) -> [Inline] {
        let format = element.firstChild(named: "rPr").map(runFormat) ?? RunFormat()
        var result: [Inline] = []
        func add(_ content: InlineContent) {
            result.append(Inline(content, format: format, hyperlink: hyperlink, revision: revision))
        }
        func keep(_ child: XMLElement, display: String?) {
            guard let xml = serialize(child) else { return }
            add(.runChild(xml: xml, display: display))
        }

        for child in element.children {
            switch child.name {
            case "rPr", "lastRenderedPageBreak":
                continue
            case "t", "delText":
                if !child.text.isEmpty { add(.text(child.text)) }
            case "tab":
                add(.tab)
            case "br":
                add(child.attribute("type") == "page" ? .pageBreak : .lineBreak)
            case "cr":
                add(.lineBreak)
            case "noBreakHyphen":
                add(.text("\u{2011}"))
            case "softHyphen":
                add(.text("\u{00AD}"))
            case "sym":
                let code = child.attribute("char").flatMap { UInt32($0, radix: 16) } ?? 0x25A1
                let scalar = UnicodeScalar(code >= 0xF000 ? code - 0xF000 : code) ?? "\u{25A1}"
                keep(child, display: String(Character(scalar)))
            case "drawing":
                if let image = image(from: child) {
                    add(.image(image))
                } else {
                    report.insert(.shapes)
                    keep(child, display: "\u{25A2}")
                }
            case "AlternateContent":
                // Usually a shape with a picture of itself as the fallback.
                report.insert(.shapes)
                keep(child, display: "\u{25A2}")
            case "pict", "object":
                report.insert(child.name == "object" ? .embeddedObjects : .shapes)
                keep(child, display: "\u{25A2}")
            case "footnoteReference", "endnoteReference":
                guard let id = child.attribute("id"), let xml = serialize(child) else {
                    keep(child, display: nil)
                    continue
                }
                add(.note(NoteReference(kind: child.name == "footnoteReference" ? .footnote : .endnote, id: id, xml: xml)))
            case "commentReference":
                keep(child, display: nil)
            default:
                // Field characters, field codes and other things that take no room.
                keep(child, display: nil)
            }
        }
        return result
    }

    private func image(from drawing: XMLElement) -> InlineImage? {
        guard let container = drawing.children.first(where: { $0.name == "inline" || $0.name == "anchor" }),
              firstDescendant(named: "txbx", in: container) == nil,
              let blip = firstDescendant(named: "blip", in: container),
              let id = blip.attribute("embed") else { return nil }
        let extent = container.firstChild(named: "extent")
        let width = Double(extent?.attribute("cx") ?? "") ?? 0
        let height = Double(extent?.attribute("cy") ?? "") ?? 0
        guard width > 0, height > 0 else { return nil }
        return InlineImage(
            relationshipID: id, width: width / 12_700, height: height / 12_700,
            xml: serialize(drawing), isFloating: container.name == "anchor"
        )
    }

    private func firstDescendant(named name: String, in element: XMLElement) -> XMLElement? {
        for child in element.children {
            if child.name == name { return child }
            if let found = firstDescendant(named: name, in: child) { return found }
        }
        return nil
    }

    // MARK: Tables

    /// Whether a table holds only what the table model keeps: rows of cells.
    static func isEditableTable(_ element: XMLElement) -> Bool {
        let rowLevel: Set<String> = ["tblPr", "tblGrid", "tr"]
        let cellLevel: Set<String> = ["tblPrEx", "trPr", "tc"]
        let rows = element.children(named: "tr")
        return !rows.isEmpty
            && element.children.allSatisfy { rowLevel.contains($0.name) }
            && rows.allSatisfy { $0.children.allSatisfy { cellLevel.contains($0.name) } }
    }

    func table(from element: XMLElement) -> Table {
        let tblPr = element.firstChild(named: "tblPr")
        let styleID = tblPr?.firstChild(named: "tblStyle")?.attribute("val")
        let grid = element.firstChild(named: "tblGrid")?.children(named: "gridCol")
            .map { Int($0.attribute("w") ?? "") ?? 0 } ?? []
        let explicitBorders = tblPr?.firstChild(named: "tblBorders").map(PropertyReader.hasVisibleBorders)

        let rows = element.children(named: "tr").map { row in
            TableRow(
                cells: row.children(named: "tc").map(cell),
                exceptionsXML: row.firstChild(named: "tblPrEx").flatMap { serialize($0) },
                preservedPropertiesXML: row.firstChild(named: "trPr").flatMap { serialize($0) },
                isHeader: row.firstChild(named: "trPr")?.firstChild(named: "tblHeader") != nil
            )
        }
        var table = Table(
            rows: rows, gridColumns: grid, preservedPropertiesXML: tblPr.flatMap { serialize($0) },
            styleID: styleID,
            hasBorders: explicitBorders ?? styles.tableHasBorders(styleID: styleID)
        )
        table.borderColorHex = tblPr?.firstChild(named: "tblBorders").flatMap(PropertyReader.borderColor)
            ?? styles.tableBorderColor(styleID: styleID)
        table.look = PropertyReader.tableLook(tblPr?.firstChild(named: "tblLook"))
        table.originalXML = serialize(element)
        table.originalRows = rows
        table.originalGrid = grid
        return table
    }

    private func cell(from element: XMLElement) -> TableCell {
        let tcPr = element.firstChild(named: "tcPr")
        var content = blocks(from: element.children.filter { $0.name != "tcPr" }).blocks
        // A cell must end in a paragraph.
        if case .paragraph = content.last {} else { content.append(.paragraph(Paragraph())) }
        var cell = TableCell(blocks: content)
        cell.preservedPropertiesXML = tcPr.flatMap { serialize($0) }
        cell.gridSpan = Int(tcPr?.firstChild(named: "gridSpan")?.attribute("val") ?? "") ?? 1
        if let merge = tcPr?.firstChild(named: "vMerge") {
            cell.verticalMerge = merge.attribute("val") == "restart" ? .restart : .continue
        }
        cell.shadingHex = tcPr?.firstChild(named: "shd").flatMap(PropertyReader.fill)
        return cell
    }
}

// MARK: - Properties

enum PropertyReader {
    /// An OOXML on/off property: present means on, unless its value says otherwise.
    static func isOn(_ element: XMLElement?) -> Bool? {
        guard let element else { return nil }
        guard let value = element.attribute("val") else { return true }
        return !["0", "false", "off", "none"].contains(value)
    }

    static func paragraphProperties(from pPr: XMLElement) -> ParagraphProperties {
        var result = ParagraphProperties()
        result.styleID = pPr.firstChild(named: "pStyle")?.attribute("val")
        result.alignment = pPr.firstChild(named: "jc")?.attribute("val").flatMap(ParagraphAlignment.init(ooxml:))
        if let numPr = pPr.firstChild(named: "numPr"),
           let id = numPr.firstChild(named: "numId")?.attribute("val").flatMap({ Int($0) }) {
            let level = numPr.firstChild(named: "ilvl")?.attribute("val").flatMap { Int($0) } ?? 0
            result.list = ListReference(numberingID: id, level: level)
        }
        if let spacing = pPr.firstChild(named: "spacing") {
            result.spacingBefore = spacing.attribute("before").flatMap { Int($0) }
            result.spacingAfter = spacing.attribute("after").flatMap { Int($0) }
            if let line = spacing.attribute("line").flatMap({ Int($0) }) {
                let rule = spacing.attribute("lineRule").flatMap(LineSpacing.Rule.init(rawValue:)) ?? .auto
                result.lineSpacing = LineSpacing(line: line, rule: rule)
            }
        }
        if let ind = pPr.firstChild(named: "ind") {
            result.indentLeft = (ind.attribute("left") ?? ind.attribute("start")).flatMap { Int($0) }
            result.indentRight = (ind.attribute("right") ?? ind.attribute("end")).flatMap { Int($0) }
            if let hanging = ind.attribute("hanging").flatMap({ Int($0) }) {
                result.indentFirstLine = -hanging
            } else if let first = ind.attribute("firstLine").flatMap({ Int($0) }) {
                result.indentFirstLine = first
            }
        }
        result.pageBreakBefore = isOn(pPr.firstChild(named: "pageBreakBefore"))
        result.outlineLevel = pPr.firstChild(named: "outlineLvl")?.attribute("val").flatMap { Int($0) }
        return result
    }

    static func runStyle(from rPr: XMLElement) -> RunStyle {
        var result = RunStyle()
        result.characterStyleID = rPr.firstChild(named: "rStyle")?.attribute("val")
        if let fonts = rPr.firstChild(named: "rFonts") {
            if let name = fonts.attribute("ascii") ?? fonts.attribute("hAnsi") ?? fonts.attribute("eastAsia") {
                result.fontName = name
            } else if let theme = fonts.attribute("asciiTheme") ?? fonts.attribute("hAnsiTheme") {
                result.fontName = theme.hasPrefix("major") ? RunStyle.majorThemeFont : RunStyle.minorThemeFont
            }
        }
        result.fontSize = rPr.firstChild(named: "sz")?.attribute("val").flatMap { Int(Double($0) ?? 0) }
            .flatMap { $0 > 0 ? $0 : nil }
        result.isBold = isOn(rPr.firstChild(named: "b"))
        result.isItalic = isOn(rPr.firstChild(named: "i"))
        result.underline = isOn(rPr.firstChild(named: "u"))
        result.isStruckThrough = isOn(rPr.firstChild(named: "strike"))
        if let color = rPr.firstChild(named: "color")?.attribute("val"), color != "auto" {
            result.colorHex = color.uppercased()
        }
        if let highlight = rPr.firstChild(named: "highlight")?.attribute("val"), highlight != "none" {
            result.highlight = highlight
        }
        result.verticalAlignment = rPr.firstChild(named: "vertAlign")?.attribute("val")
            .flatMap(RunStyle.VerticalPosition.init(rawValue:))
        result.allCaps = isOn(rPr.firstChild(named: "caps"))
        return result
    }

    /// The colour of the first border that has one.
    static func borderColor(_ borders: XMLElement) -> String? {
        borders.children.lazy.compactMap { border -> String? in
            guard let color = border.attribute("color"), color != "auto",
                  !["nil", "none"].contains(border.attribute("val") ?? "nil") else { return nil }
            return color.uppercased()
        }.first
    }

    /// A shading's fill, unless it is automatic.
    static func fill(_ shading: XMLElement) -> String? {
        guard let fill = shading.attribute("fill"), fill != "auto" else { return nil }
        return fill.uppercased()
    }

    /// `w:tblLook`, spelled either as flags in a hex value or as attributes.
    static func tableLook(_ element: XMLElement?) -> TableLook {
        var look = TableLook()
        guard let element else { return look }
        if let value = element.attribute("val").flatMap({ Int($0, radix: 16) }) {
            look.firstRow = value & 0x0020 != 0
            look.lastRow = value & 0x0040 != 0
            look.firstColumn = value & 0x0080 != 0
            look.lastColumn = value & 0x0100 != 0
            look.bandedRows = value & 0x0200 == 0
            look.bandedColumns = value & 0x0400 == 0
        }
        func flag(_ name: String) -> Bool? { element.attribute(name).map { $0 == "1" || $0 == "true" || $0 == "on" } }
        look.firstRow = flag("firstRow") ?? look.firstRow
        look.lastRow = flag("lastRow") ?? look.lastRow
        look.firstColumn = flag("firstColumn") ?? look.firstColumn
        look.lastColumn = flag("lastColumn") ?? look.lastColumn
        look.bandedRows = flag("noHBand").map(!) ?? look.bandedRows
        look.bandedColumns = flag("noVBand").map(!) ?? look.bandedColumns
        return look
    }

    static func hasVisibleBorders(_ borders: XMLElement) -> Bool {
        borders.children.contains { border in
            let value = border.attribute("val") ?? "nil"
            return value != "nil" && value != "none"
        }
    }
}

extension RunStyle {
    /// Stand-ins for the theme's fonts, resolved when the run is drawn.
    static let majorThemeFont = "+major"
    static let minorThemeFont = "+minor"
}

enum StyleReader {
    static func styleSheet(from root: XMLElement) -> StyleSheet {
        var sheet = StyleSheet()
        if let defaults = root.firstChild(named: "docDefaults") {
            if let rPr = defaults.firstDescendant(atPath: "rPrDefault/rPr") {
                sheet.defaultRunStyle = PropertyReader.runStyle(from: rPr)
            }
            if let pPr = defaults.firstDescendant(atPath: "pPrDefault/pPr") {
                sheet.defaultParagraphProperties = PropertyReader.paragraphProperties(from: pPr)
            }
        }
        for element in root.children(named: "style") {
            guard let style = style(from: element) else { continue }
            sheet.styles[style.id] = style
            if element.attribute("default") == "1" || element.attribute("default") == "true" {
                switch style.kind {
                case .paragraph: sheet.defaultParagraphStyleID = style.id
                case .character: sheet.defaultCharacterStyleID = style.id
                default: break
                }
            }
        }
        return sheet
    }

    static func style(from element: XMLElement) -> StyleSheet.Style? {
        guard let id = element.attribute("styleId"),
              let kind = StyleSheet.Style.Kind(rawValue: element.attribute("type") ?? "paragraph") else { return nil }
        var style = StyleSheet.Style(
            id: id, name: element.firstChild(named: "name")?.attribute("val") ?? id, kind: kind,
            basedOn: element.firstChild(named: "basedOn")?.attribute("val"),
            next: element.firstChild(named: "next")?.attribute("val")
        )
        if let pPr = element.firstChild(named: "pPr") {
            style.paragraphProperties = PropertyReader.paragraphProperties(from: pPr)
            style.paragraphProperties.styleID = nil
        }
        if let rPr = element.firstChild(named: "rPr") {
            style.runStyle = PropertyReader.runStyle(from: rPr)
            style.runStyle.characterStyleID = nil
        }
        if let borders = element.firstDescendant(atPath: "tblPr/tblBorders") {
            style.hasTableBorders = PropertyReader.hasVisibleBorders(borders)
            style.tableBorderColorHex = PropertyReader.borderColor(borders)
        }
        if kind == .table {
            var whole = TableCondition(runStyle: style.runStyle, paragraphProperties: style.paragraphProperties)
            whole.fillHex = element.firstDescendant(atPath: "tcPr/shd").flatMap(PropertyReader.fill)
            style.tableConditions[.wholeTable] = whole
            for part in element.children(named: "tblStylePr") {
                guard let type = part.attribute("type").flatMap(TableCondition.Kind.init(rawValue:)) else { continue }
                var condition = TableCondition()
                if let rPr = part.firstChild(named: "rPr") { condition.runStyle = PropertyReader.runStyle(from: rPr) }
                if let pPr = part.firstChild(named: "pPr") {
                    condition.paragraphProperties = PropertyReader.paragraphProperties(from: pPr)
                }
                condition.fillHex = part.firstDescendant(atPath: "tcPr/shd").flatMap(PropertyReader.fill)
                style.tableConditions[type] = condition
            }
        }
        return style
    }

    static func numbering(from root: XMLElement) -> NumberingDefinitions {
        var result = NumberingDefinitions()
        for abstract in root.children(named: "abstractNum") {
            guard let id = abstract.attribute("abstractNumId").flatMap({ Int($0) }) else { continue }
            var levels: [Int: NumberingDefinitions.ListLevel] = [:]
            for level in abstract.children(named: "lvl") {
                guard let index = level.attribute("ilvl").flatMap({ Int($0) }) else { continue }
                let ind = level.firstDescendant(atPath: "pPr/ind")
                levels[index] = NumberingDefinitions.ListLevel(
                    format: level.firstChild(named: "numFmt")?.attribute("val") ?? "decimal",
                    text: level.firstChild(named: "lvlText")?.attribute("val") ?? "",
                    start: level.firstChild(named: "start")?.attribute("val").flatMap { Int($0) } ?? 1,
                    indentLeft: (ind?.attribute("left") ?? ind?.attribute("start")).flatMap { Int($0) },
                    hanging: ind?.attribute("hanging").flatMap { Int($0) }
                )
            }
            result.abstracts[id] = levels
        }
        for instance in root.children(named: "num") {
            guard let id = instance.attribute("numId").flatMap({ Int($0) }),
                  let abstract = instance.firstChild(named: "abstractNumId")?.attribute("val").flatMap({ Int($0) })
            else { continue }
            result.instances[id] = abstract
        }
        return result
    }
}

enum NoteReader {
    /// The notes in a footnotes or endnotes part, leaving out the separators Word keeps there.
    static func notes(from root: XMLElement, kind: NoteKind) -> [Note] {
        let namespaces = root.namespaceDeclarations
        return root.children(named: kind.rawValue).compactMap { element in
            guard let id = element.attribute("id"), element.attribute("type") == nil
                    || element.attribute("type") == "normal" else { return nil }
            let paragraphs = element.children(named: "p")
            let text = paragraphs.map { HeaderFooterReader.plainText(of: $0) }.joined(separator: "\n")
                // The text usually starts with a space after the note's number.
                .trimmingPrefix(" ")
            let firstRun = paragraphs.first?.children.first { $0.name == "r" && $0.firstChild(named: "t") != nil }
            return Note(
                kind: kind, id: id, text: String(text),
                paragraphPropertiesXML: paragraphs.first?.firstChild(named: "pPr")
                    .flatMap { XMLLite.serialize($0, inheritedNamespaces: namespaces) },
                runPropertiesXML: firstRun?.firstChild(named: "rPr")
                    .flatMap { XMLLite.serialize($0, inheritedNamespaces: namespaces) },
                originalXML: XMLLite.serialize(element, inheritedNamespaces: namespaces), originalText: String(text)
            )
        }
    }
}

enum CommentReader {
    static func comments(from root: XMLElement, extended: XMLElement?) -> [Comment] {
        var states: [String: (done: Bool, parent: String?)] = [:]
        for entry in extended?.children(named: "commentEx") ?? [] {
            guard let paraID = entry.attribute("paraId") else { continue }
            states[paraID] = (entry.attribute("done") == "1", entry.attribute("paraIdParent"))
        }
        let namespaces = root.namespaceDeclarations
        return root.children(named: "comment").compactMap { element in
            guard let id = element.attribute("id") else { return nil }
            let paragraphs = element.children(named: "p")
            let text = paragraphs.map { HeaderFooterReader.plainText(of: $0) }.joined(separator: "\n")
            let paraID = paragraphs.last?.attribute("paraId")
            let state = paraID.flatMap { states[$0] }
            return Comment(
                id: id, author: element.attribute("author") ?? "", initials: element.attribute("initials"),
                date: element.attribute("date"), text: text, paraID: paraID, isDone: state?.done ?? false,
                parentParaID: state?.parent,
                originalXML: XMLLite.serialize(element, inheritedNamespaces: namespaces), originalText: text
            )
        }
    }
}

enum PageSetupReader {
    static func pageSetup(from sectPr: XMLElement) -> PageSetup {
        var setup = PageSetup()
        func value(_ element: XMLElement?, _ name: String) -> Int? {
            element?.attribute(name).flatMap { Int(Double($0) ?? .nan) }
        }
        let size = sectPr.firstChild(named: "pgSz")
        setup.width = value(size, "w") ?? setup.width
        setup.height = value(size, "h") ?? setup.height
        let margins = sectPr.firstChild(named: "pgMar")
        // Negative top and bottom margins mean "regardless of the header"; the size is what counts.
        setup.marginTop = abs(value(margins, "top") ?? setup.marginTop)
        setup.marginBottom = abs(value(margins, "bottom") ?? setup.marginBottom)
        setup.marginLeft = value(margins, "left") ?? value(margins, "start") ?? setup.marginLeft
        setup.marginRight = value(margins, "right") ?? value(margins, "end") ?? setup.marginRight
        setup.headerDistance = value(margins, "header") ?? setup.headerDistance
        setup.footerDistance = value(margins, "footer") ?? setup.footerDistance
        for reference in sectPr.children where reference.name == "headerReference" || reference.name == "footerReference" {
            guard let id = reference.attribute("id") else { continue }
            let kind = reference.attribute("type").flatMap(HeaderFooterKind.init(rawValue:)) ?? .default
            if reference.name == "headerReference" {
                setup.headerFooters.headers[kind] = id
            } else {
                setup.headerFooters.footers[kind] = id
            }
        }
        setup.headerFooters.titlePage = PropertyReader.isOn(sectPr.firstChild(named: "titlePg")) ?? false
        setup.originalHeaderFooters = setup.headerFooters
        return setup
    }
}

enum HeaderFooterReader {
    /// A header or footer part's text, with page number fields as placeholders.
    static func text(from root: XMLElement) -> HeaderFooterText {
        let paragraphs = root.children.filter { $0.name == "p" || $0.name == "sdt" || $0.name == "tbl" }
        let lines = paragraphs.map { fieldAwareText(of: $0) }.filter { !$0.trimmed.isEmpty }
        let alignment = paragraphs.lazy.compactMap {
            $0.firstDescendant(atPath: "pPr/jc")?.attribute("val").flatMap(ParagraphAlignment.init(ooxml:))
        }.first ?? .leading
        var text = HeaderFooterText(text: lines.joined(separator: "\n"), alignment: alignment)
        let namespaces = root.namespaceDeclarations
        let first = root.children.first { $0.name == "p" }
        text.paragraphPropertiesXML = first?.firstChild(named: "pPr")
            .flatMap { XMLLite.serialize($0, inheritedNamespaces: namespaces) }
        text.runPropertiesXML = first.flatMap { firstTextRun(in: $0) }?.firstChild(named: "rPr")
            .flatMap { XMLLite.serialize($0, inheritedNamespaces: namespaces) }
        text.hasRichContent = paragraphs.contains { $0.name != "p" } || paragraphs.contains { containsDrawing($0) }
        return text
    }

    private static func firstTextRun(in element: XMLElement) -> XMLElement? {
        for child in element.children {
            if child.name == "r", child.firstChild(named: "t") != nil { return child }
            if child.name != "pPr", let found = firstTextRun(in: child) { return found }
        }
        return nil
    }

    private static func containsDrawing(_ element: XMLElement) -> Bool {
        element.children.contains { ["drawing", "pict", "object", "AlternateContent"].contains($0.name) || containsDrawing($0) }
    }

    /// Text with `PAGE` and `NUMPAGES` fields replaced by placeholders, since
    /// the result Word last stored is only right for one page.
    private static func fieldAwareText(of element: XMLElement) -> String {
        var output = ""
        var instruction = ""
        // Inside a field: collecting its code, then skipping its stale result.
        var state: (inCode: Bool, skippingResult: Bool) = (false, false)
        func visit(_ node: XMLElement) {
            switch node.name {
            case "fldChar":
                switch node.attribute("fldCharType") {
                case "begin":
                    state = (true, false)
                    instruction = ""
                case "separate":
                    state.inCode = false
                    if let placeholder = placeholder(for: instruction) {
                        output += placeholder
                        state.skippingResult = true
                    }
                case "end":
                    if state.inCode, let placeholder = placeholder(for: instruction) { output += placeholder }
                    state = (false, false)
                default: break
                }
            case "instrText":
                instruction += node.text
            case "fldSimple":
                if let placeholder = placeholder(for: node.attribute("instr") ?? "") {
                    output += placeholder
                } else {
                    node.children.forEach(visit)
                }
            case "t":
                if !state.inCode && !state.skippingResult { output += node.text }
            case "tab":
                if !state.inCode && !state.skippingResult { output += "\t" }
            default:
                node.children.forEach(visit)
            }
        }
        visit(element)
        return output
    }

    private static func placeholder(for instruction: String) -> String? {
        let word = instruction.trimmed.split(separator: " ").first.map { $0.uppercased() }
        switch word {
        case "PAGE": return HeaderFooterText.pageNumberPlaceholder
        case "NUMPAGES", "SECTIONPAGES": return HeaderFooterText.pageCountPlaceholder
        default: return nil
        }
    }

    /// Every `w:t` (and equation text) inside an element, in order.
    static func plainText(of element: XMLElement) -> String {
        var output = ""
        func visit(_ node: XMLElement) {
            switch node.name {
            case "t", "delText": if node.name == "t" { output += node.text }
            case "tab": output += "\t"
            case "br", "cr": output += "\n"
            case "instrText", "rPr", "pPr": return
            case "p" where !output.isEmpty: output += "\n"; node.children.forEach(visit)
            default: node.children.forEach(visit)
            }
        }
        visit(element)
        return output
    }
}

/// Puts adjacent text with the same formatting into one piece, so the same
/// content always reads back the same however the file happened to split it.
enum InlineNormalizer {
    static func normalized(_ inlines: [Inline]) -> [Inline] {
        var result: [Inline] = []
        result.reserveCapacity(inlines.count)
        for inline in inlines {
            if case .text(let text) = inline.content, let last = result.last,
               case .text(let previous) = last.content,
               last.format == inline.format, last.hyperlink == inline.hyperlink, last.revision == inline.revision {
                result[result.count - 1].content = .text(previous + text)
            } else {
                result.append(inline)
            }
        }
        return result
    }
}
