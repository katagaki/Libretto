import SwiftUI

/// The Liquid Glass bar that floats over the pages, keeping the common
/// formatting and insertion actions within thumb reach.
struct FloatingActionBar: View {
    @Bindable var state: EditorState
    /// Lets the panels this bar opens zoom out of the button that opened them.
    var namespace: Namespace.ID

    private static let selectionActionsID = "selectionActions"

    private var format: SelectionFormat { state.selectionFormat }
    private var controller: DocumentTextController? { state.controller }

    var body: some View {
        // The full set of groups is wider than an iPhone, so the bar scrolls
        // sideways rather than clipping its end groups.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        group {
                            styleMenu
                            action("bold", isOn: format.isBold, label: "Toolbar.Bold") { controller?.toggleBold() }
                            action("italic", isOn: format.isItalic, label: "Toolbar.Italic") {
                                controller?.toggleItalic()
                            }
                            action("underline", isOn: format.isUnderlined, label: "Toolbar.Underline") {
                                controller?.toggleUnderline()
                            }
                            panelAction("paintpalette", label: "ActionBar.Format", panel: .format)
                        }

                        group {
                            action(format.alignment.symbolName, isOn: false, label: "ActionBar.Alignment") {
                                controller?.cycleAlignment()
                            }
                            action("list.bullet", isOn: format.listKind == .bulleted, label: "ActionBar.Bullets") {
                                controller?.toggleList(.bulleted)
                            }
                            action("list.number", isOn: format.listKind == .numbered, label: "ActionBar.Numbering") {
                                controller?.toggleList(.numbered)
                            }
                            panelAction("text.line.spacing", label: "ActionBar.Paragraph", panel: .paragraph)
                        }

                        group {
                            insertMenu
                            panelAction("doc.badge.gearshape", label: "ActionBar.PageSetup", panel: .pageSetup)
                        }

                        if state.selectedTableID != nil {
                            tableGroup.id(Self.selectionActionsID)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .animation(.snappy(duration: 0.2), value: state.selectedTableID)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // What can be done to a table just picked out sits at the far end
            // of the bar; bring it into view rather than leave it to be found.
            .onChange(of: state.selectedTableID) { _, selected in
                guard selected != nil else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(Self.selectionActionsID, anchor: .trailing) }
            }
        }
        .frame(height: 56)
    }

    private var styleMenu: some View {
        Menu {
            Picker("ActionBar.Style", selection: Binding(
                get: { format.styleChoice },
                set: { choice in if let choice { controller?.applyParagraphStyle(choice) } }
            )) {
                ForEach(ParagraphStyleChoice.allCases) { choice in
                    Text(choice.label).tag(Optional(choice))
                }
            }
        } label: {
            menuLabel("textformat")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("paragraphStyle")
        .accessibilityLabel("ActionBar.Style")
    }

    private var insertMenu: some View {
        Menu {
            Button("Insert.Table", systemImage: "tablecells") { state.presentedPanel = .insertTable }
            Button("Insert.Picture", systemImage: "photo") { state.isPickingPhoto = true }
            Button("Insert.PageBreak", systemImage: "doc.on.doc") { controller?.insertPageBreak() }
        } label: {
            menuLabel("plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("insert")
        .accessibilityLabel("ActionBar.Insert")
    }

    /// What can be done to the table the selection is on.
    private var tableGroup: some View {
        group {
            panelAction("tablecells", label: "ActionBar.EditTable", panel: .table)
                .accessibilityIdentifier("editTable")
            action("trash", isOn: false, label: "ActionBar.DeleteTable") {
                controller?.deleteSelectedTable()
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func menuLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 40, height: 40)
            .foregroundStyle(Color.primary)
            .contentShape(.circle)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func action(
        _ symbol: String, isOn: Bool, label: LocalizedStringKey, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                // A round highlight, so an active control reads as a lit key.
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("action.\(symbol)")
    }

    /// A button that opens a panel and acts as that panel's zoom source.
    private func panelAction(_ symbol: String, label: LocalizedStringKey, panel: EditorPanel) -> some View {
        action(symbol, isOn: state.presentedPanel == panel, label: label) {
            state.presentedPanel = panel
        }
        .matchedTransitionSource(id: panel, in: namespace)
    }
}
