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
        if !document.styles.added.isEmpty { package.addStyles(document.styles) }
        for (id, media) in document.package.addedMedia.sorted(by: { $0.key < $1.key }) {
            package.addMedia(media, relationshipID: id)
        }
        for (id, address) in document.package.addedLinks.sorted(by: { $0.key < $1.key }) {
            package.addLink(address, relationshipID: id)
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
           paragraph.properties == paragraph.originalProperties ?? ParagraphProperties() {
            output += original
            return
        }
        output += "<w:p\(paragraph.attributesXML)>"
        if let pPr = DOCXPatcher.paragraphPropertiesXML(for: paragraph) { output += pPr }

        var openLink: Hyperlink?
        var openRun: RunFormat?
        func closeRun() {
            if openRun != nil { output += "</w:r>" }
            openRun = nil
        }
        func closeLink() {
            closeRun()
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
            output += runContent(inline.content)
        }
        closeLink()
        output += "</w:p>"
    }

    private mutating func runContent(_ content: InlineContent) -> String {
        switch content {
        case .text(let text):
            return "<w:t xml:space=\"preserve\">\(XMLLite.escape(text))</w:t>"
        case .tab:
            return "<w:tab/>"
        case .lineBreak:
            return "<w:br/>"
        case .pageBreak:
            return "<w:br w:type=\"page\"/>"
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
                let instance = """
                    <w:num w:numId="\(list.numberingID)"><w:abstractNumId w:val="\(list.abstractID)"/></w:num>
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
        }
    }

    mutating func addMedia(_ media: DocumentPackage.AddedMedia, relationshipID: String) {
        parts[media.path] = media.data
        let target = media.path.hasPrefix("word/") ? String(media.path.dropFirst("word/".count)) : "/" + media.path
        relationships.append("<Relationship Id=\"\(relationshipID)\" Type=\"\(OOXML.imageType)\" Target=\"\(target)\"/>")
        defaults[media.fileExtension.lowercased()] = media.contentType
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
