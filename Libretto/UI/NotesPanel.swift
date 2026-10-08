import SwiftUI

/// The document's footnotes and endnotes, numbered as the text refers to
/// them: their text to edit, a way to their reference, and new ones to insert.
struct NotesPanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    @FocusState private var focused: String?

    private var controller: DocumentTextController? { state.controller }

    private var numbers: [String: String] { NoteNumbering.numbers(in: document) }

    /// The notes of a kind, in the order the text refers to them.
    private func notes(_ kind: NoteKind) -> [Note] {
        let order = NoteNumbering.references(in: document.body).filter { $0.kind == kind }.map { "\(kind.rawValue):\($0.id)" }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return document.notes.filter { $0.kind == kind && rank[$0.key] != nil }.sorted { rank[$0.key]! < rank[$1.key]! }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Button("Notes.InsertFootnote", systemImage: "text.append") { insert(.footnote, proxy: proxy) }
                        .accessibilityIdentifier("notes.insertFootnote")
                    Button("Notes.InsertEndnote", systemImage: "text.badge.plus") { insert(.endnote, proxy: proxy) }
                } footer: {
                    Text("Notes.Insert.Footer")
                }
                ForEach(NoteKind.allCases, id: \.self) { kind in
                    let notes = notes(kind)
                    if !notes.isEmpty {
                        Section(kind == .footnote ? "Notes.Footnotes" : "Notes.Endnotes") {
                            ForEach(notes) { note in row(note).id(note.key) }
                        }
                    }
                }
                if document.notes.isEmpty {
                    ContentUnavailableView("Notes.None", systemImage: "text.append")
                }
            }
            .formStyle(.grouped)
            .onAppear {
                guard let key = state.focusedNoteKey else { return }
                state.focusedNoteKey = nil
                DispatchQueue.main.async {
                    proxy.scrollTo(key, anchor: .center)
                    focused = key
                }
            }
        }
    }

    private func row(_ note: Note) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(numbers[note.key] ?? "")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            TextField("Notes.Placeholder", text: Binding(
                get: { note.text },
                set: { text in
                    state.controller?.flush()
                    state.pendingScope = .notes
                    if let index = document.notes.firstIndex(where: { $0.key == note.key }) {
                        document.notes[index].text = text
                    }
                }
            ), axis: .vertical)
            .lineLimit(1...6)
            .focused($focused, equals: note.key)
            .accessibilityIdentifier("note.\(note.key)")
            Menu {
                Button("Notes.GoToReference", systemImage: "arrow.turn.down.right") {
                    controller?.selectNoteReference(note.key)
                }
                Button("Comments.Delete", systemImage: "trash", role: .destructive) {
                    controller?.deleteNote(note.key)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Notes.Actions")
        }
    }

    private func insert(_ kind: NoteKind, proxy: ScrollViewProxy) {
        guard let key = controller?.insertNote(kind) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(key, anchor: .center)
            focused = key
        }
    }
}
