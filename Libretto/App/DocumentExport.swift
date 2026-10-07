import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Wraps a document so it can be handed to `ShareLink`. The file is written
/// lazily, only when the user actually picks a share destination.
struct DocumentExport: Transferable, Sendable {
    var document: WordDocument
    var name: String

    static var transferRepresentation: some TransferRepresentation {
        // Offered first when there are macros to keep: sharing as `.docx`
        // would leave them behind.
        FileRepresentation(exportedContentType: .macroEnabledDocument) { export in
            SentTransferredFile(try export.write(extension: "docm") {
                try DOCXWriter.data(from: export.document)
            })
        }
        .suggestedFileName { $0.name + ".docm" }
        .exportingCondition { $0.document.hasMacros }

        // Source code goes as the file it is, never as a Word document.
        FileRepresentation(exportedContentType: .plainText) { export in
            SentTransferredFile(try export.write(extension: export.sourceExtension ?? "txt") {
                PlainText.data(from: export.document)
            })
        }
        .suggestedFileName { $0.name + "." + ($0.sourceExtension ?? "txt") }
        .exportingCondition { $0.sourceExtension != nil }

        FileRepresentation(exportedContentType: .openXMLDocument) { export in
            SentTransferredFile(try export.write(extension: "docx") {
                try DOCXWriter.data(from: export.document.withoutMacros)
            })
        }
        .suggestedFileName { $0.name + ".docx" }
        .exportingCondition { $0.sourceExtension == nil }

        FileRepresentation(exportedContentType: .pdf) { export in
            let document = export.document
            let data = await MainActor.run { PDFExporter.data(from: document) }
            return SentTransferredFile(try export.write(extension: "pdf") { data })
        }
        .suggestedFileName { $0.name + ".pdf" }
    }

    /// The extension source code is shared with, or `nil` for anything that is not code.
    private var sourceExtension: String? {
        document.sourceLanguage?.fileExtensions.first
    }

    private func write(
        extension pathExtension: String, encode: () throws -> Data
    ) throws -> URL {
        // A per-export directory keeps concurrent shares from colliding on name.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: "\(sanitizedName).\(pathExtension)")
        try encode().write(to: url, options: .atomic)
        return url
    }

    private var sanitizedName: String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Document" : cleaned
    }
}
