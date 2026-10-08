import Foundation

/// Definitions of the styles the style menu offers, for documents that do
/// not define them yet, and for new documents.
enum BuiltInStyles {
    static func xml(for choice: ParagraphStyleChoice) -> String {
        let id = choice.defaultID
        let name = choice.builtInName
        let body: String
        switch choice {
        case .body:
            return """
                <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/>\
                <w:qFormat/></w:style>
                """
        case .title:
            body = """
                <w:pPr><w:spacing w:after="80" w:line="240" w:lineRule="auto"/><w:contextualSpacing/></w:pPr>\
                <w:rPr><w:kern w:val="28"/><w:sz w:val="56"/><w:szCs w:val="56"/></w:rPr>
                """
        case .subtitle:
            body = """
                <w:pPr><w:spacing w:after="160"/></w:pPr>\
                <w:rPr><w:color w:val="595959"/><w:spacing w:val="15"/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
                """
        case .heading1, .heading2, .heading3:
            let level = choice == .heading1 ? 0 : choice == .heading2 ? 1 : 2
            let size = [40, 32, 28][level]
            let before = [360, 160, 160][level]
            body = """
                <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="\(before)" w:after="80"/>\
                <w:outlineLvl w:val="\(level)"/></w:pPr>\
                <w:rPr><w:color w:val="0F4761"/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                """
        case .quote:
            body = """
                <w:pPr><w:spacing w:before="160"/><w:ind w:left="864" w:right="864"/><w:jc w:val="center"/></w:pPr>\
                <w:rPr><w:i/><w:iCs/><w:color w:val="404040"/></w:rPr>
                """
        }
        return """
            <w:style w:type="paragraph" w:styleId="\(id)"><w:name w:val="\(name)"/><w:basedOn w:val="Normal"/>\
            <w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\(body)</w:style>
            """
    }

    /// The model of a built-in style, read from the same XML that is written.
    static func style(for choice: ParagraphStyleChoice) -> StyleSheet.Style? {
        guard let element = XMLLite.fragment(xml(for: choice), namespaces: ["w": OOXML.wordNamespace]) else { return nil }
        return StyleReader.style(from: element)
    }
}

/// The package a new document starts as.
enum DOCXTemplate {
    /// Letter where it is the custom, A4 everywhere else.
    static var defaultPageSize: (width: Int, height: Int) {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "PR"]
        let region = Locale.current.region?.identifier ?? ""
        return letterRegions.contains(region) ? (12240, 15840) : (11906, 16838)
    }

    static func blankPackage() -> [String: Data] {
        let size = defaultPageSize
        let w = OOXML.wordNamespace
        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="\(OOXML.contentTypesNamespace)">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Default Extension="jpeg" ContentType="image/jpeg"/>\
            <Override PartName="/word/document.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
            <Override PartName="/word/settings.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
            <Override PartName="/docProps/core.xml" \
            ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
            <Override PartName="/docProps/app.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
            </Types>
            """
        let packageRelationships = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="\(OOXML.packageRelationshipsNamespace)">\
            <Relationship Id="rId1" Type="\(OOXML.officeDocumentType)" Target="word/document.xml"/>\
            <Relationship Id="rId2" \
            Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" \
            Target="docProps/core.xml"/>\
            <Relationship Id="rId3" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" \
            Target="docProps/app.xml"/>\
            </Relationships>
            """
        let documentRelationships = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="\(OOXML.packageRelationshipsNamespace)">\
            <Relationship Id="rId1" Type="\(OOXML.stylesType)" Target="styles.xml"/>\
            <Relationship Id="rId2" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" \
            Target="settings.xml"/>\
            </Relationships>
            """
        let namespaces = OOXML.standardNamespaces.sorted { $0.key < $1.key }
            .map { " xmlns:\($0.key)=\"\($0.value)\"" }.joined()
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document\(namespaces)><w:body><w:p/>\
            <w:sectPr><w:pgSz w:w="\(size.width)" w:h="\(size.height)"/>\
            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" \
            w:header="708" w:footer="708" w:gutter="0"/>\
            <w:cols w:space="708"/><w:docGrid w:linePitch="360"/></w:sectPr>\
            </w:body></w:document>
            """
        let builtIns = ParagraphStyleChoice.allCases.map(BuiltInStyles.xml(for:)).joined()
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="\(w)"><w:docDefaults>\
            <w:rPrDefault><w:rPr><w:sz w:val="22"/><w:szCs w:val="22"/>\
            <w:lang w:val="en-US" w:eastAsia="ja-JP" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>\
            <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="278" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
            </w:docDefaults>\(builtIns)\
            <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>\
            <w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/>\
            <w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>\
            <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">\
            <w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>\
            <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>\
            <w:uiPriority w:val="99"/><w:semiHidden/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>\
            <w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>\
            <w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
            </w:styles>
            """
        let settings = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:settings xmlns:w="\(w)"><w:defaultTabStop w:val="720"/>\
            <w:characterSpacingControl w:val="doNotCompress"/><w:compat>\
            <w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/>\
            </w:compat></w:settings>
            """
        let now = ISO8601DateFormatter().string(from: Date())
        let core = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties \
            xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
            <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
            <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>\
            </cp:coreProperties>
            """
        let app = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">\
            <Application>Libretto</Application></Properties>
            """
        return [
            "[Content_Types].xml": Data(contentTypes.utf8),
            "_rels/.rels": Data(packageRelationships.utf8),
            "word/_rels/document.xml.rels": Data(documentRelationships.utf8),
            "word/document.xml": Data(document.utf8),
            "word/styles.xml": Data(styles.utf8),
            "word/settings.xml": Data(settings.utf8),
            "docProps/core.xml": Data(core.utf8),
            "docProps/app.xml": Data(app.utf8),
        ]
    }
}

/// Word's table styles the table panel offers, defined as Word defines them,
/// for documents that do not have them yet.
enum BuiltInTableStyle: String, CaseIterable, Identifiable, Sendable {
    case grid = "TableGrid"
    case gridLight = "GridTable1Light"
    case gridAccent = "GridTable4-Accent1"
    case listAccent = "ListTable3-Accent1"

    var id: String { rawValue }

    /// Word's own name for it, which does not change with Word's language.
    var name: String {
        switch self {
        case .grid: return "Table Grid"
        case .gridLight: return "Grid Table 1 Light"
        case .gridAccent: return "Grid Table 4 Accent 1"
        case .listAccent: return "List Table 3 Accent 1"
        }
    }

    var xml: String {
        func borders(_ color: String, inside: Bool = true, size: Int = 4) -> String {
            let sides = ["top", "left", "bottom", "right"] + (inside ? ["insideH", "insideV"] : [])
            return "<w:tblBorders>" + sides.map {
                "<w:\($0) w:val=\"single\" w:sz=\"\(size)\" w:space=\"0\" w:color=\"\(color)\"/>"
            }.joined() + "</w:tblBorders>"
        }
        let head = """
            <w:style w:type="table" w:styleId="\(rawValue)"><w:name w:val="\(name)"/><w:basedOn w:val="TableNormal"/>\
            <w:uiPriority w:val="39"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>
            """
        let margins = "<w:tblCellMar><w:left w:w=\"108\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar>"
        switch self {
        case .grid:
            return head + "<w:tblPr>\(borders("auto"))\(margins)</w:tblPr></w:style>"
        case .gridLight:
            return head + """
                <w:tblPr><w:tblStyleRowBandSize w:val="1"/><w:tblStyleColBandSize w:val="1"/>\(borders("B4C6E7"))\(margins)</w:tblPr>\
                <w:tblStylePr w:type="firstRow"><w:rPr><w:b/><w:bCs/></w:rPr><w:tblPr/><w:tcPr><w:tcBorders>\
                <w:bottom w:val="single" w:sz="12" w:space="0" w:color="8EAADB"/></w:tcBorders></w:tcPr></w:tblStylePr>\
                <w:tblStylePr w:type="firstCol"><w:rPr><w:b/><w:bCs/></w:rPr></w:tblStylePr></w:style>
                """
        case .gridAccent:
            return head + """
                <w:tblPr><w:tblStyleRowBandSize w:val="1"/><w:tblStyleColBandSize w:val="1"/>\(borders("8EAADB"))\(margins)</w:tblPr>\
                <w:tblStylePr w:type="firstRow"><w:rPr><w:b/><w:bCs/><w:color w:val="FFFFFF"/></w:rPr><w:tblPr/>\
                <w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="4472C4"/></w:tcPr></w:tblStylePr>\
                <w:tblStylePr w:type="lastRow"><w:rPr><w:b/><w:bCs/></w:rPr></w:tblStylePr>\
                <w:tblStylePr w:type="firstCol"><w:rPr><w:b/><w:bCs/></w:rPr></w:tblStylePr>\
                <w:tblStylePr w:type="band1Horz"><w:tblPr/><w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="D9E2F3"/></w:tcPr></w:tblStylePr>\
                </w:style>
                """
        case .listAccent:
            return head + """
                <w:tblPr><w:tblStyleRowBandSize w:val="1"/><w:tblStyleColBandSize w:val="1"/>\
                \(borders("4472C4", inside: false))\(margins)</w:tblPr>\
                <w:tblStylePr w:type="firstRow"><w:rPr><w:b/><w:bCs/><w:color w:val="FFFFFF"/></w:rPr><w:tblPr/>\
                <w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="4472C4"/></w:tcPr></w:tblStylePr>\
                <w:tblStylePr w:type="firstCol"><w:rPr><w:b/><w:bCs/></w:rPr></w:tblStylePr>\
                <w:tblStylePr w:type="band1Horz"><w:tblPr/><w:tcPr><w:tcBorders><w:top w:val="single" w:sz="4" \
                w:space="0" w:color="4472C4"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="4472C4"/>\
                </w:tcBorders></w:tcPr></w:tblStylePr></w:style>
                """
        }
    }

    /// The model of the style, read from the same XML that is written.
    var style: StyleSheet.Style? {
        guard let element = XMLLite.fragment(xml, namespaces: ["w": OOXML.wordNamespace]) else { return nil }
        return StyleReader.style(from: element)
    }
}
