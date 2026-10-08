import SwiftUI

/// Finding one's way about the document: its headings, as an outline, and
/// its bookmarks, with new ones made at the selection.
struct NavigatorPanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    @State private var newBookmark = ""
    @State private var showsHidden = false

    enum Tab: String, CaseIterable, Identifiable {
        case headings, bookmarks
        var id: String { rawValue }
    }

    private var controller: DocumentTextController? { state.controller }

    var body: some View {
        Form {
            Section {
                Picker("Navigator.Show", selection: $state.navigatorTab) {
                    Text("Navigator.Headings").tag(Tab.headings)
                    Text("Navigator.Bookmarks").tag(Tab.bookmarks)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch state.navigatorTab {
            case .headings: headings
            case .bookmarks: bookmarks
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var headings: some View {
        // The document is read again whenever it changes: the binding is what tells this view it has.
        let entries = document.body.isEmpty ? [] : controller?.headings ?? []
        if entries.isEmpty {
            ContentUnavailableView("Navigator.NoHeadings", systemImage: "list.bullet.indent",
                                   description: Text("Navigator.NoHeadings.Description"))
        } else {
            Section {
                ForEach(entries) { entry in
                    Button {
                        controller?.goTo(entry.location)
                    } label: {
                        Text(entry.text)
                            .font(entry.level == 1 ? .body.weight(.semibold) : .body)
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                            .padding(.leading, CGFloat(entry.level - 1) * 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("heading.\(entry.location)")
                }
            }
        }
    }

    @ViewBuilder
    private var bookmarks: some View {
        Section {
            TextField("Navigator.Bookmark.Placeholder", text: $newBookmark)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Navigator.Bookmark.Add", systemImage: "bookmark") {
                controller?.addBookmark(newBookmark.trimmed)
                newBookmark = ""
            }
            .disabled(newBookmark.trimmed.isEmpty)
            .accessibilityIdentifier("bookmark.add")
        } footer: {
            Text("Navigator.Bookmark.Footer")
        }
        let ranges = document.body.isEmpty ? [:] : controller?.bookmarkRanges ?? [:]
        let names = ranges.keys.filter { showsHidden || !BookmarkAnchors.isHidden($0) }
            .sorted { (ranges[$0]?.location ?? 0, $0) < (ranges[$1]?.location ?? 0, $1) }
        Section {
            if names.isEmpty {
                Text("Navigator.NoBookmarks").foregroundStyle(.secondary)
            }
            ForEach(names, id: \.self) { name in
                Button {
                    if let range = ranges[name] { controller?.goTo(range.location, length: range.length) }
                } label: {
                    Label(name, systemImage: "bookmark")
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Comments.Delete", role: .destructive) { controller?.deleteBookmark(name) }
                }
                .accessibilityIdentifier("bookmark.\(name)")
            }
            Toggle("Navigator.ShowHidden", isOn: $showsHidden)
        }
    }
}
