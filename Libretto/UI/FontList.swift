import SwiftUI
import UIKit

/// Picks the font for the selection: the theme's body and heading fonts,
/// the fonts the document already uses, then every font on the device.
struct FontList: View {
    @Bindable var state: EditorState
    /// The font shown as chosen, and what choosing one does: by default, the selection's.
    var current: String??
    var onPick: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var controller: DocumentTextController? { state.controller }
    private var document: WordDocument? { controller?.document }
    private var selected: String? { current ?? state.selectionFormat.fontName }

    private static let installed = UIFont.familyNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    var body: some View {
        List {
            if search.isEmpty {
                if let styles = document?.styles, styles.minorFont != nil || styles.majorFont != nil {
                    Section("Font.Section.Theme") {
                        if let body = styles.minorFont {
                            row(RunStyle.minorThemeFont, title: String(format: String(localized: "Font.Theme.Body"), body),
                                previewFamily: body)
                        }
                        if let headings = styles.majorFont {
                            row(RunStyle.majorThemeFont,
                                title: String(format: String(localized: "Font.Theme.Headings"), headings),
                                previewFamily: headings)
                        }
                    }
                }
                let used = document?.fontNames ?? []
                if !used.isEmpty {
                    Section("Font.Section.Document") {
                        ForEach(used, id: \.self) { name in row(name, title: name, previewFamily: name) }
                    }
                }
            }
            Section("Font.Section.All") {
                ForEach(Self.installed.filter { search.isEmpty || $0.localizedStandardContains(search) }, id: \.self) {
                    name in row(name, title: name, previewFamily: name)
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Format.Font")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ name: String, title: String, previewFamily: String) -> some View {
        Button {
            if let onPick { onPick(name) } else { controller?.setFont(name) }
            dismiss()
        } label: {
            HStack {
                Text(title)
                    .font(Self.preview(previewFamily))
                    .foregroundStyle(Color.primary)
                Spacer()
                if selected == name {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("font.\(name)")
    }

    /// The family itself, or what Libretto draws it with if the device lacks it.
    private static func preview(_ family: String) -> Font {
        let style = RunStyle(fontName: family, fontSize: 34)
        return Font(Typography.font(for: style, styles: StyleSheet()))
    }
}

extension WordDocument {
    /// Fonts the document's text and styles name, in alphabetical order.
    var fontNames: [String] {
        var names: Set<String> = []
        for paragraph in allParagraphs {
            for inline in paragraph.inlines { if let name = inline.format.style.fontName { names.insert(name) } }
        }
        for style in styles.styles.values { if let name = style.runStyle.fontName { names.insert(name) } }
        if let name = styles.defaultRunStyle.fontName { names.insert(name) }
        names.remove(RunStyle.minorThemeFont)
        names.remove(RunStyle.majorThemeFont)
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
