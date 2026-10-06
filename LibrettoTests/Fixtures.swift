import Foundation
@testable import Libretto

/// Packages shaped like the ones Word writes, built in code so each test
/// can see exactly what it is reading.
enum Fixtures {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static let rootNamespaces = """
        xmlns:w="\(w)" xmlns:r="\(r)" \
        xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" \
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="w14"
        """

    /// A heading, a paragraph of mixed formatting with a link, a bookmark
    /// and a page number field, two list items, a table, a page break, and a
    /// last paragraph carrying a section break of its own.
    static let body = """
        <w:p w14:paraId="1A2B3C4D" w:rsidR="00AB12CD"><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>\
        <w:r><w:t>Annual Report</w:t></w:r></w:p>\
        <w:p><w:pPr><w:spacing w:after="120"/><w:jc w:val="both"/></w:pPr>\
        <w:r><w:rPr><w:lang w:val="en-GB"/></w:rPr><w:t xml:space="preserve">Revenue was </w:t></w:r>\
        <w:r><w:rPr><w:b/><w:lang w:val="en-GB"/></w:rPr><w:t>strong</w:t></w:r>\
        <w:bookmarkStart w:id="0" w:name="summary"/>\
        <w:r><w:t xml:space="preserve"> this year; see </w:t></w:r>\
        <w:hyperlink r:id="rIdLink" w:history="1"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr>\
        <w:t>the site</w:t></w:r></w:hyperlink><w:bookmarkEnd w:id="0"/>\
        <w:r><w:t xml:space="preserve"> on page </w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>\
        <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t>.</w:t></w:r></w:p>\
        <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>\
        <w:r><w:t>First item</w:t></w:r></w:p>\
        <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>\
        <w:r><w:t>Second item</w:t></w:r></w:p>\
        <w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/></w:tblPr>\
        <w:tblGrid><w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>\
        <w:tr><w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Region</w:t></w:r></w:p></w:tc>\
        <w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/><w:shd w:val="clear" w:color="auto" w:fill="DDEEFF"/></w:tcPr>\
        <w:p><w:r><w:t>Total</w:t></w:r></w:p></w:tc></w:tr>\
        <w:tr><w:tc><w:p><w:r><w:t>North</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>1,200</w:t></w:r></w:p></w:tc></w:tr>\
        </w:tbl>\
        <w:p><w:r><w:br w:type="page"/></w:r></w:p>\
        <w:p><w:pPr><w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:pPr><w:r><w:t>Appendix</w:t></w:r></w:p>\
        <w:p><w:r><w:t>Closing words.</w:t></w:r></w:p>
        """

    static let finalSection = """
        <w:sectPr><w:headerReference w:type="default" r:id="rIdHeader"/>\
        <w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1080" w:bottom="1440" w:left="1080" \
        w:header="720" w:footer="720" w:gutter="0"/><w:cols w:space="720"/></w:sectPr>
        """

    static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="\(w)"><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
        </w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr>\
        <w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>\
        <w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>\
        <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/>\
        <w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders></w:tblPr></w:style>\
        </w:styles>
        """

    static let numbering = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="\(w)"><w:abstractNum w:abstractNumId="0">\
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/>\
        <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>\
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2)"/></w:lvl>\
        </w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>
        """

    static let header = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="\(w)"><w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t xml:space="preserve">Page </w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>PAGE</w:instrText></w:r>\
        <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>7</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>\
        </w:p></w:hdr>
        """

    static func parts(
        body: String = body, includeNumbering: Bool = true, macroEnabled: Bool = false
    ) -> [String: Data] {
        let mainType = macroEnabled
            ? "application/vnd.ms-word.document.macroEnabled.main+xml"
            : "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
        var overrides = """
            <Override PartName="/word/document.xml" ContentType="\(mainType)"/>\
            <Override PartName="/word/styles.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
            <Override PartName="/word/header1.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
            """
        var relationships = """
            <Relationship Id="rIdStyles" Type="\(OOXML.stylesType)" Target="styles.xml"/>\
            <Relationship Id="rIdHeader" Type="\(OOXML.headerType)" Target="header1.xml"/>\
            <Relationship Id="rIdLink" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" \
            Target="https://example.com/" TargetMode="External"/>
            """
        var parts: [String: Data] = [
            "word/styles.xml": Data(styles.utf8),
            "word/header1.xml": Data(header.utf8),
            "word/document.xml": Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:document \(rootNamespaces)><w:body>\(body)\(finalSection)</w:body></w:document>
                """.utf8),
            "_rels/.rels": Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="\(OOXML.packageRelationshipsNamespace)">\
                <Relationship Id="rId1" Type="\(OOXML.officeDocumentType)" Target="word/document.xml"/></Relationships>
                """.utf8),
        ]
        if includeNumbering {
            parts["word/numbering.xml"] = Data(numbering.utf8)
            overrides += "<Override PartName=\"/word/numbering.xml\" ContentType=\"\(OOXML.numberingContentType)\"/>"
            relationships += "<Relationship Id=\"rIdNumbering\" Type=\"\(OOXML.numberingType)\" Target=\"numbering.xml\"/>"
        }
        if macroEnabled {
            parts["word/vbaProject.bin"] = Data([0xD0, 0xCF, 0x11, 0xE0])
            overrides += "<Override PartName=\"/word/vbaProject.bin\" ContentType=\"application/vnd.ms-office.vbaProject\"/>"
            relationships += """
                <Relationship Id="rIdVba" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" \
                Target="vbaProject.bin"/>
                """
        }
        parts["[Content_Types].xml"] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="\(OOXML.contentTypesNamespace)">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\(overrides)</Types>
            """.utf8)
        parts["word/_rels/document.xml.rels"] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="\(OOXML.packageRelationshipsNamespace)">\(relationships)</Relationships>
            """.utf8)
        return parts
    }

    static func document(includeNumbering: Bool = true, macroEnabled: Bool = false) throws -> WordDocument {
        try DOCXReader.document(fromParts: parts(includeNumbering: includeNumbering, macroEnabled: macroEnabled))
    }

    /// Writes a document and reads the package back, part by part.
    static func written(_ document: WordDocument) throws -> [String: Data] {
        try ZipArchive.entries(in: DOCXWriter.data(from: document))
    }

    static func text(_ parts: [String: Data], _ path: String) -> String {
        parts[path].map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
