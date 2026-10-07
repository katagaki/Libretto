import SwiftUI

/// The document's comments, thread by thread in the order they come in the
/// text: adding one to the selection, replying, resolving, editing and deleting.
struct CommentsPanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    @AppStorage(Reviewer.nameKey) private var authorName = ""
    @State private var draft = ""
    @State private var replyingTo: String?
    @State private var replyDraft = ""
    @State private var editing: String?
    @State private var editDraft = ""

    private var controller: DocumentTextController? { state.controller }

    /// Comments that reply to none, in the order of the text they are on.
    private var threads: [Comment] {
        let paraIDs = Set(document.comments.compactMap(\.paraID))
        let ranges = controller?.commentRanges ?? [:]
        return document.comments.enumerated()
            .filter { $0.element.parentParaID.map { !paraIDs.contains($0) } ?? true }
            .sorted { (ranges[$0.element.id]?.location ?? .max, $0.offset) < (ranges[$1.element.id]?.location ?? .max, $1.offset) }
            .map(\.element)
    }

    private func replies(to comment: Comment) -> [Comment] {
        guard let paraID = comment.paraID else { return [] }
        return document.comments.filter { $0.parentParaID == paraID }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    TextField("Comments.New.Placeholder", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .accessibilityIdentifier("comment.draft")
                    Button("Comments.Add", systemImage: "plus.bubble") {
                        controller?.addComment(draft.trimmed)
                        draft = ""
                    }
                    .disabled(draft.trimmed.isEmpty)
                    .accessibilityIdentifier("comment.add")
                } footer: {
                    Text("Comments.New.Footer")
                }

                if threads.isEmpty {
                    ContentUnavailableView("Comments.None", systemImage: "text.bubble")
                }
                ForEach(threads) { thread in
                    Section {
                        card(thread, isReply: false)
                        ForEach(replies(to: thread)) { reply in card(reply, isReply: true) }
                        if replyingTo == thread.id { replyComposer(thread) }
                    }
                    .id(thread.id)
                }

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
            .onAppear {
                guard let id = state.focusedCommentID else { return }
                state.focusedCommentID = nil
                let thread = threadID(containing: id)
                DispatchQueue.main.async { proxy.scrollTo(thread, anchor: .top) }
            }
        }
    }

    private func threadID(containing id: String) -> String {
        guard let comment = document.comments.first(where: { $0.id == id }), let parent = comment.parentParaID,
              let root = document.comments.first(where: { $0.paraID == parent }) else { return id }
        return root.id
    }

    private func card(_ comment: Comment, isReply: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(comment.author.isEmpty ? String(localized: "Comment.DefaultAuthor") : comment.author)
                    .font(.subheadline.weight(.semibold))
                if let date = comment.dateValue {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                menu(comment, isReply: isReply)
            }
            if !isReply, let quote = controller?.commentQuote(comment.id), !quote.isEmpty {
                Text(quote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.yellow).frame(width: 2) }
            }
            if editing == comment.id {
                TextField("Comments.Edit.Placeholder", text: $editDraft, axis: .vertical)
                    .lineLimit(1...6)
                HStack {
                    Button("Common.Cancel") { editing = nil }
                    Spacer()
                    Button("Comments.Save") {
                        controller?.editComment(comment.id, text: editDraft.trimmed)
                        editing = nil
                    }
                    .disabled(editDraft.trimmed.isEmpty)
                }
                .buttonStyle(.borderless)
            } else {
                Text(comment.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if comment.isDone, !isReply {
                Label("Comments.Resolved", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.leading, isReply ? 16 : 0)
        .opacity(comment.isDone ? 0.6 : 1)
        .contentShape(.rect)
        .onTapGesture { controller?.selectComment(comment.id) }
        .accessibilityIdentifier("comment.\(comment.id)")
    }

    private func menu(_ comment: Comment, isReply: Bool) -> some View {
        Menu {
            if !isReply {
                Button("Comments.Reply", systemImage: "arrowshape.turn.up.left") {
                    replyingTo = comment.id
                    replyDraft = ""
                }
                Button(comment.isDone ? "Comments.Reopen" : "Comments.Resolve",
                       systemImage: comment.isDone ? "arrow.uturn.backward.circle" : "checkmark.circle") {
                    controller?.setCommentDone(comment.id, !comment.isDone)
                }
            }
            Button("Comments.Edit", systemImage: "pencil") {
                editing = comment.id
                editDraft = comment.text
            }
            Button("Comments.Delete", systemImage: "trash", role: .destructive) {
                controller?.deleteComment(comment.id)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Comments.Actions")
    }

    private func replyComposer(_ thread: Comment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Comments.Reply.Placeholder", text: $replyDraft, axis: .vertical)
                .lineLimit(1...5)
            HStack {
                Button("Common.Cancel") { replyingTo = nil }
                Spacer()
                Button("Comments.Reply") {
                    controller?.reply(to: thread.id, text: replyDraft.trimmed)
                    replyingTo = nil
                }
                .disabled(replyDraft.trimmed.isEmpty)
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 16)
    }
}
