import Foundation

/// Writes a `WordDocument` back into its package.
///
/// The main document part is regenerated from the model, with every element
/// Libretto kept but does not model written back where it was read. The
/// other parts are written back as they were read, apart from the styles and
/// numbering parts, which gain whatever styles and lists were added.
enum DOCXWriter {
    static func data(from document: WordDocument) throws -> Data {
        var parts = document.package.parts
        var package = PackageEditor(parts: parts, documentPath: document.package.documentPath)

        parts[document.package.documentPath] = Data(documentXML(document).utf8)
        package.parts = parts

        if !document.numbering.added.isEmpty { package.addLists(document.numbering) }
        if !document.styles.added.isEmpty || !document.styles.addedTableStyles.isEmpty
            || document.styles.styles.values.contains(where: { $0.isCreated || $0.isModified }) {
            package.addStyles(document.styles)
        }
        for (id, media) in document.package.addedMedia.sorted(by: { $0.key < $1.key }) {
            package.addMedia(media, relationshipID: id)
        }
        for (id, address) in document.package.addedLinks.sorted(by: { $0.key < $1.key }) {
            package.addLink(address, relationshipID: id)
        }
        for (id, text) in document.headerFooters.sorted(by: { $0.key < $1.key }) where text.isEdited {
            package.writeHeaderFooter(text, relationshipID: id, existing: document.package.relationships[id],
                                      styles: document.styles)
        }
        for kind in NoteKind.allCases {
            let notes = document.notes.filter { $0.kind == kind }
            if notes != document.originalNotes.filter({ $0.kind == kind }) {
                package.writeNotes(notes, kind: kind, styles: document.styles)
            }
        }
        if document.comments != document.originalComments {
            package.writeComments(document.comments, styles: document.styles)
        }
        if document.trackRevisions != document.originalTrackRevisions {
            package.editSettings { settings in
                settings.children(named: "trackRevisions").forEach(settings.removeChild)
                if document.trackRevisions { settings.insertChild(.word("trackRevisions"), at: settings.children.count) }
            }
        }
        if document.evenAndOddHeaders != document.originalEvenAndOddHeaders {
            package.editSettings { settings in
                settings.children(named: "evenAndOddHeaders").forEach(settings.removeChild)
                if document.evenAndOddHeaders { settings.insertChild(.word("evenAndOddHeaders"), at: settings.children.count) }
            }
        }
        package.finish()

        // Content types first, then the package relationships: some readers
        // expect to find them at the front.
        let first = ["[Content_Types].xml", "_rels/.rels"]
        let rest = package.parts.keys.filter { !first.contains($0) }.sorted()
        let entries: [(path: String, data: Data)] = (first + rest).compactMap { path in
            guard let data = package.parts[path] else { return nil }
            return (path: path, data: data)
        }
        return try ZipArchive.archive(entries: entries)
    }

    // MARK: - Main part

    static func documentXML(_ document: WordDocument) -> String {
        var output = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        var attributes = document.package.rootAttributesXML
        // Parts Libretto generates use these prefixes; declare any the file did not.
        for (prefix, uri) in OOXML.standardNamespaces.sorted(by: { $0.key < $1.key })
        where document.package.namespaces[prefix] == nil {
            attributes += " xmlns:\(prefix)=\"\(uri)\""
        }
        output += "<w:document\(attributes)><w:body>"
        let body = FieldBalancer.balanced(document.body)
        var writer = BodyWriter()
        for block in body { writer.write(block) }
        output += writer.output
        output += document.trailingXML.joined()
        output += DOCXPatcher.sectionPropertiesXML(for: document.pageSetup)
        output += "</w:body></w:document>"
        return output
    }
}

/// Writes blocks, paragraphs and runs as WordprocessingML.
struct BodyWriter {
    private(set) var output = ""
    private var pictureID = 1000
    /// IDs for tracked changes made in Libretto, well above any Word gives out.
    private var revisionID = 900_000

    /// A tracked change's attributes: as read, or, for one made in Libretto, a new ID with its author and date.
    private mutating func attributes(of revision: Revision) -> String {
        guard revision.attributesXML.isEmpty else { return revision.attributesXML }
        revisionID += 1
        var result = " w:id=\"\(revisionID)\" w:author=\"\(XMLLite.escape(revision.author ?? ""))\""
        if let date = revision.date { result += " w:date=\"\(XMLLite.escape(date))\"" }
        return result
    }

    mutating func write(_ block: Block) {
        output += block.leadingXML.joined()
        switch block {
        case .paragraph(let paragraph): write(paragraph)
        case .table(let table): write(table)
        case .preserved(let preserved): output += preserved.xml
        }
    }

    // MARK: Paragraphs

    private mutating func write(_ paragraph: Paragraph) {
        if let original = paragraph.originalXML, paragraph.inlines == paragraph.originalInlines,
           paragraph.properties == paragraph.originalProperties ?? ParagraphProperties(),
           paragraph.markRevision == paragraph.originalMarkRevision, paragraph.section?.isChanged != true {
            output += original
            return
        }
        output += "<w:p\(paragraph.attributesXML)>"
        let markAttributes = paragraph.markRevision.map { attributes(of: $0) }
        if let pPr = DOCXPatcher.paragraphPropertiesXML(for: paragraph, markRevisionAttributes: markAttributes) {
            output += pPr
        }

        var openLink: Hyperlink?
        var openRevision: Revision?
        var openRun: RunFormat?
        func closeRun() {
            if openRun != nil { output += "</w:r>" }
            openRun = nil
        }
        func closeRevision() {
            closeRun()
            if let revision = openRevision { output += "</w:\(revision.kind.rawValue)>" }
            openRevision = nil
        }
        func closeLink() {
            closeRevision()
            if openLink != nil { output += "</w:hyperlink>" }
            openLink = nil
        }

        for inline in paragraph.inlines {
            if inline.hyperlink != openLink {
                closeLink()
                if let link = inline.hyperlink {
                    output += "<w:hyperlink\(link.attributesXML)>"
                    openLink = link
                }
            }
            if inline.revision != openRevision {
                closeRevision()
                if let revision = inline.revision {
                    output += "<w:\(revision.kind.rawValue)\(attributes(of: revision))>"
                    openRevision = revision
                }
            }
            if case .paragraphChild(let xml, _) = inline.content {
                closeRun()
                output += xml
                continue
            }
            if openRun != inline.format {
                closeRun()
                output += "<w:r>"
                if let rPr = DOCXPatcher.runPropertiesXML(for: inline.format) { output += rPr }
                openRun = inline.format
            }
            output += runContent(inline.content, isDeleted: openRevision.map { !$0.kind.adds } ?? false)
        }
        closeLink()
        output += "</w:p>"
    }

    private mutating func runContent(_ content: InlineContent, isDeleted: Bool = false) -> String {
        switch content {
        case .text(let text) where isDeleted:
            return "<w:delText xml:space=\"preserve\">\(XMLLite.escape(text))</w:delText>"
        case .runChild(let xml, _) where isDeleted:
            // A deleted field's code is deleted field code.
            return xml.replacing(#/^<(\w+:)?instrText\b/#) { "<\($0.output.1 ?? "")delInstrText" }
                .replacing(#/</(\w+:)?instrText>$/#) { "</\($0.output.1 ?? "")delInstrText>" }
        case .text(let text):
            return "<w:t xml:space=\"preserve\">\(XMLLite.escape(text))</w:t>"
        case .tab:
            return "<w:tab/>"
        case .lineBreak:
            return "<w:br/>"
        case .pageBreak:
            return "<w:br w:type=\"page\"/>"
        case .columnBreak:
            return "<w:br w:type=\"column\"/>"
        case .note(let reference):
            return reference.xml
        case .image(let image):
            if let xml = image.xml { return xml }
            pictureID += 1
            return Self.drawingXML(for: image, id: pictureID)
        case .runChild(let xml, _), .paragraphChild(let xml, _):
            return xml
        }
    }

    /// A `w:drawing` for a picture inserted in Libretto.
    static func drawingXML(for image: InlineImage, id: Int) -> String {
        let cx = Int(image.width * 12_700)
        let cy = Int(image.height * 12_700)
        return """
            <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
            <wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/>\
            <wp:docPr id="\(id)" name="Picture \(id)"/>\
            <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
            <a:graphic><a:graphicData uri="\(OOXML.pictureNamespace)"><pic:pic>\
            <pic:nvPicPr><pic:cNvPr id="\(id)" name="Picture \(id)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(image.relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
            """
    }

    // MARK: Tables

    private mutating func write(_ table: Table) {
        if table.isUnchanged, let original = table.originalXML {
            output += original
            return
        }
        output += "<w:tbl>"
        output += table.preservedPropertiesXML ?? Self.defaultTableProperties
        output += "<w:tblGrid>"
        for width in table.gridColumns { output += "<w:gridCol w:w=\"\(width)\"/>" }
        output += "</w:tblGrid>"
        for row in table.rows {
            output += "<w:tr>"
            output += row.exceptionsXML ?? ""
            output += row.preservedPropertiesXML ?? ""
            var column = 0
            for cell in row.cells {
                output += "<w:tc>"
                if let tcPr = cell.preservedPropertiesXML {
                    output += tcPr
                } else {
                    let width = table.gridColumns.dropFirst(column).prefix(cell.gridSpan).reduce(0, +)
                    output += "<w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>"
                }
                column += cell.gridSpan
                for block in cell.blocks { write(block) }
                output += "</w:tc>"
            }
            output += "</w:tr>"
        }
        output += "</w:tbl>"
    }

    /// Tables Libretto inserts draw their own borders, so they look the same
    /// in any document, whatever table styles it defines.
    static let defaultTableProperties = """
        <w:tblPr><w:tblW w:w="5000" w:type="pct"/><w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        </w:tblBorders><w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" \
        w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr>
        """
}

// MARK: - Headers and footers

/// A header or footer's text as paragraphs: a line each, with the page
/// number and page count as fields Word fills in.
enum HeaderFooterWriter {
    static func paragraphsXML(_ text: HeaderFooterText, styleID: String?) -> String {
        paragraphs(text, styleID: styleID).joined()
    }

    static func paragraphs(_ text: HeaderFooterText, styleID: String?) -> [String] {
        let base = text.paragraphPropertiesXML ?? (styleID.map { "<w:pPr><w:pStyle w:val=\"\(XMLLite.escape($0))\"/></w:pPr>" }
            ?? "<w:pPr/>")
        let pPr = DOCXPatcher.editing(base) { pPr in
            pPr.children(named: "jc").forEach(pPr.removeChild)
            if text.alignment != .leading {
                pPr.insertChild(.word("jc", ["val": text.alignment.rawValue]), at: pPr.children.count)
            }
            pPr.sortChildren(by: DOCXPatcher.paragraphPropertyOrder)
        }.flatMap { $0 == "<w:pPr/>" ? nil : $0 } ?? ""
        let rPr = text.runPropertiesXML ?? ""
        return text.text.components(separatedBy: "\n").map { line in
            var output = "<w:p>\(pPr)"
            var remaining = Substring(line)
            while !remaining.isEmpty {
                let fields = [(HeaderFooterText.pageNumberPlaceholder, "PAGE"), (HeaderFooterText.pageCountPlaceholder, "NUMPAGES")]
                let next = fields.compactMap { field in remaining.range(of: field.0).map { ($0, field) } }
                    .min { $0.0.lowerBound < $1.0.lowerBound }
                let plain = next.map { remaining[..<$0.0.lowerBound] } ?? remaining
                for (index, piece) in plain.components(separatedBy: "\t").enumerated() {
                    if index > 0 { output += "<w:r>\(rPr)<w:tab/></w:r>" }
                    if !piece.isEmpty { output += "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(XMLLite.escape(piece))</w:t></w:r>" }
                }
                guard let (range, field) = next else { break }
                output += "<w:fldSimple w:instr=\" \(field.1) \"><w:r>\(rPr)<w:t>1</w:t></w:r></w:fldSimple>"
                remaining = remaining[range.upperBound...]
            }
            return output + "</w:p>"
        }
    }
}

// MARK: - Notes

enum NoteWriter {
    /// A `w:footnote` or `w:endnote`, a paragraph per line, the first led by the note's number.
    static func xml(_ note: Note, textStyle: String?, referenceStyle: String?) -> String {
        let name = note.kind.rawValue
        let pPr = note.paragraphPropertiesXML ?? textStyle.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        let markProperties = referenceStyle.map { "<w:rPr><w:rStyle w:val=\"\($0)\"/></w:rPr>" }
            ?? "<w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr>"
        let rPr = note.runPropertiesXML ?? ""
        let paragraphs = note.text.components(separatedBy: "\n").enumerated().map { index, line in
            let mark = index == 0 ? "<w:r>\(markProperties)<w:\(name)Ref/></w:r>" : ""
            let text = index == 0 ? " " + line : line
            let run = text.isEmpty ? "" : "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(XMLLite.escape(text))</w:t></w:r>"
            return "<w:p>\(pPr)\(mark)\(run)</w:p>"
        }.joined()
        return "<w:\(name) w:id=\"\(XMLLite.escape(note.id))\">\(paragraphs)</w:\(name)>"
    }
}

// MARK: - Comments

enum CommentWriter {
    /// A `w:comment`, a paragraph per line, the last carrying the comment's paragraph ID.
    static func xml(_ comment: Comment, paragraphStyle: String?, referenceStyle: String?) -> String {
        var attributes = " w:id=\"\(XMLLite.escape(comment.id))\" w:author=\"\(XMLLite.escape(comment.author))\""
        if let date = comment.date { attributes += " w:date=\"\(XMLLite.escape(date))\"" }
        if let initials = comment.initials { attributes += " w:initials=\"\(XMLLite.escape(initials))\"" }
        let lines = comment.text.components(separatedBy: "\n")
        let pPr = paragraphStyle.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        let rPr = referenceStyle.map { "<w:rPr><w:rStyle w:val=\"\($0)\"/></w:rPr>" } ?? ""
        let paragraphs = lines.enumerated().map { index, line in
            let paraID = index == lines.count - 1 ? comment.paraID : nil
            let id = paraID.map { " w14:paraId=\"\($0)\" w14:textId=\"77777777\"" } ?? ""
            let mark = index == 0 ? "<w:r>\(rPr)<w:annotationRef/></w:r>" : ""
            let text = line.isEmpty ? "" : "<w:r><w:t xml:space=\"preserve\">\(XMLLite.escape(line))</w:t></w:r>"
            return "<w:p\(id)>\(pPr)\(mark)\(text)</w:p>"
        }.joined()
        return "<w:comment\(attributes)>\(paragraphs)</w:comment>"
    }
}

// MARK: - Fields

/// Removes field characters left without their partners.
///
/// A field is a begin, a separator and an end, each in a run of its own,
/// with the field's code between the first two. In the editor they ride on
/// the characters around them, and deleting those characters can take one
/// part of a field and leave another; Word treats a document with half a
/// field as damaged.
enum FieldBalancer {
    private enum Part {
        case begin, separate, end, code
    }

    private static func part(of inline: Inline) -> Part? {
        guard case .runChild(let xml, _) = inline.content else { return nil }
        if xml.contains("fldCharType=\"begin\"") { return .begin }
        if xml.contains("fldCharType=\"separate\"") { return .separate }
        if xml.contains("fldCharType=\"end\"") { return .end }
        if xml.contains("instrText") { return .code }
        return nil
    }

    static func balanced(_ body: [Block]) -> [Block] {
        // First pass: which field parts, numbered in reading order, have partners.
        var parts: [Part] = []
        visit(body) { inline in if let part = part(of: inline) { parts.append(part) } }
        guard !parts.isEmpty else { return body }

        var keep = [Bool](repeating: false, count: parts.count)
        // Each open field: its begin, and its separator once seen.
        var stack: [(begin: Int, separate: Int?, codes: [Int])] = []
        for (index, part) in parts.enumerated() {
            switch part {
            case .begin:
                stack.append((index, nil, []))
            case .code:
                if stack.last?.separate == nil, !stack.isEmpty { stack[stack.count - 1].codes.append(index) }
            case .separate:
                if stack.last?.separate == nil, !stack.isEmpty { stack[stack.count - 1].separate = index }
            case .end:
                guard let field = stack.popLast() else { continue }
                keep[field.begin] = true
                keep[index] = true
                if let separate = field.separate { keep[separate] = true }
                field.codes.forEach { keep[$0] = true }
            }
        }
        guard keep.contains(false) else { return body }

        var counter = 0
        return transform(body) { inlines in
            inlines.filter { inline in
                guard part(of: inline) != nil else { return true }
                defer { counter += 1 }
                return keep[counter]
            }
        }
    }

    private static func visit(_ blocks: [Block], _ body: (Inline) -> Void) {
        for block in blocks {
            switch block {
            case .paragraph(let paragraph): paragraph.inlines.forEach(body)
            case .table(let table):
                for row in table.rows { for cell in row.cells { visit(cell.blocks, body) } }
            case .preserved: continue
            }
        }
    }

    private static func transform(_ blocks: [Block], _ change: ([Inline]) -> [Inline]) -> [Block] {
        blocks.map { block in
            switch block {
            case .paragraph(var paragraph):
                paragraph.inlines = change(paragraph.inlines)
                return .paragraph(paragraph)
            case .table(var table):
                // Reading order: rows, then cells, then their content.
                for row in table.rows.indices {
                    for cell in table.rows[row].cells.indices {
                        table.rows[row].cells[cell].blocks = transform(table.rows[row].cells[cell].blocks, change)
                    }
                }
                return .table(table)
            case .preserved:
                return block
            }
        }
    }
}

// MARK: - Package parts

/// Adds parts, relationships and content types to a package being written.
private struct PackageEditor {
    var parts: [String: Data]
    let documentPath: String
    private var relationships: [String] = []
    private var overrides: [String] = []
    private var defaults: [String: String] = [:]

    init(parts: [String: Data], documentPath: String) {
        self.parts = parts
        self.documentPath = documentPath
    }

    private var relationshipsPath: String { DOCXPaths.relationshipsPath(for: documentPath) }

    private var existingRelationships: [String: DocumentPackage.Relationship] {
        DOCXReader.relationships(at: relationshipsPath, in: parts)
    }

    /// The path of the part a relationship type points at, creating it from
    /// `empty` if the package has none.
    private mutating func partPath(ofType type: String, defaultName: String, contentType: String, empty: String)
        -> String {
        if let existing = existingRelationships.values.first(where: { $0.type == type && !$0.isExternal }) {
            return DOCXPaths.resolve(existing.target, relativeTo: documentPath)
        }
        let path = DOCXPaths.resolve(defaultName, relativeTo: documentPath)
        parts[path] = Data(empty.utf8)
        // Named rather than numbered, so it cannot collide with the file's own IDs.
        let id = "rIdLibretto" + defaultName.replacingOccurrences(of: ".xml", with: "").capitalized
        relationships.append("<Relationship Id=\"\(id)\" Type=\"\(type)\" Target=\"\(defaultName)\"/>")
        overrides.append("<Override PartName=\"/\(path)\" ContentType=\"\(contentType)\"/>")
        return path
    }

    private mutating func edit(_ path: String, _ change: (XMLElement) -> Void) {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return }
        change(root)
        guard let xml = XMLLite.serialize(root) else { return }
        parts[path] = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + xml).utf8)
    }

    mutating func addLists(_ numbering: NumberingDefinitions) {
        let path = partPath(
            ofType: OOXML.numberingType, defaultName: "numbering.xml", contentType: OOXML.numberingContentType,
            empty: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<w:numbering xmlns:w=\"\(OOXML.wordNamespace)\"></w:numbering>"
        )
        edit(path) { root in
            let namespaces = ["w": root.sourceNamespaceBinding(forPrefix: "w") ?? OOXML.wordNamespace]
            for list in numbering.added {
                let overrides = (numbering.overrides[list.numberingID] ?? [:]).sorted { $0.key < $1.key }.map { level, start in
                    "<w:lvlOverride w:ilvl=\"\(level)\"><w:startOverride w:val=\"\(start)\"/></w:lvlOverride>"
                }.joined()
                let instance = """
                    <w:num w:numId="\(list.numberingID)"><w:abstractNumId w:val="\(list.abstractID)"/>\(overrides)</w:num>
                    """
                if !list.isNewDefinition {
                    if let element = XMLLite.fragment(instance, namespaces: namespaces) {
                        let index = root.children.firstIndex { $0.name == "numIdMacAtCleanup" }
                        root.insertChild(element, at: index ?? root.children.count)
                    }
                    continue
                }
                let levels = (numbering.abstracts[list.abstractID] ?? [:]).sorted { $0.key < $1.key }.map { index, level in
                    """
                    <w:lvl w:ilvl="\(index)"><w:start w:val="\(level.start)"/><w:numFmt w:val="\(level.format)"/>\
                    <w:lvlText w:val="\(XMLLite.escape(level.text))"/><w:lvlJc w:val="left"/>\
                    <w:pPr><w:ind w:left="\(level.indentLeft ?? 720)" w:hanging="\(level.hanging ?? 360)"/></w:pPr></w:lvl>
                    """
                }.joined()
                let abstract = """
                    <w:abstractNum w:abstractNumId="\(list.abstractID)">\
                    <w:multiLevelType w:val="hybridMultilevel"/>\(levels)</w:abstractNum>
                    """
                // Abstract definitions all come before the first instance.
                if let element = XMLLite.fragment(abstract, namespaces: namespaces) {
                    let index = root.children.firstIndex { $0.name == "num" || $0.name == "numIdMacAtCleanup" }
                    root.insertChild(element, at: index ?? root.children.count)
                }
                if let element = XMLLite.fragment(instance, namespaces: namespaces) {
                    let index = root.children.firstIndex { $0.name == "numIdMacAtCleanup" }
                    root.insertChild(element, at: index ?? root.children.count)
                }
            }
        }
    }

    mutating func addStyles(_ styles: StyleSheet) {
        let path = partPath(
            ofType: OOXML.stylesType, defaultName: "styles.xml",
            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
            empty: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<w:styles xmlns:w=\"\(OOXML.wordNamespace)\"></w:styles>"
        )
        edit(path) { root in
            let namespaces = ["w": root.sourceNamespaceBinding(forPrefix: "w") ?? OOXML.wordNamespace]
            for choice in styles.added {
                let id = styles.styleID(for: choice) ?? choice.defaultID
                let xml = BuiltInStyles.xml(for: choice)
                    .replacingOccurrences(of: "w:styleId=\"\(choice.defaultID)\"", with: "w:styleId=\"\(id)\"")
                    .replacingOccurrences(of: " w:default=\"1\"", with: "")
                if let element = XMLLite.fragment(xml, namespaces: namespaces) {
                    root.insertChild(element, at: root.children.count)
                }
            }
            for builtIn in styles.addedTableStyles {
                var xml = builtIn.xml
                if styles.styles["TableNormal"] == nil {
                    xml = xml.replacingOccurrences(of: "<w:basedOn w:val=\"TableNormal\"/>", with: "")
                }
                if let element = XMLLite.fragment(xml, namespaces: namespaces) {
                    root.insertChild(element, at: root.children.count)
                }
            }
            // Styles made in Libretto, then styles whose definitions changed.
            for style in styles.styles.values.filter(\.isCreated).sorted(by: { $0.id < $1.id }) {
                var xml = "<w:style w:type=\"paragraph\" w:customStyle=\"1\" w:styleId=\"\(XMLLite.escape(style.id))\">"
                xml += "<w:name w:val=\"\(XMLLite.escape(style.name))\"/>"
                if let basedOn = style.basedOn { xml += "<w:basedOn w:val=\"\(XMLLite.escape(basedOn))\"/>" }
                if let next = style.next { xml += "<w:next w:val=\"\(XMLLite.escape(next))\"/>" }
                xml += "<w:qFormat/>"
                xml += DOCXPatcher.paragraphPropertiesXML(for: Paragraph(properties: style.paragraphProperties)) ?? ""
                xml += DOCXPatcher.runPropertiesXML(for: RunFormat(style: style.runStyle)) ?? ""
                xml += "</w:style>"
                if let element = XMLLite.fragment(xml, namespaces: namespaces) {
                    root.insertChild(element, at: root.children.count)
                }
            }
            let modified = Dictionary(
                styles.styles.values.filter(\.isModified).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            guard !modified.isEmpty else { return }
            for element in root.children(named: "style") {
                guard let id = element.attribute("styleId"), let style = modified[id] else { continue }
                let pPr = DOCXPatcher.paragraphPropertiesXML(for: Paragraph(
                    properties: style.paragraphProperties, originalProperties: style.originalParagraphProperties,
                    preservedPropertiesXML: style.paragraphPropertiesXML
                ))
                var format = RunFormat(style: style.runStyle, original: style.originalRunStyle)
                format.preservedPropertiesXML = style.runPropertiesXML
                let rPr = DOCXPatcher.runPropertiesXML(for: format)
                element.children.filter { $0.name == "pPr" || $0.name == "rPr" }.forEach(element.removeChild)
                let scope = root.namespaceDeclarations.merging(namespaces) { own, _ in own }
                for xml in [pPr, rPr].compactMap({ $0 }) {
                    if let child = XMLLite.fragment(xml, namespaces: DOCXPatcher.usedBindings(for: xml, in: scope)) {
                        element.insertChild(child, at: element.children.count)
                    }
                }
                element.sortChildren(by: DOCXPatcher.styleOrder)
            }
        }
    }

    mutating func addMedia(_ media: DocumentPackage.AddedMedia, relationshipID: String) {
        parts[media.path] = media.data
        let target = media.path.hasPrefix("word/") ? String(media.path.dropFirst("word/".count)) : "/" + media.path
        relationships.append("<Relationship Id=\"\(relationshipID)\" Type=\"\(OOXML.imageType)\" Target=\"\(target)\"/>")
        defaults[media.fileExtension.lowercased()] = media.contentType
    }

    /// Writes a header or footer part afresh from its text: over the part it
    /// came from, keeping that part's root and anything that is not content,
    /// or as a new part.
    mutating func writeHeaderFooter(
        _ text: HeaderFooterText, relationshipID: String, existing: DocumentPackage.Relationship?, styles: StyleSheet
    ) {
        let name = text.isFooter ? "ftr" : "hdr"
        let styleName = text.isFooter ? "footer" : "header"
        let styleID = styles.styles.values.first { $0.kind == .paragraph && $0.name.lowercased() == styleName }?.id
        let content: Set<String> = ["p", "tbl", "sdt", "customXml"]
        if let existing, !existing.isExternal {
            let path = DOCXPaths.resolve(existing.target, relativeTo: documentPath)
            edit(path) { root in
                let namespaces = DOCXPatcher.usedBindings(
                    for: HeaderFooterWriter.paragraphsXML(text, styleID: styleID), in: root.namespaceDeclarations
                )
                let index = root.children.firstIndex { content.contains($0.name) } ?? root.children.count
                root.children.filter { content.contains($0.name) }.forEach(root.removeChild)
                for (offset, xml) in HeaderFooterWriter.paragraphs(text, styleID: styleID).enumerated() {
                    if let element = XMLLite.fragment(xml, namespaces: namespaces) {
                        root.insertChild(element, at: index + offset)
                    }
                }
            }
            return
        }
        var number = 1
        let stem = text.isFooter ? "footer" : "header"
        while parts["word/\(stem)\(number).xml"] != nil { number += 1 }
        let file = "\(stem)\(number).xml"
        let path = DOCXPaths.resolve(file, relativeTo: documentPath)
        let declarations = OOXML.standardNamespaces.sorted { $0.key < $1.key }
            .map { " xmlns:\($0.key)=\"\($0.value)\"" }.joined()
        parts[path] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:\(name)\(declarations)>\(HeaderFooterWriter.paragraphsXML(text, styleID: styleID))</w:\(name)>
            """.utf8)
        let type = text.isFooter ? OOXML.footerType : OOXML.headerType
        relationships.append("<Relationship Id=\"\(relationshipID)\" Type=\"\(type)\" Target=\"\(file)\"/>")
        let contentType = text.isFooter ? OOXML.footerContentType : OOXML.headerContentType
        overrides.append("<Override PartName=\"/\(path)\" ContentType=\"\(contentType)\"/>")
    }

    /// Writes the comments part: comments untouched as they were read, the
    /// rest afresh; and Word's extensions to it, which say which comments are
    /// resolved and which reply to which.
    mutating func writeComments(_ comments: [Comment], styles: StyleSheet) {
        let path = partPath(
            ofType: OOXML.commentsType, defaultName: "comments.xml", contentType: OOXML.commentsContentType,
            empty: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<w:comments xmlns:w=\"\(OOXML.wordNamespace)\" xmlns:w14=\"\(OOXML.w14Namespace)\"></w:comments>"
        )
        let paragraphStyle = styles.styles["CommentText"] != nil ? "CommentText" : nil
        let referenceStyle = styles.styles["CommentReference"] != nil ? "CommentReference" : nil
        edit(path) { root in
            var namespaces = root.namespaceDeclarations
            namespaces["w"] = namespaces["w"] ?? OOXML.wordNamespace
            if namespaces["w14"] == nil {
                root.declareNamespaces(["w14": OOXML.w14Namespace])
                namespaces["w14"] = OOXML.w14Namespace
            }
            let existing = Dictionary(
                root.children(named: "comment").compactMap { element in element.attribute("id").map { ($0, element) } },
                uniquingKeysWith: { first, _ in first }
            )
            root.children(named: "comment").forEach(root.removeChild)
            for comment in comments {
                // Resolving a comment from before paragraph IDs gives it one, which it must be written with.
                let keepsID = comment.paraID.map { comment.originalXML?.contains("\"\($0)\"") ?? false } ?? true
                if let element = existing[comment.id], comment.text == comment.originalText,
                   comment.originalXML != nil, keepsID {
                    root.insertChild(element, at: root.children.count)
                } else if let element = XMLLite.fragment(
                    CommentWriter.xml(comment, paragraphStyle: paragraphStyle, referenceStyle: referenceStyle),
                    namespaces: namespaces.filter { !$0.key.isEmpty }
                ) {
                    root.insertChild(element, at: root.children.count)
                }
            }
        }

        let extended = comments.filter { $0.paraID != nil }
        guard !extended.isEmpty else { return }
        let extendedPath = partPath(
            ofType: OOXML.commentsExtendedType, defaultName: "commentsExtended.xml",
            contentType: OOXML.commentsExtendedContentType,
            empty: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<w15:commentsEx xmlns:w15=\"\(OOXML.w15Namespace)\"></w15:commentsEx>"
        )
        edit(extendedPath) { root in
            let prefix = root.namespaceDeclarations.first { $0.value == OOXML.w15Namespace }?.key ?? "w15"
            root.children(named: "commentEx").forEach(root.removeChild)
            for comment in extended {
                guard let paraID = comment.paraID else { continue }
                var attributes = ["paraId": paraID, "done": comment.isDone ? "1" : "0"]
                if let parent = comment.parentParaID { attributes["paraIdParent"] = parent }
                let element = XMLElement(
                    name: "commentEx", qualifiedName: "\(prefix):commentEx", attributes: attributes,
                    qualifiedAttributes: Dictionary(uniqueKeysWithValues: attributes.map { ("\(prefix):\($0.key)", $0.value) })
                )
                root.insertChild(element, at: root.children.count)
            }
        }
    }

    /// Writes a footnotes or endnotes part: notes untouched as they were read,
    /// the rest afresh. A new part starts with the separators Word expects.
    mutating func writeNotes(_ notes: [Note], kind: NoteKind, styles: StyleSheet) {
        let type = OOXML.notesType(kind)
        let name = kind.rawValue
        let isNew = !existingRelationships.values.contains { $0.type == type && !$0.isExternal }
        let separators = ["separator": -1, "continuationSeparator": 0].sorted { $0.value < $1.value }.map { type, id in
            """
            <w:\(name) w:type="\(type)" w:id="\(id)"><w:p><w:pPr><w:spacing w:after="0" w:line="240" \
            w:lineRule="auto"/></w:pPr><w:r><w:\(type)/></w:r></w:p></w:\(name)>
            """
        }.joined()
        let path = partPath(
            ofType: type, defaultName: "\(name)s.xml", contentType: OOXML.notesContentType(kind),
            empty: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<w:\(name)s xmlns:w=\"\(OOXML.wordNamespace)\">\(separators)</w:\(name)s>"
        )
        let textStyle = styles.styles.values.first { $0.kind == .paragraph && $0.name.lowercased() == "\(name) text" }?.id
        let referenceStyle = styles.styles.values
            .first { $0.kind == .character && $0.name.lowercased() == "\(name) reference" }?.id
        edit(path) { root in
            var namespaces = root.namespaceDeclarations.filter { !$0.key.isEmpty }
            namespaces["w"] = namespaces["w"] ?? OOXML.wordNamespace
            let existing = Dictionary(
                root.children(named: name).compactMap { element in element.attribute("id").map { ($0, element) } },
                uniquingKeysWith: { first, _ in first }
            )
            root.children(named: name).filter { ($0.attribute("type") ?? "normal") == "normal" }.forEach(root.removeChild)
            for note in notes {
                if let element = existing[note.id], note.text == note.originalText, note.originalXML != nil {
                    root.insertChild(element, at: root.children.count)
                } else if let element = XMLLite.fragment(
                    NoteWriter.xml(note, textStyle: textStyle, referenceStyle: referenceStyle), namespaces: namespaces
                ) {
                    root.insertChild(element, at: root.children.count)
                }
            }
        }
        if isNew {
            // Word looks for the separators by the IDs the settings name.
            editSettings { settings in
                guard settings.firstChild(named: "\(name)Pr") == nil,
                      let properties = XMLLite.fragment(
                          "<w:\(name)Pr><w:\(name) w:id=\"-1\"/><w:\(name) w:id=\"0\"/></w:\(name)Pr>",
                          namespaces: ["w": settings.sourceNamespaceBinding(forPrefix: "w") ?? OOXML.wordNamespace]
                      ) else { return }
                settings.insertChild(properties, at: settings.children.count)
            }
        }
    }

    /// Edits the settings part, making one if the package has none.
    mutating func editSettings(_ change: (XMLElement) -> Void) {
        let path = partPath(
            ofType: OOXML.settingsType, defaultName: "settings.xml",
            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml",
            empty: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<w:settings xmlns:w=\"\(OOXML.wordNamespace)\"></w:settings>"
        )
        edit(path) { root in
            change(root)
            root.sortChildren(by: DOCXPatcher.settingsOrder)
        }
    }

    mutating func addLink(_ address: String, relationshipID: String) {
        relationships.append("""
            <Relationship Id="\(relationshipID)" Type="\(OOXML.hyperlinkType)" \
            Target="\(XMLLite.escape(address))" TargetMode="External"/>
            """)
    }

    /// Writes the relationships and content types gathered along the way.
    mutating func finish() {
        if !relationships.isEmpty {
            let existing = parts[relationshipsPath].map { String(decoding: $0, as: UTF8.self) }
                ?? "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<Relationships xmlns=\"\(OOXML.packageRelationshipsNamespace)\"></Relationships>"
            parts[relationshipsPath] = Data(Self.insert(relationships.joined(), before: "</Relationships>", in: existing).utf8)
        }
        guard let data = parts["[Content_Types].xml"] else { return }
        var types = String(decoding: data, as: UTF8.self)
        var additions = overrides
        for (fileExtension, contentType) in defaults.sorted(by: { $0.key < $1.key })
        where !types.lowercased().contains("extension=\"\(fileExtension)\"") {
            additions.insert("<Default Extension=\"\(fileExtension)\" ContentType=\"\(contentType)\"/>", at: 0)
        }
        guard !additions.isEmpty else { return }
        types = Self.insert(additions.joined(), before: "</Types>", in: types)
        parts["[Content_Types].xml"] = Data(types.utf8)
    }

    private static func insert(_ addition: String, before closing: String, in xml: String) -> String {
        guard let range = xml.range(of: closing, options: .backwards) else { return xml }
        var result = xml
        result.insert(contentsOf: addition, at: range.lowerBound)
        return result
    }
}
