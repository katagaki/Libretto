import Foundation

enum DOCXError: LocalizedError {
    case missingMainDocument
    case missingBody

    var errorDescription: String? {
        switch self {
        case .missingMainDocument:
            return String(localized: "Error.MissingMainDocument")
        case .missingBody:
            return String(localized: "Error.MissingBody")
        }
    }
}

/// Namespaces and relationship types of WordprocessingML packages.
enum OOXML {
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let drawingNamespace = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let drawingMainNamespace = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let pictureNamespace = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    static let packageRelationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let contentTypesNamespace = "http://schemas.openxmlformats.org/package/2006/content-types"

    static let officeDocumentType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let stylesType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let numberingType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
    static let themeType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
    static let imageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    static let headerType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"
    static let footerType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"
    static let hyperlinkType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    static let settingsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings"
    static let commentsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
    static let commentsExtendedType = "http://schemas.microsoft.com/office/2011/relationships/commentsExtended"
    static let commentsContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"
    static let commentsExtendedContentType =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.commentsExtended+xml"
    static let w14Namespace = "http://schemas.microsoft.com/office/word/2010/wordml"
    static let w15Namespace = "http://schemas.microsoft.com/office/word/2012/wordml"
    static let headerContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"
    static let footerContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"

    static let numberingContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"

    /// The prefixes a freshly written document part declares.
    static let standardNamespaces: [String: String] = [
        "w": wordNamespace,
        "r": relationshipsNamespace,
        "wp": drawingNamespace,
        "a": drawingMainNamespace,
        "pic": pictureNamespace,
    ]
}

enum DOCXPaths {
    /// Resolves a relationship target against the part that holds the relationship.
    static func resolve(_ target: String, relativeTo source: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = source.split(separator: "/").map(String.init)
        // The part's own name; what is left is the folder it sits in.
        _ = components.popLast()
        for step in target.split(separator: "/") {
            switch step {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(step))
            }
        }
        return components.joined(separator: "/")
    }

    /// `word/document.xml` → `word/_rels/document.xml.rels`.
    static func relationshipsPath(for part: String) -> String {
        var components = part.split(separator: "/").map(String.init)
        let name = components.removeLast()
        return (components + ["_rels", name + ".rels"]).joined(separator: "/")
    }
}
