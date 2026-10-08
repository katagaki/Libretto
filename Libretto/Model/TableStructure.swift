import Foundation

/// A cell picked out by its row and the grid column it starts at.
struct CellPosition: Hashable, Sendable {
    var row: Int
    var column: Int
}

/// Changes to a table's structure: rows and columns anywhere, merged and
/// split cells, widths, shading, borders, its style and its header rows.
///
/// The model and the kept properties change together: what the properties
/// say of a cell's span and merge, its shading, or the table's style and
/// borders is patched in place, so everything else they say survives.
extension TableEditing {
    // MARK: - The grid

    /// The grid column each cell of a row starts at.
    static func gridStarts(of row: TableRow) -> [Int] {
        var column = 0
        return row.cells.map { cell in
            defer { column += max(1, cell.gridSpan) }
            return column
        }
    }

    /// The cell of a row that covers a grid column.
    static func cellIndex(in row: TableRow, coveringColumn column: Int) -> Int? {
        let starts = gridStarts(of: row)
        return row.cells.indices.first { column >= starts[$0] && column < starts[$0] + max(1, row.cells[$0].gridSpan) }
    }

    private static func emptyCell() -> TableCell {
        TableCell(blocks: [.paragraph(Paragraph())])
    }

    // MARK: - Rows

    /// A new row before or after `index`, its cells spanning as that row's do.
    static func insertRow(in table: inout Table, at index: Int, below: Bool) {
        guard table.rows.indices.contains(index) else { return addRow(to: &table) }
        let model = table.rows[index]
        var row = TableRow(cells: model.cells.map { cell in
            var fresh = emptyCell()
            fresh.gridSpan = cell.gridSpan
            fresh.preservedPropertiesXML = cell.preservedPropertiesXML.flatMap { patchCell($0) { tcPr in
                // The new row's cells carry on no vertical merge, and none of the text's shading.
                tcPr.children(named: "vMerge").forEach(tcPr.removeChild)
            } }
            fresh.shadingHex = cell.shadingHex
            return fresh
        })
        row.preservedPropertiesXML = model.preservedPropertiesXML.flatMap { trPr in
            DOCXPatcher.editing(trPr) { $0.children(named: "tblHeader").forEach($0.removeChild) }
        }
        table.rows.insert(row, at: below ? index + 1 : index)
    }

    /// Deletes a row; a vertical merge it started carries on from the row after.
    static func deleteRow(in table: inout Table, at index: Int) {
        guard table.rows.count > 1, table.rows.indices.contains(index) else { return }
        if index + 1 < table.rows.count {
            let starts = gridStarts(of: table.rows[index])
            for (cellIndex, cell) in table.rows[index].cells.enumerated() where cell.verticalMerge == .restart {
                guard let below = self.cellIndex(in: table.rows[index + 1], coveringColumn: starts[cellIndex]),
                      table.rows[index + 1].cells[below].verticalMerge == .continue else { continue }
                // The merged text moves down with the merge.
                table.rows[index + 1].cells[below].blocks = cell.blocks
                setVerticalMerge(&table.rows[index + 1].cells[below], .restart)
            }
        }
        table.rows.remove(at: index)
    }

    // MARK: - Columns

    /// A new grid column before or after `column`, taking a share of the table's width.
    static func insertColumn(in table: inout Table, at column: Int, after: Bool) {
        let count = max(1, table.columnCount)
        let target = min(max(0, after ? column + 1 : column), count)
        if table.gridColumns.count < count {
            table.gridColumns = Array(repeating: 1440, count: count)
        }
        let total = table.gridColumns.reduce(0, +)
        let share = total / (count + 1)
        table.gridColumns = table.gridColumns.map { $0 * count / (count + 1) }
        table.gridColumns.insert(share, at: target)
        for index in table.rows.indices {
            let row = table.rows[index]
            let starts = gridStarts(of: row)
            if let inside = row.cells.indices.first(where: { starts[$0] < target && target < starts[$0] + max(1, row.cells[$0].gridSpan) }) {
                // Inside a spanning cell: the cell spans the new column too.
                setSpan(&table.rows[index].cells[inside], row.cells[inside].gridSpan + 1)
            } else {
                let position = row.cells.indices.first { starts[$0] >= target } ?? row.cells.count
                table.rows[index].cells.insert(emptyCell(), at: position)
            }
        }
        clearWidths(&table)
    }

    /// Deletes a grid column; cells spanning it span one fewer.
    static func deleteColumn(in table: inout Table, at column: Int) {
        guard table.columnCount > 1 else { return }
        for index in table.rows.indices {
            guard let cell = cellIndex(in: table.rows[index], coveringColumn: column) else { continue }
            if table.rows[index].cells[cell].gridSpan > 1 {
                setSpan(&table.rows[index].cells[cell], table.rows[index].cells[cell].gridSpan - 1)
            } else {
                table.rows[index].cells.remove(at: cell)
            }
        }
        if table.gridColumns.indices.contains(column) {
            let removed = table.gridColumns.remove(at: column)
            // The table keeps its width: the column beside takes the room.
            if !table.gridColumns.isEmpty {
                table.gridColumns[min(column, table.gridColumns.count - 1)] += removed
            }
        }
        table.rows.removeAll { $0.cells.isEmpty }
        clearWidths(&table)
    }

    /// Sets a grid column's width, in twips.
    static func setColumnWidth(in table: inout Table, column: Int, to width: Int) {
        if table.gridColumns.count < table.columnCount {
            table.gridColumns = Array(repeating: 1440, count: table.columnCount)
        }
        guard table.gridColumns.indices.contains(column) else { return }
        table.gridColumns[column] = max(144, width)
        clearWidths(&table)
        table.preservedPropertiesXML = patchTable(table.preservedPropertiesXML) { tblPr in
            // A fixed width for the whole table would fight the columns'.
            tblPr.children(named: "tblW").forEach(tblPr.removeChild)
            tblPr.insertChild(.word("tblW", ["w": "0", "type": "auto"]), at: tblPr.children.count)
        }
    }

    // MARK: - Merging

    /// Merges a rectangle of cells, rows `rows` and grid columns `columns`,
    /// into one: their text gathered into the first.
    static func merge(in table: inout Table, rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        guard rows.lowerBound >= 0, rows.upperBound < table.rows.count else { return }
        var gathered: [Block] = []
        for index in rows {
            let row = table.rows[index]
            let starts = gridStarts(of: row)
            let covered = row.cells.indices.filter {
                starts[$0] + max(1, row.cells[$0].gridSpan) > columns.lowerBound && starts[$0] <= columns.upperBound
            }
            guard let first = covered.first else { continue }
            let span = covered.reduce(0) { $0 + max(1, row.cells[$1].gridSpan) }
            for cell in covered {
                let blocks = row.cells[cell].blocks
                let hasText = blocks.contains { !$0.paragraphs.allSatisfy { $0.plainText.isEmpty } }
                if hasText { gathered += blocks }
            }
            var merged = table.rows[index].cells[first]
            setSpan(&merged, span)
            if rows.count > 1 { setVerticalMerge(&merged, index == rows.lowerBound ? .restart : .continue) }
            merged.blocks = [.paragraph(Paragraph())]
            table.rows[index].cells.replaceSubrange(covered.first!...covered.last!, with: [merged])
        }
        let firstRow = table.rows[rows.lowerBound]
        if let first = cellIndex(in: firstRow, coveringColumn: columns.lowerBound) {
            table.rows[rows.lowerBound].cells[first].blocks = gathered.isEmpty ? [.paragraph(Paragraph())] : gathered
            if case .paragraph = table.rows[rows.lowerBound].cells[first].blocks.last {} else {
                table.rows[rows.lowerBound].cells[first].blocks.append(.paragraph(Paragraph()))
            }
        }
        clearWidths(&table)
    }

    /// Splits a merged cell back into the cells it covers.
    static func split(in table: inout Table, at position: CellPosition) {
        guard table.rows.indices.contains(position.row),
              let index = cellIndex(in: table.rows[position.row], coveringColumn: position.column) else { return }
        let cell = table.rows[position.row].cells[index]
        let span = max(1, cell.gridSpan)
        let start = gridStarts(of: table.rows[position.row])[index]
        // The rows below that carry on its vertical merge become cells of their own.
        if cell.verticalMerge == .restart {
            var below = position.row + 1
            while below < table.rows.count,
                  let continued = cellIndex(in: table.rows[below], coveringColumn: start),
                  table.rows[below].cells[continued].verticalMerge == .continue {
                setVerticalMerge(&table.rows[below].cells[continued], nil)
                splitSpan(in: &table.rows[below], at: continued)
                below += 1
            }
        }
        setVerticalMerge(&table.rows[position.row].cells[index], nil)
        if span > 1 { splitSpan(in: &table.rows[position.row], at: index) }
        clearWidths(&table)
    }

    private static func splitSpan(in row: inout TableRow, at index: Int) {
        let span = max(1, row.cells[index].gridSpan)
        guard span > 1 else { return }
        setSpan(&row.cells[index], 1)
        row.cells.insert(contentsOf: (1..<span).map { _ in emptyCell() }, at: index + 1)
    }

    /// Whether a rectangle of cells can be merged: it covers whole cells only.
    static func canMerge(_ table: Table, rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Bool {
        guard rows.count > 1 || columns.count > 1, rows.upperBound < table.rows.count else { return false }
        for index in rows {
            let row = table.rows[index]
            let starts = gridStarts(of: row)
            for (cell, start) in starts.enumerated() {
                let end = start + max(1, row.cells[cell].gridSpan) - 1
                let overlaps = end >= columns.lowerBound && start <= columns.upperBound
                if overlaps && (start < columns.lowerBound || end > columns.upperBound) { return false }
            }
        }
        return true
    }

    // MARK: - Appearance

    static func setShading(in table: inout Table, cells: [CellPosition], hex: String?) {
        for position in cells {
            guard table.rows.indices.contains(position.row),
                  let index = cellIndex(in: table.rows[position.row], coveringColumn: position.column) else { continue }
            var cell = table.rows[position.row].cells[index]
            cell.shadingHex = hex
            cell.preservedPropertiesXML = patchCell(cell.preservedPropertiesXML ?? "<w:tcPr/>") { tcPr in
                tcPr.children(named: "shd").forEach(tcPr.removeChild)
                if let hex { tcPr.insertChild(.word("shd", ["val": "clear", "color": "auto", "fill": hex]), at: tcPr.children.count) }
            }
            table.rows[position.row].cells[index] = cell
        }
    }

    enum BorderPreset: String, CaseIterable, Identifiable {
        case all, outside, inside, none
        var id: String { rawValue }
    }

    /// The table's own borders: every line, the outside, the inside, or none.
    static func setBorders(in table: inout Table, _ preset: BorderPreset, colorHex: String? = nil) {
        let line = ["val": "single", "sz": "4", "space": "0", "color": colorHex ?? "auto"]
        let none = ["val": "nil"]
        let outside = preset == .all || preset == .outside
        let inside = preset == .all || preset == .inside
        table.preservedPropertiesXML = patchTable(table.preservedPropertiesXML) { tblPr in
            tblPr.children(named: "tblBorders").forEach(tblPr.removeChild)
            let borders = XMLElement.word("tblBorders")
            for side in ["top", "left", "bottom", "right"] { borders.insertChild(.word(side, outside ? line : none), at: borders.children.count) }
            for side in ["insideH", "insideV"] { borders.insertChild(.word(side, inside ? line : none), at: borders.children.count) }
            tblPr.insertChild(borders, at: tblPr.children.count)
        }
        table.hasBorders = preset != .none
        table.borderColorHex = colorHex
    }

    /// Puts the table in a table style, or none.
    static func setStyle(in table: inout Table, styleID: String?, styles: StyleSheet) {
        table.styleID = styleID
        table.preservedPropertiesXML = patchTable(table.preservedPropertiesXML) { tblPr in
            tblPr.children(named: "tblStyle").forEach(tblPr.removeChild)
            if let styleID { tblPr.insertChild(.word("tblStyle", ["val": styleID]), at: 0) }
            // The style's borders show once the table's own give way to them.
            tblPr.children(named: "tblBorders").forEach(tblPr.removeChild)
        }
        table.hasBorders = styles.tableHasBorders(styleID: styleID)
        table.borderColorHex = styles.tableBorderColor(styleID: styleID)
    }

    /// Which of its style's parts the table shows: header row, banding, first column and so on.
    static func setLook(in table: inout Table, _ look: TableLook) {
        table.look = look
        table.preservedPropertiesXML = patchTable(table.preservedPropertiesXML) { tblPr in
            tblPr.children(named: "tblLook").forEach(tblPr.removeChild)
            func flag(_ on: Bool) -> String { on ? "1" : "0" }
            var value = 0
            if look.firstRow { value |= 0x0020 }
            if look.lastRow { value |= 0x0040 }
            if look.firstColumn { value |= 0x0080 }
            if look.lastColumn { value |= 0x0100 }
            if !look.bandedRows { value |= 0x0200 }
            if !look.bandedColumns { value |= 0x0400 }
            tblPr.insertChild(.word("tblLook", [
                "val": String(format: "%04X", value), "firstRow": flag(look.firstRow), "lastRow": flag(look.lastRow),
                "firstColumn": flag(look.firstColumn), "lastColumn": flag(look.lastColumn),
                "noHBand": flag(!look.bandedRows), "noVBand": flag(!look.bandedColumns),
            ]), at: tblPr.children.count)
        }
    }

    /// Makes a row one of the header rows Word repeats at the top of each page the table runs on to.
    static func setHeader(in table: inout Table, row: Int, _ isHeader: Bool) {
        guard table.rows.indices.contains(row) else { return }
        table.rows[row].isHeader = isHeader
        table.rows[row].preservedPropertiesXML = DOCXPatcher.editing(table.rows[row].preservedPropertiesXML ?? "<w:trPr/>") { trPr in
            trPr.children(named: "tblHeader").forEach(trPr.removeChild)
            if isHeader { trPr.insertChild(.word("tblHeader"), at: trPr.children.count) }
            trPr.sortChildren(by: Self.rowPropertyOrder)
        }.flatMap { $0 == "<w:trPr/>" ? nil : $0 }
    }

    // MARK: - Patching the kept properties

    static let cellPropertyOrder = [
        "cnfStyle", "tcW", "gridSpan", "hMerge", "vMerge", "tcBorders", "shd", "noWrap", "tcMar", "textDirection",
        "tcFitText", "vAlign", "hideMark", "headers", "cellIns", "cellDel", "cellMerge", "tcPrChange",
    ]
    static let tablePropertyOrder = [
        "tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblStyleRowBandSize", "tblStyleColBandSize", "tblW", "jc",
        "tblCellSpacing", "tblInd", "tblBorders", "shd", "tblLayout", "tblCellMar", "tblLook", "tblCaption",
        "tblDescription", "tblPrChange",
    ]
    static let rowPropertyOrder = [
        "cnfStyle", "divId", "gridBefore", "gridAfter", "wBefore", "wAfter", "cantSplit", "trHeight", "tblHeader",
        "tblCellSpacing", "jc", "hidden", "ins", "del", "trPrChange",
    ]

    private static func patchCell(_ xml: String, _ edit: (XMLElement) -> Void) -> String? {
        DOCXPatcher.editing(xml) { tcPr in
            edit(tcPr)
            tcPr.sortChildren(by: cellPropertyOrder)
        }.flatMap { $0 == "<w:tcPr/>" ? nil : $0 }
    }

    private static func patchTable(_ xml: String?, _ edit: (XMLElement) -> Void) -> String? {
        DOCXPatcher.editing(xml ?? BodyWriter.defaultTableProperties) { tblPr in
            edit(tblPr)
            tblPr.sortChildren(by: tablePropertyOrder)
        } ?? xml
    }

    private static func setSpan(_ cell: inout TableCell, _ span: Int) {
        cell.gridSpan = max(1, span)
        cell.preservedPropertiesXML = patchCell(cell.preservedPropertiesXML ?? "<w:tcPr/>") { tcPr in
            tcPr.children(named: "gridSpan").forEach(tcPr.removeChild)
            if span > 1 { tcPr.insertChild(.word("gridSpan", ["val": String(span)]), at: tcPr.children.count) }
        }
    }

    private static func setVerticalMerge(_ cell: inout TableCell, _ merge: TableCell.VerticalMerge?) {
        cell.verticalMerge = merge
        cell.preservedPropertiesXML = patchCell(cell.preservedPropertiesXML ?? "<w:tcPr/>") { tcPr in
            tcPr.children(named: "vMerge").forEach(tcPr.removeChild)
            switch merge {
            case .restart?: tcPr.insertChild(.word("vMerge", ["val": "restart"]), at: tcPr.children.count)
            case .continue?: tcPr.insertChild(.word("vMerge"), at: tcPr.children.count)
            case nil: break
            }
        }
    }

    /// Cell widths written for the old columns would fight the new grid.
    private static func clearWidths(_ table: inout Table) {
        for row in table.rows.indices {
            for cell in table.rows[row].cells.indices {
                table.rows[row].cells[cell].preservedPropertiesXML = table.rows[row].cells[cell].preservedPropertiesXML
                    .flatMap { patchCell($0) { tcPr in tcPr.children(named: "tcW").forEach(tcPr.removeChild) } }
            }
        }
    }
}
