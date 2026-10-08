import SwiftUI

/// Character formatting: emphasis, size, colour and highlight.
struct FormatPanel: View {
    @Bindable var state: EditorState

    private var format: SelectionFormat { state.selectionFormat }
    private var controller: DocumentTextController? { state.controller }

    var body: some View {
        Form {
            Section("Format.Section.Text") {
                NavigationLink {
                    FontList(state: state)
                } label: {
                    LabeledContent("Format.Font", value: fontLabel)
                }
                .accessibilityIdentifier("font")
                HStack(spacing: 12) {
                    styleToggle("bold", label: "Toolbar.Bold", isOn: format.isBold) { controller?.toggleBold() }
                    styleToggle("italic", label: "Toolbar.Italic", isOn: format.isItalic) { controller?.toggleItalic() }
                    styleToggle("underline", label: "Toolbar.Underline", isOn: format.isUnderlined) {
                        controller?.toggleUnderline()
                    }
                    styleToggle("strikethrough", label: "Toolbar.Strikethrough", isOn: format.isStruckThrough) {
                        controller?.toggleStrikethrough()
                    }
                }
                HStack(spacing: 12) {
                    styleToggle("textformat.superscript", label: "Format.Superscript",
                                isOn: format.verticalAlignment == .superscript) {
                        controller?.toggleVerticalAlignment(.superscript)
                    }
                    styleToggle("textformat.subscript", label: "Format.Subscript",
                                isOn: format.verticalAlignment == .subscript) {
                        controller?.toggleVerticalAlignment(.subscript)
                    }
                }

                LabeledContent("Format.Text.Size") {
                    HStack(spacing: 16) {
                        stepButton("minus", label: "Format.Text.Size.Decrease", identifier: "fontSize.decrease") {
                            controller?.adjustFontSize(by: -1)
                        }
                        Text(Self.points(format.fontSize))
                            .font(.system(size: 17, weight: .medium))
                            .monospacedDigit()
                            .frame(minWidth: 36)
                            .accessibilityIdentifier("fontSize.value")
                        stepButton("plus", label: "Format.Text.Size.Increase", identifier: "fontSize.increase") {
                            controller?.adjustFontSize(by: 1)
                        }
                    }
                    .buttonStyle(.borderless)
                }

                SystemColorSwatches(
                    role: .text,
                    selectedHex: format.colorHex.map { "FF" + $0 },
                    customColor: Binding(
                        get: { Color(argbHex: format.colorHex) ?? .primary },
                        set: { controller?.setTextColor($0.argbHex) }
                    ),
                    onSelect: { controller?.setTextColor($0.argbHex) },
                    onClear: { controller?.setTextColor(nil) }
                )
            }

            Section("Format.Section.Highlight") {
                HighlightSwatches(selected: format.highlight) { controller?.setHighlight($0) }
            }

            Section("Format.Section.Effects") {
                Picker("Format.Underline", selection: Binding(
                    get: { format.underlineKind },
                    set: { controller?.setUnderline($0) }
                )) {
                    ForEach(underlineKinds, id: \.self) { kind in
                        Text(LocalizedStringKey("Underline.\(kind)")).tag(kind)
                    }
                }
                .accessibilityIdentifier("underlineKind")
                effect("Format.DoubleStrikethrough", \.isDoubleStruckThrough, isOn: format.isDoubleStruckThrough)
                effect("Format.SmallCaps", \.smallCaps, isOn: format.smallCaps)
                effect("Format.AllCaps", \.allCaps, isOn: format.allCaps)
                effect("Format.Outline", \.outline, isOn: format.outline)
                effect("Format.Shadow", \.shadow, isOn: format.shadow)
                effect("Format.Emboss", \.emboss, isOn: format.emboss)
                effect("Format.Engrave", \.imprint, isOn: format.imprint)
                Stepper(
                    Self.spacingLabel(format.characterSpacing),
                    onIncrement: { controller?.setCharacterSpacing(format.characterSpacing + 10) },
                    onDecrement: { controller?.setCharacterSpacing(format.characterSpacing - 10) }
                )
                .accessibilityIdentifier("characterSpacing")
                Stepper(
                    Self.positionLabel(format.position),
                    onIncrement: { controller?.setPosition(format.position + 2) },
                    onDecrement: { controller?.setPosition(format.position - 2) }
                )
            }

            Section {
                Button("Format.ClearAll", role: .destructive) { controller?.clearFormatting() }
            }
        }
        .formStyle(.grouped)
    }

    /// The underlines the picker offers, with the selection's own if it is another.
    private var underlineKinds: [String] {
        let kinds = ["none", "single", "double", "thick", "dotted", "dash", "dotDash", "wave", "words"]
        return kinds.contains(format.underlineKind) ? kinds : kinds + [format.underlineKind]
    }

    private func effect(_ label: LocalizedStringKey, _ key: WritableKeyPath<RunStyle, Bool?>, isOn: Bool) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: { controller?.setEffect(key, $0) }))
    }

    private static func pointsLabel(_ points: Double) -> String {
        points.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func spacingLabel(_ twips: Int) -> String {
        if twips == 0 { return String(localized: "Format.Spacing.Normal") }
        let points = pointsLabel(Double(abs(twips)) / 20)
        return String(format: String(localized: twips > 0 ? "Format.Spacing.Expanded" : "Format.Spacing.Condensed"), points)
    }

    static func positionLabel(_ halfPoints: Int) -> String {
        if halfPoints == 0 { return String(localized: "Format.Position.Normal") }
        let points = pointsLabel(Double(abs(halfPoints)) / 2)
        return String(format: String(localized: halfPoints > 0 ? "Format.Position.Raised" : "Format.Position.Lowered"), points)
    }

    /// The selection's font by name, the theme's by its role.
    private var fontLabel: String {
        let styles = controller?.document.styles
        switch format.fontName {
        case RunStyle.minorThemeFont?:
            return String(format: String(localized: "Font.Theme.Body"), styles?.minorFont ?? "")
        case RunStyle.majorThemeFont?:
            return String(format: String(localized: "Font.Theme.Headings"), styles?.majorFont ?? "")
        case let name?:
            return name
        case nil:
            return String(localized: "Font.Default")
        }
    }

    /// Half-points, as a point size: 11, or 10.5.
    static func points(_ halfPoints: Int) -> String {
        halfPoints % 2 == 0 ? String(halfPoints / 2) : String(format: "%.1f", Double(halfPoints) / 2)
    }

    private func stepButton(
        _ symbol: String, label: LocalizedStringKey, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }

    private func styleToggle(
        _ symbol: String, label: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 46, height: 46)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Word's highlighter colours, which are a fixed set of names rather than
/// any colour at all.
private struct HighlightSwatches: View {
    let selected: String?
    let onSelect: (String?) -> Void

    private static let names = ["yellow", "green", "cyan", "magenta", "red", "blue", "lightGray", "darkYellow"]
    private let size: CGFloat = 28

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                swatch(nil) {
                    Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                        .overlay {
                            Path { path in
                                let inset = size / 2 * (1 - 1 / sqrt(2))
                                path.move(to: CGPoint(x: inset, y: size - inset))
                                path.addLine(to: CGPoint(x: size - inset, y: inset))
                            }
                            .stroke(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        }
                }
                .accessibilityLabel("Highlight.None")
                ForEach(Self.names, id: \.self) { name in
                    swatch(name) {
                        Circle()
                            .fill(Color(argbHex: Typography.highlightColors[name]) ?? .yellow)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .accessibilityLabel(Text(LocalizedStringKey("Highlight.\(name)")))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("highlight.swatches")
    }

    private func swatch<Content: View>(_ name: String?, @ViewBuilder content: () -> Content) -> some View {
        let isSelected = selected == name
        return Button { onSelect(name) } label: {
            content()
                .frame(width: size, height: size)
                .overlay {
                    if isSelected { Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-3) }
                }
                .padding(3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("highlight.\(name ?? "none")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Paragraph

/// Paragraph style, alignment, lists, spacing and indentation.
struct ParagraphPanel: View {
    @Bindable var state: EditorState

    private var format: SelectionFormat { state.selectionFormat }
    private var controller: DocumentTextController? { state.controller }

    private static let lineSpacings: [Double] = [1, 1.15, 1.5, 2]

    var body: some View {
        Form {
            Section("Paragraph.Section.Style") {
                ForEach(ParagraphStyleChoice.allCases) { choice in
                    Button {
                        controller?.applyParagraphStyle(choice)
                    } label: {
                        HStack {
                            Text(choice.label)
                                .font(Self.previewFont(choice))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if format.styleChoice == choice {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("style.\(choice.rawValue)")
                }
            }

            Section("Paragraph.Section.Alignment") {
                Picker("Paragraph.Alignment", selection: Binding(
                    get: { format.alignment },
                    set: { controller?.setAlignment($0) }
                )) {
                    ForEach(ParagraphAlignment.allCases, id: \.self) { alignment in
                        Image(systemName: alignment.symbolName)
                            .accessibilityLabel(alignment.label)
                            .tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Button("Paragraph.Bullets", systemImage: "list.bullet") { controller?.toggleList(.bulleted) }
                        .foregroundStyle(format.listKind == .bulleted ? Color.accentColor : .primary)
                    Spacer()
                    Button("Paragraph.Numbering", systemImage: "list.number") { controller?.toggleList(.numbered) }
                        .foregroundStyle(format.listKind == .numbered ? Color.accentColor : .primary)
                }
                .buttonStyle(.borderless)

                LabeledContent("Paragraph.Indent") {
                    HStack(spacing: 16) {
                        Button { controller?.indent(by: -1) } label: { Image(systemName: "decrease.indent") }
                            .accessibilityLabel("Paragraph.Indent.Decrease")
                        Button { controller?.indent(by: 1) } label: { Image(systemName: "increase.indent") }
                            .accessibilityLabel("Paragraph.Indent.Increase")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Paragraph.Section.Spacing") {
                Stepper(
                    String(format: String(localized: "Paragraph.SpacingBefore"), format.spacingBefore / 20),
                    onIncrement: { controller?.setSpacing(before: format.spacingBefore + 120) },
                    onDecrement: { controller?.setSpacing(before: max(0, format.spacingBefore - 120)) }
                )
                Stepper(
                    String(format: String(localized: "Paragraph.SpacingAfter"), format.spacingAfter / 20),
                    onIncrement: { controller?.setSpacing(after: format.spacingAfter + 120) },
                    onDecrement: { controller?.setSpacing(after: max(0, format.spacingAfter - 120)) }
                )
                Picker("Paragraph.LineSpacing", selection: Binding(
                    get: { Self.lineSpacings.min { abs($0 - format.lineSpacing) < abs($1 - format.lineSpacing) } ?? 1 },
                    set: { controller?.setSpacing(lineMultiple: $0) }
                )) {
                    ForEach(Self.lineSpacings, id: \.self) { value in
                        Text(value.formatted(.number.precision(.fractionLength(0...2)))).tag(value)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func previewFont(_ choice: ParagraphStyleChoice) -> Font {
        switch choice {
        case .title: return .title.weight(.regular)
        case .subtitle: return .title3
        case .heading1: return .title2
        case .heading2: return .title3
        case .heading3: return .headline
        case .body: return .body
        case .quote: return .body.italic()
        }
    }
}

// MARK: - Page setup

/// Paper size, orientation and margins.
struct PageSetupPanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState

    struct PaperSize: Identifiable, Hashable {
        let id: String
        let label: String
        /// Twips, portrait.
        let width: Int
        let height: Int
    }

    static let paperSizes = [
        PaperSize(id: "a4", label: "A4", width: 11906, height: 16838),
        PaperSize(id: "a5", label: "A5", width: 8391, height: 11906),
        PaperSize(id: "b5", label: "B5 (JIS)", width: 10319, height: 14571),
        PaperSize(id: "letter", label: String(localized: "PageSetup.Paper.Letter"), width: 12240, height: 15840),
        PaperSize(id: "legal", label: String(localized: "PageSetup.Paper.Legal"), width: 12240, height: 20160),
    ]

    enum MarginPreset: String, CaseIterable, Identifiable {
        case normal, narrow, moderate, wide

        var id: String { rawValue }

        /// Top/bottom, left/right, in twips.
        var values: (vertical: Int, horizontal: Int) {
            switch self {
            case .normal: return (1440, 1440)
            case .narrow: return (720, 720)
            case .moderate: return (1440, 1080)
            case .wide: return (1440, 2880)
            }
        }

        var label: String {
            switch self {
            case .normal: return String(localized: "PageSetup.Margins.Normal")
            case .narrow: return String(localized: "PageSetup.Margins.Narrow")
            case .moderate: return String(localized: "PageSetup.Margins.Moderate")
            case .wide: return String(localized: "PageSetup.Margins.Wide")
            }
        }
    }

    private var setup: PageSetup { document.pageSetup }

    private var currentPaper: PaperSize? {
        let short = min(setup.width, setup.height)
        let long = max(setup.width, setup.height)
        return Self.paperSizes.first { abs($0.width - short) < 40 && abs($0.height - long) < 40 }
    }

    private var currentMargins: MarginPreset? {
        MarginPreset.allCases.first {
            $0.values.vertical == setup.marginTop && $0.values.vertical == setup.marginBottom
                && $0.values.horizontal == setup.marginLeft && $0.values.horizontal == setup.marginRight
        }
    }

    var body: some View {
        Form {
            Section("PageSetup.Section.Paper") {
                Picker("PageSetup.Paper", selection: Binding(
                    get: { currentPaper?.id ?? "custom" },
                    set: { id in
                        guard let paper = Self.paperSizes.first(where: { $0.id == id }) else { return }
                        change { setup in
                            setup.width = setup.isLandscape ? paper.height : paper.width
                            setup.height = setup.isLandscape ? paper.width : paper.height
                        }
                    }
                )) {
                    ForEach(Self.paperSizes) { paper in Text(paper.label).tag(paper.id) }
                    if currentPaper == nil {
                        Text(String(
                            format: String(localized: "PageSetup.Paper.Custom"),
                            setup.size.width / 72 * 25.4, setup.size.height / 72 * 25.4
                        )).tag("custom")
                    }
                }
                Picker("PageSetup.Orientation", selection: Binding(
                    get: { setup.isLandscape },
                    set: { landscape in
                        guard landscape != setup.isLandscape else { return }
                        change { setup in swap(&setup.width, &setup.height) }
                    }
                )) {
                    Label("PageSetup.Portrait", systemImage: "rectangle.portrait").tag(false)
                    Label("PageSetup.Landscape", systemImage: "rectangle").tag(true)
                }
                .pickerStyle(.segmented)
            }

            Section("PageSetup.Section.Margins") {
                ForEach(MarginPreset.allCases) { preset in
                    Button {
                        change { setup in
                            setup.marginTop = preset.values.vertical
                            setup.marginBottom = preset.values.vertical
                            setup.marginLeft = preset.values.horizontal
                            setup.marginRight = preset.values.horizontal
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label).foregroundStyle(Color.primary)
                                Text(Self.describe(preset))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if currentMargins == preset {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func describe(_ preset: MarginPreset) -> String {
        let measurement = { (twips: Int) in
            Measurement(value: Double(twips) / 1440 * 25.4, unit: UnitLength.millimeters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        return String(
            format: String(localized: "PageSetup.Margins.Description"),
            measurement(preset.values.vertical), measurement(preset.values.horizontal)
        )
    }

    private func change(_ edit: (inout PageSetup) -> Void) {
        state.controller?.flush()
        state.pendingScope = .pageSetup
        edit(&document.pageSetup)
    }
}

// MARK: - Tables

/// Edits the text of the table the selection is on, and its rows and columns.
struct TablePanel: View {
    @Bindable var state: EditorState
    @State private var table: Table?

    var body: some View {
        Form {
            if let table {
                ForEach(Array(table.rows.enumerated()), id: \.element.id) { rowIndex, row in
                    Section(String(format: String(localized: "Table.Row"), rowIndex + 1)) {
                        ForEach(Array(row.cells.enumerated()), id: \.element.id) { cellIndex, cell in
                            if cell.verticalMerge != .continue {
                                TextField(
                                    String(format: String(localized: "Table.Cell.Placeholder"), cellIndex + 1),
                                    text: Binding(
                                        get: { cell.plainText },
                                        set: { setText($0, row: rowIndex, cell: cellIndex) }
                                    ),
                                    axis: .vertical
                                )
                                .accessibilityIdentifier("cell.\(rowIndex).\(cellIndex)")
                            }
                        }
                    }
                }
                Section {
                    Button("Table.AddRow", systemImage: "plus") { edit { TableEditing.addRow(to: &$0) } }
                    Button("Table.AddColumn", systemImage: "plus") { edit { TableEditing.addColumn(to: &$0) } }
                    Button("Table.RemoveRow", systemImage: "minus", role: .destructive) {
                        edit { TableEditing.removeLastRow(from: &$0) }
                    }
                    .disabled(table.rows.count <= 1)
                    Button("Table.RemoveColumn", systemImage: "minus", role: .destructive) {
                        edit { TableEditing.removeLastColumn(from: &$0) }
                    }
                    .disabled(table.columnCount <= 1)
                }
                Section {
                    Button("ActionBar.DeleteTable", role: .destructive) {
                        state.controller?.deleteSelectedTable()
                        state.presentedPanel = nil
                    }
                }
            } else {
                ContentUnavailableView("Table.None", systemImage: "tablecells")
            }
        }
        .formStyle(.grouped)
        .onAppear { table = state.controller?.selectedTable }
    }

    private func setText(_ text: String, row: Int, cell: Int) {
        edit { TableEditing.setText(text, row: row, cell: cell, in: &$0) }
    }

    private func edit(_ change: (inout Table) -> Void) {
        guard var current = table else { return }
        change(&current)
        table = current
        state.controller?.replaceTable(current)
    }
}

/// Changes to a table's structure and text, as the table panel makes them.
enum TableEditing {
    static func setText(_ text: String, row: Int, cell: Int, in table: inout Table) {
        guard table.rows.indices.contains(row), table.rows[row].cells.indices.contains(cell) else { return }
        let existing = table.rows[row].cells[cell].blocks.flatMap(\.paragraphs)
        let lines = text.components(separatedBy: "\n")
        // Each line keeps the paragraph it replaces, so its style survives.
        table.rows[row].cells[cell].blocks = lines.enumerated().map { index, line in
            var paragraph = existing.indices.contains(index) ? existing[index] : (existing.last ?? Paragraph())
            if !existing.indices.contains(index) { paragraph = paragraph.splitCopy() }
            let format = paragraph.inlines.first { if case .text = $0.content { return true } else { return false } }?
                .format ?? RunFormat()
            paragraph.inlines = line.isEmpty ? [] : [Inline(.text(line), format: format)]
            return .paragraph(paragraph)
        }
    }

    static func addRow(to table: inout Table) {
        let columns = max(1, table.columnCount)
        table.rows.append(TableRow(cells: (0..<columns).map { _ in TableCell(blocks: [.paragraph(Paragraph())]) }))
    }

    static func addColumn(to table: inout Table) {
        // The new column takes a share of the width the others had.
        let total = table.gridColumns.reduce(0, +)
        let count = table.gridColumns.count + 1
        if total > 0 {
            table.gridColumns = table.gridColumns.map { $0 * (count - 1) / count } + [total / count]
        } else {
            table.gridColumns.append(1440)
        }
        for index in table.rows.indices {
            table.rows[index].cells.append(TableCell(blocks: [.paragraph(Paragraph())]))
        }
        clearCellWidths(&table)
        table.preservedPropertiesXML = table.preservedPropertiesXML.map(dropFixedLayout)
    }

    static func removeLastRow(from table: inout Table) {
        guard table.rows.count > 1 else { return }
        table.rows.removeLast()
    }

    static func removeLastColumn(from table: inout Table) {
        guard table.columnCount > 1 else { return }
        let removed = table.gridColumns.popLast() ?? 0
        if !table.gridColumns.isEmpty {
            table.gridColumns[table.gridColumns.count - 1] += removed
        }
        for index in table.rows.indices {
            guard var last = table.rows[index].cells.popLast() else { continue }
            if last.gridSpan > 1 {
                last.gridSpan -= 1
                table.rows[index].cells.append(last)
            }
        }
        clearCellWidths(&table)
    }

    /// Cell widths written for the old columns would fight the new grid.
    private static func clearCellWidths(_ table: inout Table) {
        for row in table.rows.indices {
            for cell in table.rows[row].cells.indices {
                table.rows[row].cells[cell].preservedPropertiesXML = table.rows[row].cells[cell].preservedPropertiesXML
                    .flatMap { xml in DOCXPatcher.editing(xml) { tcPr in tcPr.children(named: "tcW").forEach(tcPr.removeChild) } }
            }
        }
    }

    private static func dropFixedLayout(_ xml: String) -> String {
        DOCXPatcher.editing(xml) { tblPr in tblPr.children(named: "tblLayout").forEach(tblPr.removeChild) } ?? xml
    }
}

/// Picks a size for a new table.
struct InsertTablePanel: View {
    @Bindable var state: EditorState
    @State private var rows = 3
    @State private var columns = 3

    var body: some View {
        Form {
            Section {
                Stepper(String(format: String(localized: "InsertTable.Rows"), rows), value: $rows, in: 1...50)
                Stepper(String(format: String(localized: "InsertTable.Columns"), columns), value: $columns, in: 1...10)
            }
            Section {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<min(rows, 8), id: \.self) { _ in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.25)).frame(height: 18)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .accessibilityHidden(true)
            }
            Section {
                Button("InsertTable.Insert") {
                    state.controller?.insertTable(rows: rows, columns: columns)
                    state.presentedPanel = nil
                }
                .accessibilityIdentifier("insertTable.confirm")
            }
        }
        .formStyle(.grouped)
    }
}
