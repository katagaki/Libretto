import PhotosUI
import SwiftUI

/// The document's root view: the pages or the reader, the floating action
/// bar, and the navigation bar's controls.
struct DocumentView: View {
    @Binding var document: LibrettoDocument
    var fileName: String?
    @State private var state = EditorState()
    @State private var history = DocumentHistory()
    @State private var photo: PhotosPickerItem?
    /// The mode this window was last in, so it comes back the same way.
    @SceneStorage("viewMode") private var storedMode: String?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var panelTransition

    private var wordDocument: Binding<WordDocument> { $document.document }

    var body: some View {
        // A stack rather than an overlay: the pages run under the home
        // indicator, but the bar must stay clear of it, where taps go to the system.
        ZStack(alignment: .bottom) {
            content
            // Code is edited as text: there is nothing to format.
            if !isCode {
                if state.viewMode == .page {
                    if !state.isFinding {
                        FloatingActionBar(state: state, namespace: panelTransition)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    }
                } else {
                    editButton
                }
            }
        }
            .background(Color(uiColor: .secondarySystemBackground))
            .onAppear {
                if let storedMode, let mode = ViewMode(rawValue: storedMode) {
                    state.viewMode = mode
                } else {
                    // A phone opens documents to read; anything wider, to work on.
                    state.viewMode = horizontalSizeClass == .compact ? .mobile : .page
                }
                attachHistory()
            }
            .onChange(of: undoManager) { _, _ in attachHistory() }
            .onChange(of: document.document) { old, new in
                history.record(from: old, to: new, scope: state.pendingScope)
                state.pendingScope = .other
            }
            .toolbar { navigationToolbar }
            .sheet(item: $state.presentedPanel) { panel in
                NavigationStack {
                    panelContent(panel)
                        .navigationTitle(panel.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationBarBackButtonHidden()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                // `.confirm` is the SDK's label-less Done button.
                                Button(role: .confirm) { state.presentedPanel = nil }
                            }
                        }
                }
                .navigationTransition(.zoom(sourceID: panel, in: panelTransition))
                // Half height only: the document stays in view beside the
                // panel, so a change can be seen as it is made. Longer panels
                // scroll within the sheet rather than growing it.
                .presentationDetents([.medium])
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.hidden)
                .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: $state.isShowingUnsupportedFeatureNotice) {
                UnsupportedFeatureNotice(report: document.unsupportedFeatures)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .photosPicker(isPresented: $state.isPickingPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        state.errorMessage = String(localized: "Alert.Picture.Failed")
                        return
                    }
                    state.controller?.insertImage(data)
                }
            }
            .alert(
                "Alert.Error.Title",
                isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.errorMessage = nil } }
                )
            ) {
                Button("Common.OK", role: .cancel) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
    }

    /// Whether the document is source code, which opens in the code editor.
    private var isCode: Bool { document.document.sourceLanguage != nil }

    @ViewBuilder
    private var content: some View {
        if let language = document.document.sourceLanguage {
            CodeEditorView(document: wordDocument, language: language, state: state)
                .ignoresSafeArea(edges: .bottom)
        } else {
            pagesOrReader
        }
    }

    @ViewBuilder
    private var pagesOrReader: some View {
        switch state.viewMode {
        case .page:
            PageView(document: wordDocument, state: state)
                .ignoresSafeArea(edges: .bottom)
        case .mobile:
            MobileReaderView(document: document.document)
        }
    }

    /// The reader is for reading; this is the way back to editing.
    private var editButton: some View {
        HStack {
            Spacer()
            Button {
                setMode(.page)
            } label: {
                Label("Mobile.Edit", systemImage: "pencil")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityIdentifier("editInPageView")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Opens a panel, on the pages, where panels act on the selection.
    private func openPanel(_ panel: EditorPanel) {
        setMode(.page)
        state.presentedPanel = panel
    }

    /// Opens the find bar. The reader has none, so find goes to the pages.
    private func find() {
        if isCode {
            state.codeEditor?.showFind()
        } else if state.viewMode == .page, let controller = state.controller {
            controller.showFind()
        } else {
            state.wantsFind = true
            setMode(.page)
        }
    }

    private func setMode(_ mode: ViewMode) {
        guard mode != state.viewMode else { return }
        // Typing still on its way to the document goes with it.
        state.controller?.flush()
        state.presentedPanel = nil
        withAnimation(.snappy(duration: 0.25)) { state.viewMode = mode }
        storedMode = mode.rawValue
    }

    // MARK: - Panels

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .format: FormatPanel(state: state)
        case .paragraph: ParagraphPanel(document: wordDocument, state: state)
        case .pageSetup: PageSetupPanel(document: wordDocument, state: state)
        case .table: TablePanel(document: wordDocument, state: state)
        case .insertTable: InsertTablePanel(state: state)
        case .link: LinkPanel(state: state)
        case .headerFooter: HeaderFooterPanel(document: wordDocument, state: state)
        case .comments: CommentsPanel(document: wordDocument, state: state)
        case .review: ReviewPanel(document: wordDocument, state: state)
        case .notes: NotesPanel(document: wordDocument, state: state)
        case .navigator: NavigatorPanel(document: wordDocument, state: state)
        case .crossReference: CrossReferencePanel(document: wordDocument, state: state)
        case .symbols: SymbolPanel(state: state)
        case .picture: PicturePanel(document: wordDocument, state: state)
        case .equation: EquationPanel(state: state)
        }
    }

    // MARK: - Toolbars

    private func attachHistory() {
        let document = $document
        history.attach(
            to: undoManager,
            read: { document.wrappedValue.document },
            write: { document.wrappedValue.document = $0 },
            restored: { _, _ in /* The page view renders whatever the document now is. */ }
        )
    }

    /// On iPad the everyday actions sit in the bar and the rest in the "…"
    /// menu. A phone has room only for undo and redo, so everything else is
    /// gathered into the menu. A menu of its own rather than secondary
    /// actions, which iPad would spread across the bar.
    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        if horizontalSizeClass == .regular {
            ToolbarItemGroup(placement: .primaryAction) { editButtons }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) { undoButtons }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { findButton }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { shareButton }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                moreMenu {
                    panelButtons
                    viewModePicker
                    Section { sourceCodeLink }
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) { undoButtons }
            ToolbarItem(placement: .primaryAction) {
                moreMenu {
                    Section { editButtons }
                    Section {
                        Button("Toolbar.Undo", systemImage: "arrow.uturn.backward", action: undo)
                            .disabled(!history.canUndo)
                        Button("Toolbar.Redo", systemImage: "arrow.uturn.forward") { history.redo() }
                            .disabled(!history.canRedo)
                    }
                    Section { findButton }
                    Section {
                        shareButton
                        sourceCodeLink
                    }
                    panelButtons
                    viewModePicker
                }
            }
        }
    }

    private func moreMenu(@ViewBuilder content: () -> some View) -> some View {
        Menu(content: content) {
            Label("Toolbar.More", systemImage: "ellipsis")
        }
    }

    @ViewBuilder
    private var editButtons: some View {
        Button("Toolbar.Cut", systemImage: "scissors") { sendEditAction(#selector(UIResponderStandardEditActions.cut(_:))) }
        Button("Toolbar.Copy", systemImage: "document.on.document") { sendEditAction(#selector(UIResponderStandardEditActions.copy(_:))) }
        Button("Toolbar.Paste", systemImage: "document.on.clipboard") { sendEditAction(#selector(UIResponderStandardEditActions.paste(_:))) }
    }

    @ViewBuilder
    private var undoButtons: some View {
        Button("Toolbar.Undo", systemImage: "arrow.uturn.backward", action: undo)
            .disabled(!history.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityIdentifier("undo")
        Button("Toolbar.Redo", systemImage: "arrow.uturn.forward") { history.redo() }
            .disabled(!history.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityIdentifier("redo")
    }

    private var shareButton: some View {
        ShareLink(item: export, preview: SharePreview(export.name, image: Image(systemName: "doc.text"))) {
            Label("Toolbar.Share.Label", systemImage: "square.and.arrow.up")
        }
    }

    private var findButton: some View {
        Button("Toolbar.Find", systemImage: "magnifyingglass", action: find)
            .accessibilityIdentifier("find")
    }

    private var sourceCodeLink: some View {
        Link(destination: URL(string: "https://github.com/katagaki/Libretto")!) {
            Label("Toolbar.SourceCode", systemImage: "chevron.left.forwardslash.chevron.right")
        }
    }

    @ViewBuilder
    private var panelButtons: some View {
        Section {
            if !isCode {
                Button("Toolbar.Comments", systemImage: "text.bubble") { openPanel(.comments) }
                    .accessibilityIdentifier("comments")
                Button("Toolbar.Review", systemImage: "pencil.and.list.clipboard") { openPanel(.review) }
                    .accessibilityIdentifier("review")
                Button("Toolbar.Notes", systemImage: "text.append") { openPanel(.notes) }
                    .accessibilityIdentifier("notes")
                Button("Toolbar.Navigator", systemImage: "list.bullet.indent") {
                    state.navigatorTab = .headings
                    openPanel(.navigator)
                }
                .accessibilityIdentifier("navigator")
                Button("Toolbar.UpdateFields", systemImage: "arrow.clockwise") {
                    setMode(.page)
                    state.controller?.updateTableOfContents()
                    state.controller?.updateFields()
                }
            }
            if !document.unsupportedFeatures.isEmpty {
                Button("Toolbar.UnsupportedFeatures.Label", systemImage: "exclamationmark.triangle") {
                    state.isShowingUnsupportedFeatureNotice = true
                }
                .accessibilityIdentifier("unsupportedFeatures")
            }
        }
    }

    @ViewBuilder
    private var viewModePicker: some View {
        if !isCode {
            Section {
                Picker(selection: Binding(get: { state.viewMode }, set: { setMode($0) })) {
                    ForEach(ViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbolName).tag(mode)
                    }
                } label: {
                    Label("Toolbar.ViewMode", systemImage: state.viewMode.symbolName)
                }
                .accessibilityIdentifier("viewMode")
            }
        }
    }

    private func undo() {
        state.controller?.flush()
        state.codeEditor?.flush()
        history.undo()
    }

    /// Sends cut, copy or paste to whichever text view is being edited.
    private func sendEditAction(_ action: Selector) {
        UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
    }

    private var export: DocumentExport {
        DocumentExport(
            document: document.document,
            name: fileName.map { ($0 as NSString).deletingPathExtension } ?? String(localized: "Document.DefaultName")
        )
    }
}

/// What the More menu's warning says: which parts of the file Libretto can
/// only show and keep, and that macros never run.
///
/// A sheet rather than an alert: nothing here needs deciding, so it has no
/// business stopping the user before they have seen their document.
private struct UnsupportedFeatureNotice: View {
    var report: UnsupportedFeatureReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notice.UnsupportedFeatures.Title", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Text("Notice.UnsupportedFeatures.Message")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.orderedFeatures, id: \.self) { feature in
                    Label(feature.label, systemImage: feature == .macros ? "curlybraces" : "circle.fill")
                        .font(.callout)
                        .labelStyle(BulletLabelStyle(isMacro: feature == .macros))
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct BulletLabelStyle: LabelStyle {
        var isMacro: Bool

        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                configuration.icon
                    .font(isMacro ? .caption : .system(size: 5))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                configuration.title
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
