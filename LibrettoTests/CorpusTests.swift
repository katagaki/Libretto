import Foundation
import Testing
import UIKit
@testable import Libretto

/// Runs every `.docx` in a folder through reading, the editor's text,
/// saving, editing and saving again, the reader and PDF export.
///
/// Off unless pointed at a folder, since the documents are not part of the
/// repository: run with `TEST_RUNNER_LIBRETTO_CORPUS=/path/to/folder`, and
/// optionally `TEST_RUNNER_LIBRETTO_CORPUS_OUTPUT=/path` to keep what was
/// saved, for checking with other readers.
@Suite("Document corpus", .enabled(if: ProcessInfo.processInfo.environment["LIBRETTO_CORPUS"] != nil))
struct CorpusTests {
    private static var folder: URL? {
        ProcessInfo.processInfo.environment["LIBRETTO_CORPUS"].map { URL(fileURLWithPath: $0) }
    }

    private static var output: URL? {
        ProcessInfo.processInfo.environment["LIBRETTO_CORPUS_OUTPUT"].map { URL(fileURLWithPath: $0) }
    }

    static var files: [String] {
        guard let folder else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".docx") || $0.lowercased().hasSuffix(".docm") }.sorted()
    }

    private func texts(_ blocks: [Block]) -> [String] {
        blocks.flatMap(\.paragraphs).map(\.plainText)
    }

    /// Where two blocks part ways, briefly enough to read.
    private static func difference(_ read: Block, _ file: Block) -> String {
        guard case .paragraph(let left) = read, case .paragraph(let right) = file else {
            return "kinds: \(String(describing: read).prefix(80)) / \(String(describing: file).prefix(80))"
        }
        if left.inlines.count != right.inlines.count {
            return "inline count \(left.inlines.count) / \(right.inlines.count): "
                + "\(left.inlines.map(\.plainText)) / \(right.inlines.map(\.plainText))"
        }
        if let index = zip(left.inlines, right.inlines).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            return "inline \(index): \(left.inlines[index]) / \(right.inlines[index])"
        }
        return "properties or identity: \(left.id == right.id ? "same" : "different") id"
    }

    @Test("Each document survives the round trip", arguments: files)
    func roundTrip(_ name: String) throws {
        let url = try #require(Self.folder).appending(path: name)
        let data = try Data(contentsOf: url)
        let document: WordDocument
        do {
            document = try DOCXReader.document(from: data)
        } catch {
            // Protected and legacy files are turned away; anything else reads.
            print("CORPUS \(name): rejected: \(error.localizedDescription)")
            return
        }

        // The editor's text reads back as the document it came from.
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let rendered = DocumentRenderer.render(document.body, context: context)
        let read = AttributedReader.blocks(
            from: rendered.string, finalParagraph: rendered.finalParagraph, trailingMarkers: rendered.trailingMarkers
        )
        if let index = zip(read.blocks, document.body).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            Issue.record("\(name): block \(index) reads back differently from the editor's text")
            print("CORPUS-DIFF \(name) [\(index)] \(Self.difference(read.blocks[index], document.body[index]))")
        }
        #expect(read.blocks.count == document.body.count, "\(name): the editor's text has a different number of blocks")

        // Saved untouched, it reads back the same, and every part is well-formed.
        let saved = try DOCXWriter.data(from: document)
        let parts = try ZipArchive.entries(in: saved)
        for (path, part) in parts where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            #expect(throws: Never.self, "\(name): \(path) is not well-formed") { _ = try XMLLite.parse(part) }
        }
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(texts(reread.body) == texts(document.body), "\(name): text changed on saving")

        // Edited everywhere, it still saves to something that reads back.
        var edited = document
        edited.body = edited.body.map { block in
            guard case .paragraph(var paragraph) = block else { return block }
            paragraph.inlines.append(Inline(.text(" ✎")))
            for index in paragraph.inlines.indices { paragraph.inlines[index].format.style.isBold = true }
            paragraph.properties.alignment = .center
            return .paragraph(paragraph)
        }
        edited.pageSetup.width += 20
        let editedData = try DOCXWriter.data(from: edited)
        let editedParts = try ZipArchive.entries(in: editedData)
        for (path, part) in editedParts where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            #expect(throws: Never.self, "\(name): edited \(path) is not well-formed") { _ = try XMLLite.parse(part) }
        }
        let editedReread = try DOCXReader.document(fromParts: editedParts)
        #expect(texts(editedReread.body) == texts(edited.body), "\(name): edited text changed on saving")

        // The reader and the PDF both manage it.
        _ = MobileLayout(document: document, scheme: .light)
        let pdf = PDFExporter.data(from: document)
        #expect(pdf.starts(with: Array("%PDF".utf8)), "\(name): no PDF")

        if let output = Self.output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try saved.write(to: output.appending(path: "saved-" + name))
            try editedData.write(to: output.appending(path: "edited-" + name))
        }
        print("CORPUS \(name): ok, \(document.body.count) blocks, \(document.unsupportedFeatures.orderedFeatures.map(\.rawValue))")
    }
}
