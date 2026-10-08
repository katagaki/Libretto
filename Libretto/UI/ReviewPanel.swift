import SwiftUI

/// Tracked changes: recording them, stepping through them, and accepting or
/// rejecting them one at a time or all at once.
struct ReviewPanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    @AppStorage(Reviewer.nameKey) private var authorName = ""

    private var controller: DocumentTextController? { state.controller }
    private var hasChanges: Bool { Revisions.contains(document.body) }

    var body: some View {
        Form {
            Section {
                Toggle("Review.TrackChanges", isOn: Binding(
                    get: { document.trackRevisions },
                    set: { controller?.setTracking($0) }
                ))
                .accessibilityIdentifier("review.track")
            } footer: {
                Text("Review.TrackChanges.Footer")
            }

            Section {
                HStack {
                    Button("Review.Previous", systemImage: "chevron.up") { controller?.selectChange(forward: false) }
                    Spacer()
                    Text(String(format: String(localized: "Review.Count"), controller?.changeCount ?? 0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Review.Next", systemImage: "chevron.down") { controller?.selectChange(forward: true) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                HStack {
                    Button("Review.Accept", systemImage: "checkmark") { controller?.resolveChange(accept: true) }
                        .disabled(!state.isOnChange)
                    Spacer()
                    Button("Review.Reject", systemImage: "xmark") { controller?.resolveChange(accept: false) }
                        .disabled(!state.isOnChange)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Review.Section.Changes")
            }

            Section {
                Button("Review.AcceptAll", systemImage: "checkmark.circle") { controller?.resolveAllChanges(accept: true) }
                    .accessibilityIdentifier("review.acceptAll")
                Button("Review.RejectAll", systemImage: "xmark.circle", role: .destructive) {
                    controller?.resolveAllChanges(accept: false)
                }
            }
            .disabled(!hasChanges)

            Section {
                TextField("Comments.YourName.Placeholder", text: $authorName)
                    .textContentType(.name)
            } header: {
                Text("Comments.YourName")
            } footer: {
                Text("Comments.YourName.Footer")
            }
        }
        .formStyle(.grouped)
    }
}
