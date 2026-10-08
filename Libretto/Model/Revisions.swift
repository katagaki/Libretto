import Foundation

/// Accepting and rejecting tracked changes across a document.
///
/// Accepting keeps what an insertion added and lets a deletion go; rejecting
/// does the opposite. A paragraph mark that goes joins its paragraph to the
/// next, which, as in Word, keeps the next paragraph's formatting. Formatting
/// changes, kept in the properties as `w:rPrChange` and `w:pPrChange`, are
/// accepted by dropping the record and rejected by restoring what it records.
enum Revisions {
    static func resolve(_ blocks: [Block], accept: Bool) -> [Block] {
        var result: [Block] = []
        var joining: Paragraph?
        func flushJoining() {
            if let paragraph = joining { result.append(.paragraph(paragraph)) }
            joining = nil
        }
        for block in blocks {
            switch block {
            case .paragraph(var paragraph):
                let before = paragraph
                paragraph.inlines = resolve(paragraph.inlines, accept: accept)
                resolveFormatting(of: &paragraph, accept: accept)
                if let previous = joining {
                    paragraph.inlines = previous.inlines + paragraph.inlines
                    joining = nil
                }
                var markGoes = false
                if let mark = paragraph.markRevision {
                    paragraph.markRevision = nil
                    markGoes = accept != mark.kind.adds
                }
                if paragraph != before { paragraph.originalXML = nil }
                if markGoes {
                    joining = paragraph
                } else {
                    result.append(.paragraph(paragraph))
                }
            case .table(var table):
                flushJoining()
                for row in table.rows.indices {
                    for cell in table.rows[row].cells.indices {
                        table.rows[row].cells[cell].blocks = resolve(table.rows[row].cells[cell].blocks, accept: accept)
                        // A cell must still end in a paragraph.
                        if case .paragraph = table.rows[row].cells[cell].blocks.last {} else {
                            table.rows[row].cells[cell].blocks.append(.paragraph(Paragraph()))
                        }
                    }
                }
                result.append(.table(table))
            case .preserved:
                flushJoining()
                result.append(block)
            }
        }
        flushJoining()
        return result
    }

    /// Keeps what stays of a run of inlines, no longer marked as changed.
    static func resolve(_ inlines: [Inline], accept: Bool) -> [Inline] {
        inlines.compactMap { inline in
            var inline = inline
            if let revision = inline.revision {
                guard accept == revision.kind.adds else { return nil }
                inline.revision = nil
            }
            if let xml = inline.format.preservedPropertiesXML, xml.contains("rPrChange"),
               let resolved = resolvedRunProperties(xml, accept: accept) {
                inline.format = resolved
            }
            return inline
        }
    }

    /// Whether anything in the blocks is a tracked change.
    static func contains(_ blocks: [Block]) -> Bool {
        blocks.contains { block in
            switch block {
            case .paragraph(let paragraph):
                return paragraph.markRevision != nil || paragraph.inlines.contains { $0.revision != nil }
                    || paragraph.preservedPropertiesXML?.contains("pPrChange") == true
                    || paragraph.inlines.contains { $0.format.preservedPropertiesXML?.contains("rPrChange") == true }
            case .table(let table):
                return table.rows.contains { $0.cells.contains { contains($0.blocks) } }
            case .preserved:
                return false
            }
        }
    }

    // MARK: - Formatting changes

    private static func element(_ xml: String) -> XMLElement? {
        XMLLite.fragment(xml, namespaces: DOCXPatcher.namespaceBindings(for: xml))
    }

    private static func resolvedRunProperties(_ xml: String, accept: Bool) -> RunFormat? {
        guard let edited = DOCXPatcher.editing(xml, { rPr in
            guard let change = rPr.firstChild(named: "rPrChange") else { return }
            if accept {
                rPr.removeChild(change)
            } else {
                let old = change.firstChild(named: "rPr")?.children ?? []
                rPr.children.forEach(rPr.removeChild)
                for (index, child) in old.enumerated() { rPr.insertChild(child, at: index) }
            }
        }) else { return nil }
        let style = element(edited).map(PropertyReader.runStyle(from:)) ?? RunStyle()
        return RunFormat(style: style, original: style, preservedPropertiesXML: edited == "<w:rPr/>" ? nil : edited)
    }

    private static func resolveFormatting(of paragraph: inout Paragraph, accept: Bool) {
        guard let xml = paragraph.preservedPropertiesXML, xml.contains("pPrChange"),
              let edited = DOCXPatcher.editing(xml, { pPr in
                  guard let change = pPr.firstChild(named: "pPrChange") else { return }
                  pPr.removeChild(change)
                  guard !accept else { return }
                  // The properties as they were; the mark's formatting and the section stay.
                  let kept: Set<String> = ["rPr", "sectPr"]
                  pPr.children.filter { !kept.contains($0.name) }.forEach(pPr.removeChild)
                  for child in change.firstChild(named: "pPr")?.children ?? [] {
                      pPr.insertChild(child, at: pPr.children.count)
                  }
                  pPr.sortChildren(by: DOCXPatcher.paragraphPropertyOrder)
              }) else { return }
        let properties = element(edited).map(PropertyReader.paragraphProperties(from:)) ?? ParagraphProperties()
        paragraph.preservedPropertiesXML = edited
        paragraph.properties = properties
        paragraph.originalProperties = properties
    }
}
