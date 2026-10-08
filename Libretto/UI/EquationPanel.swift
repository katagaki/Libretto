import SwiftUI

/// Writes an equation on one line, seen as it will look, to put in at the
/// selection or in place of the equation it is on.
struct EquationPanel: View {
    @Bindable var state: EditorState
    @State private var linear = ""
    @State private var isEditing = false
    @Environment(\.colorScheme) private var colorScheme

    private var controller: DocumentTextController? { state.controller }

    private var preview: UIImage? {
        guard !linear.trimmed.isEmpty else { return nil }
        return MathRenderer.image(
            forXML: LinearMath.omml(linear), fontSize: 22, color: colorScheme == .dark ? .white : .black
        )?.image
    }

    var body: some View {
        Form {
            Section {
                TextField("Equation.Placeholder", text: $linear, axis: .vertical)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("equation.text")
                if let preview {
                    Image(uiImage: preview)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel(linear)
                }
            } footer: {
                Text("Equation.Footer")
            }
            Section {
                Button(isEditing ? "Equation.Update" : "Equation.Insert", systemImage: "function") {
                    controller?.insertEquation(linear.trimmed)
                    state.presentedPanel = nil
                }
                .disabled(linear.trimmed.isEmpty)
                .accessibilityIdentifier("equation.confirm")
                if isEditing {
                    Button("Equation.Delete", systemImage: "trash", role: .destructive) {
                        controller?.deleteSelectedEquation()
                        state.presentedPanel = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard let (_, xml) = controller?.selectedEquation else { return }
            isEditing = true
            linear = LinearMath.linear(fromXML: xml)
        }
    }
}
