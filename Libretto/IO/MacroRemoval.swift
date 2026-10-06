import Foundation

extension WordDocument {
    /// The same document as a plain `.docx`: the VBA project and everything
    /// pointing at it taken out, and the main part typed as a macro-free one.
    ///
    /// Libretto never runs macros; this is for saving a `.docm` as a `.docx`,
    /// which Word refuses to open if it still declares a macro project.
    var withoutMacros: WordDocument {
        guard hasMacros else { return self }
        var copy = self
        var parts = package.parts
        let isMacroPart = { (path: String) -> Bool in
            let name = path.lowercased()
            return name.hasSuffix("vbaproject.bin") || name.hasSuffix("vbadata.xml")
                || name.hasSuffix("vbaproject.bin.rels")
        }
        for path in parts.keys where isMacroPart(path) { parts[path] = nil }

        let relationshipsPath = DOCXPaths.relationshipsPath(for: package.documentPath)
        if let data = parts[relationshipsPath] {
            let xml = String(decoding: data, as: UTF8.self)
                .replacing(#/<Relationship\b[^>]*vbaProject[^>]*/>/#, with: "")
            parts[relationshipsPath] = Data(xml.utf8)
        }
        if let data = parts["[Content_Types].xml"] {
            let xml = String(decoding: data, as: UTF8.self)
                .replacing(#/<Override\b[^>]*(vbaProject|vbaData)[^>]*/>/#, with: "")
                .replacing(#/<Default\b[^>]*vbaProject[^>]*/>/#, with: "")
                .replacingOccurrences(
                    of: "application/vnd.ms-word.document.macroEnabled.main+xml",
                    with: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
                )
            parts["[Content_Types].xml"] = Data(xml.utf8)
        }
        copy.package.parts = parts
        copy.package.relationships = package.relationships.filter { !$0.value.type.contains("vbaProject") }
        copy.unsupportedFeatures.features.remove(.macros)
        return copy
    }
}
