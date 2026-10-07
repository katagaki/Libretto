import SwiftUI

/// A modal panel presented over the document, as a sheet.
enum EditorPanel: String, Identifiable, Hashable {
    case format
    case paragraph
    case pageSetup
    case table
    case insertTable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .format: return String(localized: "Panel.Format.Title")
        case .paragraph: return String(localized: "Panel.Paragraph.Title")
        case .pageSetup: return String(localized: "Panel.PageSetup.Title")
        case .table: return String(localized: "Panel.Table.Title")
        case .insertTable: return String(localized: "Panel.InsertTable.Title")
        }
    }
}

/// How the document is shown.
enum ViewMode: String, CaseIterable, Identifiable {
    /// Pages at the document's own page size, editable.
    case page
    /// Reflowed to the width of the screen, for reading.
    case mobile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .page: return String(localized: "ViewMode.Page")
        case .mobile: return String(localized: "ViewMode.Mobile")
        }
    }

    var symbolName: String {
        switch self {
        case .page: return "doc.text"
        case .mobile: return "iphone"
        }
    }
}

/// What kind of change an edit was, so a run of the same kind undoes as one.
enum EditScope: Equatable {
    case typing
    case formatting
    case paragraphStyle
    case list
    case insertion
    case table
    case pageSetup
    case other

    /// Typing, and editing a table's text, arrive a keystroke at a time.
    var coalesces: Bool { self == .typing || self == .table }

    var actionName: String {
        switch self {
        case .typing: return String(localized: "Undo.Typing")
        case .formatting: return String(localized: "Undo.Formatting")
        case .paragraphStyle: return String(localized: "Undo.ParagraphStyle")
        case .list: return String(localized: "Undo.List")
        case .insertion: return String(localized: "Undo.Insertion")
        case .table: return String(localized: "Undo.Table")
        case .pageSetup: return String(localized: "Undo.PageSetup")
        case .other: return String(localized: "Undo.Edit")
        }
    }
}

/// How the text at the selection is formatted, for lighting up controls.
struct SelectionFormat: Equatable {
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStruckThrough = false
    var verticalAlignment: RunStyle.VerticalPosition = .baseline
    /// Half-points.
    var fontSize = 22
    /// The font the text resolves to, a theme font as `+minor` or `+major`.
    var fontName: String?
    var colorHex: String?
    var highlight: String?
    var alignment: ParagraphAlignment = .leading
    var styleChoice: ParagraphStyleChoice?
    var listKind: ListKind?
    /// Twentieths of a point.
    var spacingBefore = 0
    var spacingAfter = 0
    var lineSpacing: Double = 1
}

/// Everything about the editing session that isn't part of the document itself.
@MainActor
@Observable
final class EditorState {
    var viewMode: ViewMode = .page
    var presentedPanel: EditorPanel? {
        didSet {
            // Panels edit the document directly, so it must be up to date first.
            if presentedPanel != nil { controller?.flush() }
        }
    }
    var selectionFormat = SelectionFormat()
    /// The table the selection is on, if any, which the table panel edits.
    var selectedTableID: Table.ID?
    /// What the last change was, read by the history when it records it.
    var pendingScope: EditScope = .other
    var errorMessage: String?
    var isShowingUnsupportedFeatureNotice = false
    var isPickingPhoto = false
    /// Find was asked for from the reader, which has no find bar: the page
    /// view opens one once it is on screen.
    @ObservationIgnored var wantsFind = false
    /// The page view zooms out to fit; this is how far, for the zoom readout.
    var zoom: CGFloat = 1

    /// The page view's editor, while it is on screen.
    @ObservationIgnored weak var controller: DocumentTextController?
    /// The code editor, while a source file is open.
    @ObservationIgnored weak var codeEditor: CodeEditorController?
}
