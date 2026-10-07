import SwiftUI

/// Edits the headers and footers: their text, the page number and count in
/// them, how they are aligned, and whether the first page and even pages
/// have their own.
struct HeaderFooterPanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    @State private var kind: HeaderFooterKind = .default

    private var references: HeaderFooterReferences { document.pageSetup.headerFooters }

    private var kinds: [HeaderFooterKind] {
        [.default] + (references.titlePage ? [.first] : []) + (document.evenAndOddHeaders ? [.even] : [])
    }

    var body: some View {
        Form {
            Section {
                Toggle("HeaderFooter.DifferentFirstPage", isOn: Binding(
                    get: { references.titlePage },
                    set: { isOn in change { $0.pageSetup.headerFooters.titlePage = isOn } }
                ))
                .accessibilityIdentifier("headerFooter.firstPage")
                Toggle("HeaderFooter.DifferentOddEven", isOn: Binding(
                    get: { document.evenAndOddHeaders },
                    set: { isOn in change { $0.evenAndOddHeaders = isOn } }
                ))
                if kinds.count > 1 {
                    Picker("HeaderFooter.Pages", selection: $kind) {
                        ForEach(kinds, id: \.self) { kind in Text(label(kind)).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            editor(isFooter: false)
            editor(isFooter: true)
        }
        .formStyle(.grouped)
        .onChange(of: kinds) { _, kinds in if !kinds.contains(kind) { kind = .default } }
    }

    private func label(_ kind: HeaderFooterKind) -> String {
        switch kind {
        case .default:
            return String(localized: document.evenAndOddHeaders ? "HeaderFooter.OddPages" : "HeaderFooter.AllPages")
        case .first: return String(localized: "HeaderFooter.FirstPage")
        case .even: return String(localized: "HeaderFooter.EvenPages")
        }
    }

    private func current(isFooter: Bool) -> HeaderFooterText? {
        document.headerFooter(kind, isFooter: isFooter, in: document.pageSetup)
    }

    private func editor(isFooter: Bool) -> some View {
        let text = current(isFooter: isFooter)
        return Section {
            TextField(
                isFooter ? "HeaderFooter.Footer.Placeholder" : "HeaderFooter.Header.Placeholder",
                text: Binding(get: { text?.text ?? "" }, set: { value in edit(isFooter: isFooter) { $0.text = value } }),
                axis: .vertical
            )
            .lineLimit(1...4)
            .accessibilityIdentifier(isFooter ? "footer.text" : "header.text")
            Picker("Paragraph.Alignment", selection: Binding(
                get: { text?.alignment ?? .leading },
                set: { value in edit(isFooter: isFooter) { $0.alignment = value } }
            )) {
                ForEach([ParagraphAlignment.leading, .center, .trailing], id: \.self) { alignment in
                    Image(systemName: alignment.symbolName).accessibilityLabel(alignment.label).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Button("HeaderFooter.PageNumber", systemImage: "number") {
                    edit(isFooter: isFooter) { $0.text += HeaderFooterText.pageNumberPlaceholder }
                }
                Spacer()
                Button("HeaderFooter.PageCount", systemImage: "doc.on.doc") {
                    edit(isFooter: isFooter) { $0.text += HeaderFooterText.pageCountPlaceholder }
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text(isFooter ? "HeaderFooter.Footer" : "HeaderFooter.Header")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !isFooter { Text("HeaderFooter.Fields") }
                if text?.hasRichContent == true, text?.isEdited == false { Text("HeaderFooter.RichContent") }
            }
        }
    }

    /// Changes the header or footer this kind of page shows, giving it a part of its own if it has none.
    private func edit(isFooter: Bool, _ change: (inout HeaderFooterText) -> Void) {
        let kind = kind
        self.change { document in
            let references = isFooter ? document.pageSetup.headerFooters.footers : document.pageSetup.headerFooters.headers
            if let id = references[kind], var text = document.headerFooters[id] {
                change(&text)
                text.isEdited = true
                document.headerFooters[id] = text
                return
            }
            // A new part looks like the default one, if there is one.
            var text = document.headerFooter(.default, isFooter: isFooter, in: document.pageSetup)
                .map { HeaderFooterText(text: "", alignment: $0.alignment, isFooter: isFooter,
                                        paragraphPropertiesXML: $0.paragraphPropertiesXML,
                                        runPropertiesXML: $0.runPropertiesXML) }
                ?? HeaderFooterText(text: "", isFooter: isFooter)
            change(&text)
            text.isEdited = true
            let id = document.unusedHeaderFooterID(isFooter: isFooter)
            document.headerFooters[id] = text
            if isFooter {
                document.pageSetup.headerFooters.footers[kind] = id
            } else {
                document.pageSetup.headerFooters.headers[kind] = id
            }
        }
    }

    private func change(_ edit: (inout WordDocument) -> Void) {
        state.controller?.flush()
        state.pendingScope = .headerFooter
        edit(&document)
    }
}
