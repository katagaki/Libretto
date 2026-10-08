import Foundation

/// Edits kept property elements in place: only what changed is touched, so
/// whatever else the file said about a paragraph or run survives the edit.
enum DOCXPatcher {
    // MARK: - Fragments

    /// Parses a fragment that was written out relying on the document's own
    /// namespace declarations, edits it, and writes it back the same way.
    ///
    /// Every prefix the fragment uses is bound for the parse and treated as in
    /// scope for the write, so no declarations are added: the fragment goes
    /// back into a document that already declares them.
    static func editing(_ xml: String, _ edit: (XMLElement) -> Void) -> String? {
        let namespaces = namespaceBindings(for: xml)
        guard let element = XMLLite.fragment(xml, namespaces: namespaces) else { return nil }
        edit(element)
        return XMLLite.serialize(element, inheritedNamespaces: namespaces)
    }

    /// The standard prefixes, and a stand-in binding for every other prefix the fragment uses.
    static func namespaceBindings(for xml: String) -> [String: String] {
        var result = OOXML.standardNamespaces
        let pattern = #/[<\s\/]([A-Za-z_][\w.\-]*):[A-Za-z_]/#
        for match in xml.matches(of: pattern) {
            let prefix = String(match.output.1)
            guard prefix != "xml", prefix != "xmlns", result[prefix] == nil else { continue }
            result[prefix] = "urn:libretto:prefix:\(prefix)"
        }
        return result
    }

    static func removingSectionBreak(fromPPr xml: String) -> String? {
        editing(xml) { pPr in
            pPr.children(named: "sectPr").forEach(pPr.removeChild)
        }
    }

    static func removingParagraphIDs(fromAttributes attributes: String) -> String {
        attributes.replacing(#/\s[\w]+:(paraId|textId)="[^"]*"/#, with: "")
    }

    // MARK: - Paragraph properties

    static let paragraphPropertyOrder = [
        "pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl", "numPr",
        "suppressLineNumbers", "pBdr", "shd", "tabs", "suppressAutoHyphens", "kinsoku", "wordWrap",
        "overflowPunct", "topLinePunct", "autoSpaceDE", "autoSpaceDN", "bidi", "adjustRightInd", "snapToGrid",
        "spacing", "ind", "contextualSpacing", "mirrorIndents", "suppressOverlap", "jc", "textDirection",
        "textAlignment", "textboxTightWrap", "outlineLvl", "divId", "cnfStyle", "rPr", "sectPr", "pPrChange",
    ]

    /// The `w:pPr` to write for a paragraph, or `nil` if it needs none.
    /// `markRevisionAttributes` are the attributes the mark's tracked change is written with.
    static func paragraphPropertiesXML(for paragraph: Paragraph, markRevisionAttributes: String? = nil) -> String? {
        let new = paragraph.properties
        let old = paragraph.originalProperties ?? ParagraphProperties()
        let markChanged = paragraph.markRevision != paragraph.originalMarkRevision
        if let preserved = paragraph.preservedPropertiesXML, new == old, !markChanged { return preserved }
        if paragraph.preservedPropertiesXML == nil, new == ParagraphProperties(), paragraph.markRevision == nil {
            return nil
        }

        let edited = editing(paragraph.preservedPropertiesXML ?? "<w:pPr/>") { pPr in
            if markChanged {
                let rPr = child("rPr", of: pPr)
                rPr.children.filter { Revision.Kind(rawValue: $0.name) != nil }.forEach(rPr.removeChild)
                if let revision = paragraph.markRevision,
                   let element = XMLLite.fragment(
                       "<w:\(revision.kind.rawValue)\(markRevisionAttributes ?? revision.attributesXML)/>",
                       namespaces: namespaceBindings(for: revision.attributesXML)
                   ) {
                    // A mark's own changes come before its formatting.
                    rPr.insertChild(element, at: 0)
                }
                if rPr.children.isEmpty { pPr.removeChild(rPr) }
            }
            func set(_ name: String, _ attributes: [String: String]?) {
                pPr.children(named: name).forEach(pPr.removeChild)
                if let attributes { pPr.insertChild(.word(name, attributes), at: pPr.children.count) }
            }
            if new.styleID != old.styleID { set("pStyle", new.styleID.map { ["val": $0] }) }
            if new.alignment != old.alignment { set("jc", new.alignment.map { ["val": $0.rawValue] }) }
            if new.pageBreakBefore != old.pageBreakBefore {
                set("pageBreakBefore", new.pageBreakBefore.map { $0 ? [:] : ["val": "0"] })
            }
            if new.outlineLevel != old.outlineLevel { set("outlineLvl", new.outlineLevel.map { ["val": String($0)] }) }
            if new.list != old.list {
                pPr.children(named: "numPr").forEach(pPr.removeChild)
                if let list = new.list {
                    let numPr = XMLElement.word("numPr")
                    pPr.insertChild(numPr, at: pPr.children.count)
                    numPr.insertChild(.word("ilvl", ["val": String(list.level)]), at: 0)
                    numPr.insertChild(.word("numId", ["val": String(list.numberingID)]), at: 1)
                }
            }
            if new.spacingBefore != old.spacingBefore || new.spacingAfter != old.spacingAfter
                || new.lineSpacing != old.lineSpacing {
                let spacing = child("spacing", of: pPr)
                if new.spacingBefore != old.spacingBefore {
                    spacing.setWordAttribute("before", new.spacingBefore.map(String.init))
                    spacing.setWordAttribute("beforeAutospacing", nil)
                }
                if new.spacingAfter != old.spacingAfter {
                    spacing.setWordAttribute("after", new.spacingAfter.map(String.init))
                    spacing.setWordAttribute("afterAutospacing", nil)
                }
                if new.lineSpacing != old.lineSpacing {
                    spacing.setWordAttribute("line", new.lineSpacing.map { String($0.line) })
                    spacing.setWordAttribute("lineRule", new.lineSpacing?.rule.rawValue)
                }
                if spacing.attributes.isEmpty { pPr.removeChild(spacing) }
            }
            if new.indentLeft != old.indentLeft || new.indentRight != old.indentRight
                || new.indentFirstLine != old.indentFirstLine {
                let ind = child("ind", of: pPr)
                if new.indentLeft != old.indentLeft {
                    ind.setWordAttribute("start", nil)
                    ind.setWordAttribute("left", new.indentLeft.map(String.init))
                }
                if new.indentRight != old.indentRight {
                    ind.setWordAttribute("end", nil)
                    ind.setWordAttribute("right", new.indentRight.map(String.init))
                }
                if new.indentFirstLine != old.indentFirstLine {
                    let first = new.indentFirstLine ?? 0
                    ind.setWordAttribute("firstLine", new.indentFirstLine != nil && first >= 0 ? String(first) : nil)
                    ind.setWordAttribute("hanging", first < 0 ? String(-first) : nil)
                }
                if ind.attributes.isEmpty { pPr.removeChild(ind) }
            }
            pPr.sortChildren(by: paragraphPropertyOrder)
        }
        guard let edited, edited != "<w:pPr/>" else { return nil }
        return edited
    }

    // MARK: - Run properties

    static let runPropertyOrder = [
        "rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike", "dstrike", "outline", "shadow",
        "emboss", "imprint", "noProof", "snapToGrid", "vanish", "webHidden", "color", "spacing", "w", "kern",
        "position", "sz", "szCs", "highlight", "u", "effect", "bdr", "shd", "fitText", "vertAlign", "rtl", "cs",
        "em", "lang", "eastAsianLayout", "specVanish", "oMath",
    ]

    static func runPropertiesXML(for format: RunFormat) -> String? {
        let new = format.style
        let old = format.original ?? RunStyle()
        if let preserved = format.preservedPropertiesXML, new == old { return preserved }
        if format.preservedPropertiesXML == nil, new == RunStyle() { return nil }

        let edited = editing(format.preservedPropertiesXML ?? "<w:rPr/>") { rPr in
            func set(_ names: [String], _ attributes: [String: String]?) {
                for name in names {
                    rPr.children(named: name).forEach(rPr.removeChild)
                    if let attributes { rPr.insertChild(.word(name, attributes), at: rPr.children.count) }
                }
            }
            func toggle(_ value: Bool?) -> [String: String]? {
                value.map { $0 ? [:] : ["val": "0"] }
            }
            if new.characterStyleID != old.characterStyleID {
                set(["rStyle"], new.characterStyleID.map { ["val": $0] })
            }
            if new.fontName != old.fontName {
                set(["rFonts"], new.fontName.map { ["ascii": $0, "hAnsi": $0, "cs": $0, "eastAsia": $0] })
            }
            if new.isBold != old.isBold { set(["b", "bCs"], toggle(new.isBold)) }
            if new.isItalic != old.isItalic { set(["i", "iCs"], toggle(new.isItalic)) }
            if new.isStruckThrough != old.isStruckThrough { set(["strike"], toggle(new.isStruckThrough)) }
            if new.allCaps != old.allCaps { set(["caps"], toggle(new.allCaps)) }
            if new.underline != old.underline || new.underlineStyle != old.underlineStyle {
                set(["u"], new.underline.map { ["val": $0 ? new.underlineStyle ?? "single" : "none"] })
            }
            if new.isDoubleStruckThrough != old.isDoubleStruckThrough { set(["dstrike"], toggle(new.isDoubleStruckThrough)) }
            if new.smallCaps != old.smallCaps { set(["smallCaps"], toggle(new.smallCaps)) }
            if new.outline != old.outline { set(["outline"], toggle(new.outline)) }
            if new.shadow != old.shadow { set(["shadow"], toggle(new.shadow)) }
            if new.emboss != old.emboss { set(["emboss"], toggle(new.emboss)) }
            if new.imprint != old.imprint { set(["imprint"], toggle(new.imprint)) }
            if new.characterSpacing != old.characterSpacing {
                set(["spacing"], new.characterSpacing.map { ["val": String($0)] })
            }
            if new.position != old.position { set(["position"], new.position.map { ["val": String($0)] }) }
            if new.colorHex != old.colorHex { set(["color"], new.colorHex.map { ["val": $0] }) }
            if new.fontSize != old.fontSize { set(["sz", "szCs"], new.fontSize.map { ["val": String($0)] }) }
            if new.highlight != old.highlight { set(["highlight"], new.highlight.map { ["val": $0] }) }
            if new.verticalAlignment != old.verticalAlignment {
                set(["vertAlign"], new.verticalAlignment.map { ["val": $0.rawValue] })
            }
            rPr.sortChildren(by: runPropertyOrder)
        }
        guard let edited, edited != "<w:rPr/>" else { return nil }
        return edited
    }

    // MARK: - Section properties

    static let sectionPropertyOrder = [
        "headerReference", "footerReference", "footnotePr", "endnotePr", "type", "pgSz", "pgMar", "paperSrc",
        "pgBorders", "lnNumType", "pgNumType", "cols", "formProt", "vAlign", "noEndnote", "titlePg",
        "textDirection", "bidi", "rtlGutter", "docGrid", "printerSettings", "sectPrChange",
    ]

    static func sectionPropertiesXML(for setup: PageSetup) -> String {
        let base = setup.preservedXML ?? """
            <w:sectPr><w:pgSz/><w:pgMar w:header="708" w:footer="708" w:gutter="0"/>\
            <w:cols w:space="708"/><w:docGrid w:linePitch="360"/></w:sectPr>
            """
        let referencesChanged = setup.headerFooters != (setup.originalHeaderFooters ?? HeaderFooterReferences())
        if setup.preservedXML != nil, setup.original == setup.values, !referencesChanged { return base }
        return editing(base) { sectPr in
            if referencesChanged {
                sectPr.children.filter { $0.name == "headerReference" || $0.name == "footerReference" }
                    .forEach(sectPr.removeChild)
                for (name, references) in [("headerReference", setup.headerFooters.headers),
                                           ("footerReference", setup.headerFooters.footers)] {
                    for kind in HeaderFooterKind.allCases {
                        guard let id = references[kind] else { continue }
                        let reference = XMLElement(
                            name: name, qualifiedName: "w:" + name, attributes: ["type": kind.rawValue, "id": id],
                            qualifiedAttributes: ["w:type": kind.rawValue, "r:id": id]
                        )
                        sectPr.insertChild(reference, at: sectPr.children.count)
                    }
                }
                sectPr.children(named: "titlePg").forEach(sectPr.removeChild)
                if setup.headerFooters.titlePage { sectPr.insertChild(.word("titlePg"), at: sectPr.children.count) }
            }
            guard setup.preservedXML == nil || setup.original != setup.values else {
                sectPr.sortChildren(by: sectionPropertyOrder)
                return
            }
            let size = child("pgSz", of: sectPr)
            size.setWordAttribute("w", String(setup.width))
            size.setWordAttribute("h", String(setup.height))
            size.setWordAttribute("orient", setup.isLandscape ? "landscape" : nil)
            let margins = child("pgMar", of: sectPr)
            margins.setWordAttribute("top", String(setup.marginTop))
            margins.setWordAttribute("bottom", String(setup.marginBottom))
            margins.setWordAttribute("start", nil)
            margins.setWordAttribute("end", nil)
            margins.setWordAttribute("left", String(setup.marginLeft))
            margins.setWordAttribute("right", String(setup.marginRight))
            for (name, value) in [("header", setup.headerDistance), ("footer", setup.footerDistance), ("gutter", 0)]
            where margins.attribute(name) == nil {
                margins.setWordAttribute(name, String(value))
            }
            sectPr.sortChildren(by: sectionPropertyOrder)
        } ?? base
    }

    // MARK: - Settings

    /// `w:settings`'s children, in schema order.
    static let settingsOrder = [
        "writeProtection", "view", "zoom", "removePersonalInformation", "removeDateAndTime",
        "doNotDisplayPageBoundaries", "displayBackgroundShape", "printPostScriptOverText",
        "printFractionalCharacterWidth", "printFormsData", "embedTrueTypeFonts", "embedSystemFonts",
        "saveSubsetFonts", "saveFormsData", "mirrorMargins", "alignBordersAndEdges", "bordersDoNotSurroundHeader",
        "bordersDoNotSurroundFooter", "gutterAtTop", "hideSpellingErrors", "hideGrammaticalErrors",
        "activeWritingStyle", "proofState", "formsDesign", "attachedTemplate", "linkStyles", "stylePaneFormatFilter",
        "stylePaneSortMethod", "documentType", "mailMerge", "revisionView", "trackRevisions", "doNotTrackMoves",
        "doNotTrackFormatting", "documentProtection", "autoFormatOverride", "styleLockTheme", "styleLockQFSet",
        "defaultTabStop", "autoHyphenation", "consecutiveHyphenLimit", "hyphenationZone", "doNotHyphenateCaps",
        "showEnvelope", "summaryLength", "clickAndTypeStyle", "defaultTableStyle", "evenAndOddHeaders",
        "bookFoldRevPrinting", "bookFoldPrinting", "bookFoldPrintingSheets", "drawingGridHorizontalSpacing",
        "drawingGridVerticalSpacing", "displayHorizontalDrawingGridEvery", "displayVerticalDrawingGridEvery",
        "doNotUseMarginsForDrawingGridOrigin", "drawingGridHorizontalOrigin", "drawingGridVerticalOrigin",
        "doNotShadeFormData", "noPunctuationKerning", "characterSpacingControl", "printTwoOnOne",
        "strictFirstAndLastChars", "noLineBreaksAfter", "noLineBreaksBefore", "savePreviewPicture",
        "doNotValidateAgainstSchema", "saveInvalidXml", "ignoreMixedContent", "alwaysShowPlaceholderText",
        "doNotDemarcateInvalidXml", "saveXmlDataOnly", "useXSLTWhenSaving", "saveThroughXslt", "showXMLTags",
        "alwaysMergeEmptyNamespace", "updateFields", "hdrShapeDefaults", "footnotePr", "endnotePr", "compat",
        "docVars", "rsids", "mathPr", "attachedSchema", "themeFontLang", "clrSchemeMapping",
        "doNotIncludeSubdocsInStats", "doNotAutoCompressPictures", "forceUpgrade", "captions",
        "readModeInkLockDown", "smartTagType", "schemaLibrary", "shapeDefaults", "doNotEmbedSmartTags",
        "decimalSymbol", "listSeparator",
    ]

    // MARK: - Helpers

    /// The first child of that name, created at the end if there is none.
    private static func child(_ name: String, of parent: XMLElement) -> XMLElement {
        if let existing = parent.firstChild(named: name) { return existing }
        let created = XMLElement.word(name)
        parent.insertChild(created, at: parent.children.count)
        return created
    }
}
