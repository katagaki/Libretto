import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The Office Open XML document type, declared by the system.
    static let openXMLDocument = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
    /// The `.docm` document, which may carry macros. It does not conform to
    /// the plain document type, so it is asked about in its own right.
    static let macroEnabledDocument = UTType("org.openxmlformats.wordprocessingml.document.macroenabled") ?? .data
    /// Markdown, declared by the app. It conforms to plain text, so it is asked about first.
    static let markdownDocument = UTType("net.daringfireball.markdown") ?? .plainText
}

/// The app's document: a word-processing document, loaded from `.docx` or
/// `.docm`, or from a Markdown, source code or plain text file.
///
/// A `.docm` opens like any other document. Its macros are kept, and saved
/// back with it, but Libretto never runs them. A text file is saved back as
/// text, so any formatting given to it is not kept, and a Markdown file keeps
/// only the formatting Markdown has. Source code is set in a code font and
/// coloured by its syntax, and saved back as text.
struct LibrettoDocument: FileDocument {
    static let readableContentTypes: [UTType] = [
        .openXMLDocument, .macroEnabledDocument, .markdownDocument,
    ] + SourceLanguage.contentTypes + [.plainText]
    static let writableContentTypes: [UTType] = [
        .openXMLDocument, .macroEnabledDocument, .markdownDocument,
    ] + SourceLanguage.contentTypes + [.plainText]

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
        let filename = configuration.file.filename ?? configuration.file.preferredFilename
        if let language = SourceLanguage(contentType: configuration.contentType, filename: filename) {
            // A video sharing TypeScript's extension is no text to open.
            if configuration.contentType.conforms(to: .mpeg2TransportStream), data.prefix(4096).contains(0) {
                throw CocoaError(.fileReadCorruptFile)
            }
            document = PlainText.document(from: data, format: PlainText.codeFormat)
            document.sourceLanguage = language
        } else if configuration.contentType.conforms(to: .markdownDocument) {
            document = MarkdownReader.document(from: data)
        } else if configuration.contentType.conforms(to: .plainText) {
            document = PlainText.document(from: data)
        } else {
            document = try DOCXReader.document(from: data)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Text has no way to track changes; it is saved as it reads with them accepted.
        var text = document
        text.body = Revisions.resolve(document.body, accept: true)
        if configuration.contentType.conforms(to: .markdownDocument) {
            return FileWrapper(regularFileWithContents: MarkdownWriter.data(from: text))
        }
        if configuration.contentType.conforms(to: .plainText) || document.sourceLanguage != nil
            || SourceLanguage(contentType: configuration.contentType, filename: nil) != nil {
            return FileWrapper(regularFileWithContents: PlainText.data(from: text))
        }
        // A `.docx` cannot hold macros, and Word will not open one that claims to.
        let keepsMacros = configuration.contentType.conforms(to: .macroEnabledDocument)
        return FileWrapper(regularFileWithContents: try DOCXWriter.data(
            from: keepsMacros ? document : document.withoutMacros
        ))
    }
}
