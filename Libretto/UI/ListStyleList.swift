import SwiftUI

/// Bullets, numbering and multilevel lists to put the selection in, and
/// where its numbering starts.
struct ListStyleList: View {
    @Bindable var state: EditorState
    @State private var start = 1

    private var controller: DocumentTextController? { state.controller }

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 10)]

    var body: some View {
        Form {
            presets("List.Section.Bullets", ListPreset.bullets)
            presets("List.Section.Numbering", ListPreset.numbers)
            presets("List.Section.Multilevel", ListPreset.multilevel)
            Section {
                Stepper(String(format: String(localized: "List.StartAt"), start), value: $start, in: 0...999)
                Button("List.Restart", systemImage: "arrow.counterclockwise") { controller?.restartNumbering(at: start) }
                    .accessibilityIdentifier("list.restart")
                Button("List.Continue", systemImage: "arrow.down.to.line") { controller?.continueNumbering() }
            } header: {
                Text("List.Section.Numbers")
            }
            .disabled(state.selectionFormat.listKind != .numbered)
        }
        .formStyle(.grouped)
        .navigationTitle("List.Title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func presets(_ title: LocalizedStringKey, _ presets: [ListPreset]) -> some View {
        Section(title) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(presets) { preset in
                    Button {
                        controller?.applyListPreset(preset)
                    } label: {
                        Text(preset.sample)
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
                            .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("list.\(preset.rawValue)")
                }
            }
            .padding(.vertical, 4)
        }
    }
}
