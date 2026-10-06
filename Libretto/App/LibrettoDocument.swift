import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The Office Open XML document type, declared by the system.
    static let openXMLDocument = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
    /// The `.docm` document, which may carry macros. It does not conform to
    /// the plain document type, so it is asked about in its own right.
    static let macroEnabledDocument = UTType("org.openxmlformats.wordprocessingml.document.macroenabled") ?? .data
}

/// The app's document: a word-processing document, loaded from `.docx` or `.docm`.
///
/// A `.docm` opens like any other document. Its macros are kept, and saved
/// back with it, but Libretto never runs them.
struct LibrettoDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.openXMLDocument, .macroEnabledDocument]
    static let writableContentTypes: [UTType] = [.openXMLDocument, .macroEnabledDocument]

    var document: WordDocument

    /// What the opened file used that Libretto cannot edit. Empty for anything we
    /// authored ourselves.
    var unsupportedFeatures: UnsupportedFeatureReport { document.unsupportedFeatures }

    init() {
        document = WordDocument()
    }

    init(document: WordDocument) {
        self.document = document
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        document = try DOCXReader.document(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // A `.docx` cannot hold macros, and Word will not open one that claims to.
        let keepsMacros = configuration.contentType.conforms(to: .macroEnabledDocument)
        return FileWrapper(regularFileWithContents: try DOCXWriter.data(
            from: keepsMacros ? document : document.withoutMacros
        ))
    }
}
