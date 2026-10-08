import SwiftUI

/// Edits the table the selection is on: its cells' text, its rows and
/// columns, merged cells, widths, shading, borders, style and header rows.
struct TablePanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState
    @State private var table: Table?
    /// The picked cells: from the anchor to the far corner, by row and grid column.
    @State private var anchor = CellPosition(row: 0, column: 0)
    @State private var corner = CellPosition(row: 0, column: 0)
    @State private var isExtending = false

    private var controller: DocumentTextController? { state.controller }

    private var rows: ClosedRange<Int> { min(anchor.row, corner.row)...max(anchor.row, corner.row) }
    private var columns: ClosedRange<Int> { min(anchor.column, corner.column)...max(anchor.column, corner.column) }

    var body: some View {
        Form {
            if let table {
                Section {
                    TableGridPicker(table: table, rows: rows, columns: columns) { position in
                        if isExtending {
                            corner = position
                            isExtending = false
                        } else {
                            anchor = position
                            corner = position
                        }
                    }
                    Toggle("Table.ExtendSelection", isOn: $isExtending)
                } footer: {
                    Text("Table.Select.Footer")
                }

                if rows.count == 1, columns.count == 1, let cell = cell(in: table, at: anchor) {
                    Section("Table.Cell") {
                        TextField("Table.Cell.Text", text: Binding(
                            get: { cell.plainText },
                            set: { text in edit { TableEditing.setText(text, row: anchor.row, cell: cellIndex(in: $0, at: anchor) ?? 0, in: &$0) } }
                        ), axis: .vertical)
                        .lineLimit(1...5)
                        .accessibilityIdentifier("table.cellText")
                    }
                }

                Section("Table.Section.RowsColumns") {
                    HStack {
                        Button("Table.InsertAbove", systemImage: "arrow.up.to.line") {
                            edit { TableEditing.insertRow(in: &$0, at: rows.lowerBound, below: false) }
                            shiftRows(by: 1)
                        }
                        Spacer()
                        Button("Table.InsertBelow", systemImage: "arrow.down.to.line") {
                            edit { TableEditing.insertRow(in: &$0, at: rows.upperBound, below: true) }
                        }
                    }
                    HStack {
                        Button("Table.InsertLeft", systemImage: "arrow.left.to.line") {
                            edit { TableEditing.insertColumn(in: &$0, at: columns.lowerBound, after: false) }
                            shiftColumns(by: 1)
                        }
                        Spacer()
                        Button("Table.InsertRight", systemImage: "arrow.right.to.line") {
                            edit { TableEditing.insertColumn(in: &$0, at: columns.upperBound, after: true) }
                        }
                    }
                    HStack {
                        Button("Table.DeleteRow", systemImage: "minus", role: .destructive) {
                            edit { table in for row in rows.reversed() { TableEditing.deleteRow(in: &table, at: row) } }
                            resetSelection()
                        }
                        .disabled(table.rows.count <= rows.count)
                        Spacer()
                        Button("Table.DeleteColumn", systemImage: "minus", role: .destructive) {
                            edit { table in for column in columns.reversed() { TableEditing.deleteColumn(in: &table, at: column) } }
                            resetSelection()
                        }
                        .disabled(table.columnCount <= columns.count)
                    }
                }
                .buttonStyle(.borderless)

                Section("Table.Section.Cells") {
                    Button("Table.Merge", systemImage: "rectangle.compress.vertical") {
                        edit { TableEditing.merge(in: &$0, rows: rows, columns: columns) }
                        corner = anchor
                    }
                    .disabled(!TableEditing.canMerge(table, rows: rows, columns: columns))
                    Button("Table.Split", systemImage: "rectangle.split.2x1") {
                        edit { TableEditing.split(in: &$0, at: anchor) }
                    }
                    .disabled(!isMerged(table, at: anchor))
                    Stepper(
                        String(format: String(localized: "Table.ColumnWidth"), ParagraphDetailSections.position(width(of: columns.lowerBound, in: table))),
                        onIncrement: { edit { TableEditing.setColumnWidth(in: &$0, column: columns.lowerBound, to: width(of: columns.lowerBound, in: $0) + 144) } },
                        onDecrement: { edit { TableEditing.setColumnWidth(in: &$0, column: columns.lowerBound, to: width(of: columns.lowerBound, in: $0) - 144) } }
                    )
                    LabeledContent("Table.Shading") { EmptyView() }
                    SystemColorSwatches(
                        role: .fill,
                        selectedHex: cell(in: table, at: anchor)?.shadingHex.map { "FF" + $0 },
                        customColor: Binding(
                            get: { Color(argbHex: cell(in: table, at: anchor)?.shadingHex) ?? .clear },
                            set: { color in shade(color.argbHex) }
                        ),
                        onSelect: { shade($0.argbHex) },
                        onClear: { shade(nil) }
                    )
                }

                Section("Table.Section.Table") {
                    Picker("Table.Style", selection: Binding(
                        get: { table.styleID ?? "" },
                        set: { id in
                            let styleID = id.isEmpty ? nil : document.styles.ensureTableStyle(id)
                            let styles = document.styles
                            edit { TableEditing.setStyle(in: &$0, styleID: styleID, styles: styles) }
                        }
                    )) {
                        Text("Table.Style.None").tag("")
                        ForEach(document.styles.tableStyles, id: \.id) { style in Text(style.name).tag(style.id) }
                    }
                    .accessibilityIdentifier("table.style")
                    look("Table.Look.HeaderRow", \.firstRow, table)
                    look("Table.Look.BandedRows", \.bandedRows, table)
                    look("Table.Look.FirstColumn", \.firstColumn, table)
                    look("Table.Look.TotalRow", \.lastRow, table)
                    Picker("Table.Borders", selection: Binding<TableEditing.BorderPreset?>(
                        get: { nil },
                        set: { preset in if let preset { edit { TableEditing.setBorders(in: &$0, preset) } } }
                    )) {
                        ForEach(TableEditing.BorderPreset.allCases) { preset in
                            Text(LocalizedStringKey("Table.Borders.\(preset.rawValue)")).tag(Optional(preset))
                        }
                    }
                    Toggle("Table.RepeatHeader", isOn: Binding(
                        get: { table.rows.indices.contains(anchor.row) && table.rows[anchor.row].isHeader },
                        set: { value in edit { table in for row in rows { TableEditing.setHeader(in: &table, row: row, value) } } }
                    ))
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

    // MARK: - Cells

    private func cellIndex(in table: Table, at position: CellPosition) -> Int? {
        guard table.rows.indices.contains(position.row) else { return nil }
        return TableEditing.cellIndex(in: table.rows[position.row], coveringColumn: position.column)
    }

    private func cell(in table: Table, at position: CellPosition) -> TableCell? {
        cellIndex(in: table, at: position).map { table.rows[position.row].cells[$0] }
    }

    private func isMerged(_ table: Table, at position: CellPosition) -> Bool {
        guard let cell = cell(in: table, at: position) else { return false }
        return cell.gridSpan > 1 || cell.verticalMerge == .restart
    }

    private func width(of column: Int, in table: Table) -> Int {
        table.gridColumns.indices.contains(column) ? table.gridColumns[column]
            : (table.gridColumns.reduce(0, +) / max(1, table.columnCount))
    }

    private func shade(_ argbHex: String?) {
        let positions = rows.flatMap { row in columns.map { CellPosition(row: row, column: $0) } }
        edit { TableEditing.setShading(in: &$0, cells: positions, hex: argbHex.map { String($0.suffix(6)).uppercased() }) }
    }

    private func look(_ label: LocalizedStringKey, _ key: WritableKeyPath<TableLook, Bool>, _ table: Table) -> some View {
        Toggle(label, isOn: Binding(
            get: { table.look[keyPath: key] },
            set: { value in
                var look = table.look
                look[keyPath: key] = value
                edit { TableEditing.setLook(in: &$0, look) }
            }
        ))
    }

    // MARK: - Selection

    private func shiftRows(by count: Int) {
        anchor.row += count
        corner.row += count
    }

    private func shiftColumns(by count: Int) {
        anchor.column += count
        corner.column += count
    }

    private func resetSelection() {
        anchor = CellPosition(row: 0, column: 0)
        corner = anchor
    }

    private func edit(_ change: (inout Table) -> Void) {
        guard var current = table else { return }
        change(&current)
        table = current
        state.controller?.replaceTable(current)
    }
}

/// The table in miniature, its cells to tap: spanning cells span, merged
/// cells read as one, and the picked cells are lit.
private struct TableGridPicker: View {
    let table: Table
    let rows: ClosedRange<Int>
    let columns: ClosedRange<Int>
    let onPick: (CellPosition) -> Void

    var body: some View {
        let widths = TableRenderer.columnWidths(table, availableWidth: 300)
        let total = max(1, widths.reduce(0, +))
        GeometryReader { proxy in
            let scale = proxy.size.width / total
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 2) {
                        let starts = TableEditing.gridStarts(of: row)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { cellIndex, cell in
                            let start = starts[cellIndex]
                            let span = max(1, cell.gridSpan)
                            let width = widths.dropFirst(start).prefix(span).reduce(0, +) * scale - 2
                            let isPicked = rows.contains(rowIndex) && columns.overlaps(start...(start + span - 1))
                            Text(cell.verticalMerge == .continue ? "" : cell.plainText)
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                                .frame(width: max(8, width), height: 26, alignment: .leading)
                                .background(
                                    isPicked ? Color.accentColor.opacity(0.3)
                                        : cell.verticalMerge == .continue ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.15),
                                    in: .rect(cornerRadius: 3)
                                )
                                .contentShape(.rect)
                                .onTapGesture { onPick(CellPosition(row: rowIndex, column: start)) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("table.cell.\(rowIndex).\(start)")
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(table.rows.count) * 28)
        .padding(.vertical, 4)
    }
}
