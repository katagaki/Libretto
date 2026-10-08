import SwiftUI

/// Refers to a heading or a bookmark elsewhere in the document: its text,
/// or the page it is on, as a field that updates.
struct CrossReferencePanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    @State private var showsPage = false

    private var controller: DocumentTextController? { state.controller }

    var body: some View {
        Form {
            Section {
                Picker("CrossReference.Insert", selection: $showsPage) {
                    Text("CrossReference.Text").tag(false)
                    Text("CrossReference.Page").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            let headings = document.body.isEmpty ? [] : controller?.headings ?? []
            if !headings.isEmpty {
                Section("Navigator.Headings") {
                    ForEach(headings) { heading in
                        Button {
                            guard let controller else { return }
                            refer(to: controller.bookmarkHeading(heading))
                        } label: {
                            Text(heading.text)
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(heading.level - 1) * 16)
                        }
                    }
                }
            }
            let names = (document.body.isEmpty ? [:] : controller?.bookmarkRanges ?? [:]).keys
                .filter { !BookmarkAnchors.isHidden($0) }.sorted()
            Section("Navigator.Bookmarks") {
                if names.isEmpty { Text("Navigator.NoBookmarks").foregroundStyle(.secondary) }
                ForEach(names, id: \.self) { name in
                    Button { refer(to: name) } label: {
                        Label(name, systemImage: "bookmark").foregroundStyle(Color.primary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func refer(to name: String) {
        controller?.insertField((showsPage ? "PAGEREF " : "REF ") + name + " \\h")
        state.presentedPanel = nil
    }
}
