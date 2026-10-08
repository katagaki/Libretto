import SwiftUI

/// Every paragraph style the document offers: to put the selection in, to
/// change, or to make anew from the selection's formatting.
struct StylesList: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    @State private var newName = ""

    private var controller: DocumentTextController? { state.controller }

    private var styles: [StyleSheet.Style] {
        let used = Set(document.allParagraphs.compactMap(\.properties.styleID))
        return document.styles.offeredParagraphStyles(using: used)
    }

    /// The style the selection's paragraph is in.
    private var currentID: String? {
        guard let controller else { return nil }
        let location = controller.textView.selectedRange.location
        let paragraph = document.allParagraphs.isEmpty ? nil : controller.paragraphStyleID(at: location)
        return paragraph ?? document.styles.defaultParagraphStyleID
    }

    var body: some View {
        Form {
            Section {
                TextField("Styles.New.Placeholder", text: $newName)
                Button("Styles.New", systemImage: "plus") {
                    controller?.createStyleFromSelection(name: newName.trimmed)
                    newName = ""
                }
                .disabled(newName.trimmed.isEmpty)
                .accessibilityIdentifier("styles.create")
            } footer: {
                Text("Styles.New.Footer")
            }
            Section("Styles.Section.All") {
                ForEach(styles, id: \.id) { style in
                    HStack {
                        Button {
                            controller?.applyParagraphStyle(id: style.id)
                        } label: {
                            HStack {
                                Text(style.name)
                                    .font(preview(style.id))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)
                                Spacer()
                                if currentID == style.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        NavigationLink {
                            StyleEditor(document: $document, state: state, styleID: style.id)
                        } label: {
                            EmptyView()
                        }
                        .frame(width: 24)
                        .accessibilityLabel("Styles.Modify")
                    }
                    .accessibilityIdentifier("styles.\(style.id)")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Styles.Title")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The style's font, at a size that fits a list.
    private func preview(_ id: String) -> Font {
        var run = document.styles.resolvedRunStyle(RunStyle(), paragraphStyleID: id)
        run.fontSize = min(36, max(20, run.fontSize ?? 22))
        return Font(Typography.font(for: run, styles: document.styles))
    }
}

/// Changes one style's definition: its font and emphasis, colour, alignment and spacing.
struct StyleEditor: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    let styleID: String

    private var controller: DocumentTextController? { state.controller }
    private var style: StyleSheet.Style? { document.styles.styles[styleID] }
    private var run: RunStyle { document.styles.resolvedRunStyle(RunStyle(), paragraphStyleID: styleID) }
    private var paragraph: ParagraphProperties {
        document.styles.resolvedParagraphProperties(ParagraphProperties(styleID: styleID))
    }

    var body: some View {
        Form {
            Section("Format.Section.Text") {
                NavigationLink {
                    FontList(state: state, current: .some(run.fontName)) { name in change { $0.runStyle.fontName = name } }
                } label: {
                    LabeledContent("Format.Font", value: run.fontName.map(fontLabel) ?? String(localized: "Font.Default"))
                }
                Stepper(
                    String(format: String(localized: "Styles.Size"), FormatPanel.points(run.fontSize ?? 22)),
                    onIncrement: { change { $0.runStyle.fontSize = min(192, (run.fontSize ?? 22) + 2) } },
                    onDecrement: { change { $0.runStyle.fontSize = max(2, (run.fontSize ?? 22) - 2) } }
                )
                Toggle("Toolbar.Bold", isOn: Binding(get: { run.isBold ?? false }, set: { value in change { $0.runStyle.isBold = value } }))
                Toggle("Toolbar.Italic", isOn: Binding(get: { run.isItalic ?? false }, set: { value in change { $0.runStyle.isItalic = value } }))
                Toggle("Toolbar.Underline", isOn: Binding(get: { run.underline ?? false }, set: { value in change { $0.runStyle.underline = value } }))
                SystemColorSwatches(
                    role: .text,
                    selectedHex: run.colorHex.map { "FF" + $0 },
                    customColor: Binding(
                        get: { Color(argbHex: run.colorHex) ?? .primary },
                        set: { color in change { $0.runStyle.colorHex = color.argbHex.map { String($0.suffix(6)) } } }
                    ),
                    onSelect: { swatch in change { $0.runStyle.colorHex = String(swatch.argbHex.suffix(6)) } },
                    onClear: { change { $0.runStyle.colorHex = nil } }
                )
            }
            Section("Paragraph.Section.Alignment") {
                Picker("Paragraph.Alignment", selection: Binding(
                    get: { paragraph.alignment ?? .leading },
                    set: { value in change { $0.paragraphProperties.alignment = value } }
                )) {
                    ForEach(ParagraphAlignment.allCases, id: \.self) { alignment in
                        Image(systemName: alignment.symbolName).accessibilityLabel(alignment.label).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Paragraph.Section.Spacing") {
                Stepper(
                    String(format: String(localized: "Paragraph.SpacingBefore"), (paragraph.spacingBefore ?? 0) / 20),
                    onIncrement: { change { $0.paragraphProperties.spacingBefore = (paragraph.spacingBefore ?? 0) + 120 } },
                    onDecrement: { change { $0.paragraphProperties.spacingBefore = max(0, (paragraph.spacingBefore ?? 0) - 120) } }
                )
                Stepper(
                    String(format: String(localized: "Paragraph.SpacingAfter"), (paragraph.spacingAfter ?? 0) / 20),
                    onIncrement: { change { $0.paragraphProperties.spacingAfter = (paragraph.spacingAfter ?? 0) + 120 } },
                    onDecrement: { change { $0.paragraphProperties.spacingAfter = max(0, (paragraph.spacingAfter ?? 0) - 120) } }
                )
                Toggle("Paragraph.KeepWithNext", isOn: Binding(
                    get: { paragraph.keepNext ?? false },
                    set: { value in change { $0.paragraphProperties.keepNext = value } }
                ))
            }
            Section {
                Button("Styles.UpdateToMatch", systemImage: "arrow.triangle.2.circlepath") {
                    controller?.updateStyleToMatchSelection(styleID)
                }
            } footer: {
                Text("Styles.Modify.Footer")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(style?.name ?? styleID)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fontLabel(_ name: String) -> String {
        switch name {
        case RunStyle.minorThemeFont:
            return String(format: String(localized: "Font.Theme.Body"), document.styles.minorFont ?? "")
        case RunStyle.majorThemeFont:
            return String(format: String(localized: "Font.Theme.Headings"), document.styles.majorFont ?? "")
        default:
            return name
        }
    }

    private func change(_ edit: (inout StyleSheet.Style) -> Void) {
        controller?.modifyStyle(styleID, edit)
    }
}
