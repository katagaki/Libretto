import UniformTypeIdentifiers

extension UTType {
    /// TypeScript, declared by the app. The system gives `.ts` to MPEG-2
    /// transport streams, so a TypeScript file usually arrives as one of those.
    static let typeScriptSource = UTType("com.microsoft.typescript") ?? .sourceCode
}

/// The programming language of a source file, which is opened as text and
/// coloured by its syntax.
enum SourceLanguage: String, CaseIterable, Sendable {
    case swift
    case python
    case javaScript
    case typeScript
    case html
    case css
    case shell

    /// The types Libretto opens as source, most particular first.
    static let contentTypes: [UTType] = [
        .swiftSource, .pythonScript, .typeScriptSource, .javaScript, .html, .css, .shellScript, .mpeg2TransportStream,
    ]

    var fileExtensions: [String] {
        switch self {
        case .swift: return ["swift"]
        case .python: return ["py"]
        case .javaScript: return ["js", "mjs", "cjs"]
        case .typeScript: return ["ts", "mts", "cts"]
        case .html: return ["html", "htm"]
        case .css: return ["css"]
        case .shell: return ["sh", "bash", "zsh"]
        }
    }

    /// The language of a file, from its name if it has one, or else its type.
    init?(contentType: UTType, filename: String?) {
        let pathExtension = (filename as NSString?)?.pathExtension.lowercased() ?? ""
        if let language = Self.allCases.first(where: { $0.fileExtensions.contains(pathExtension) }) {
            self = language
            return
        }
        switch contentType {
        case let type where type.conforms(to: .swiftSource): self = .swift
        case let type where type.conforms(to: .pythonScript): self = .python
        case let type where type.conforms(to: .typeScriptSource) || type.conforms(to: .mpeg2TransportStream):
            self = .typeScript
        case let type where type.conforms(to: .javaScript): self = .javaScript
        case let type where type.conforms(to: .html): self = .html
        case let type where type.conforms(to: .css): self = .css
        case let type where type.conforms(to: .shellScript): self = .shell
        default: return nil
        }
    }
}
