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
            if state.viewMode == .page {
                FloatingActionBar(state: state, namespace: panelTransition)
                    .padding(.bottom, 8)
            } else {
                editButton
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
            .toolbar { undoToolbar }
            .toolbar { moreToolbar }
            .toolbar { sharingToolbar }
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

    @ViewBuilder
    private var content: some View {
        switch state.viewMode {
        case .page:
            PageView(document: wordDocument, state: state)
                .ignoresSafeArea(.container, edges: .bottom)
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
        case .paragraph: ParagraphPanel(state: state)
        case .pageSetup: PageSetupPanel(document: wordDocument, state: state)
        case .table: TablePanel(state: state)
        case .insertTable: InsertTablePanel(state: state)
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

    @ToolbarContentBuilder
    private var undoToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Toolbar.Undo", systemImage: "arrow.uturn.backward") {
                state.controller?.flush()
                history.undo()
            }
            .disabled(!history.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityIdentifier("undo")
            if horizontalSizeClass != .compact {
                redoButton
            }
        }
    }

    private var redoButton: some View {
        Button("Toolbar.Redo", systemImage: "arrow.uturn.forward") { history.redo() }
            .disabled(!history.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityIdentifier("redo")
    }

    /// Secondary actions are gathered into the navigation bar's "…" menu.
    @ToolbarContentBuilder
    private var moreToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .secondaryAction) {
            // A narrow bar has no room for Redo and would push it into this
            // menu itself, below everything here. Placing it keeps Source Code last.
            if horizontalSizeClass == .compact {
                redoButton
            }
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
            Section {
                Link(destination: URL(string: "https://github.com/katagaki/Libretto")!) {
                    Label("Toolbar.SourceCode", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
    }

    private var export: DocumentExport {
        DocumentExport(
            document: document.document,
            name: fileName.map { ($0 as NSString).deletingPathExtension } ?? String(localized: "Document.DefaultName")
        )
    }

    @ToolbarContentBuilder
    private var sharingToolbar: some ToolbarContent {
        // Declared before the share button so it sits beside it on the inside.
        if !document.unsupportedFeatures.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.isShowingUnsupportedFeatureNotice = true
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityIdentifier("unsupportedFeatures")
                .accessibilityLabel("Toolbar.UnsupportedFeatures.Label")
                .popover(isPresented: $state.isShowingUnsupportedFeatureNotice) {
                    UnsupportedFeatureNotice(report: document.unsupportedFeatures)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            ShareLink(item: export, preview: SharePreview(export.name, image: Image(systemName: "doc.text")))
                .accessibilityLabel("Toolbar.Share.Label")
        }
    }
}

/// What the toolbar's warning button says: which parts of the file Libretto
/// can only show and keep, and that macros never run.
///
/// A popover rather than an alert: nothing here needs deciding, so it has no
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
                // A popover sizes itself to its content, and without this the
                // message is laid out on one unbroken line.
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
        .padding(20)
        .frame(idealWidth: 300, maxWidth: 340, alignment: .leading)
        // iPhone turns a popover into a sheet unless it is told not to.
        .presentationCompactAdaptation(.popover)
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
