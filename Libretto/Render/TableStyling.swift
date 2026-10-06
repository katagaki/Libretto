import Foundation

/// How a table's style dresses one of its cells: the header row's fill and
/// bold, the banding, the first column, and so on.
struct CellAppearance: Equatable {
    /// Six-digit RGB; the cell's own shading, else its style's.
    var fillHex: String?
    var condition = TableCondition()
}

enum TableStyling {
    /// Each cell's appearance, row by row, column by column.
    static func appearances(of table: Table, styles: StyleSheet) -> [[CellAppearance]] {
        let conditions = styles.tableConditions(styleID: table.styleID)
        let look = table.look
        let rowCount = table.rows.count
        // Bands count from after the header row, and alternate one row at a time.
        let bandedRows = look.firstRow ? 1 : 0
        return table.rows.enumerated().map { rowIndex, row in
            let cellCount = row.cells.count
            return row.cells.enumerated().map { cellIndex, cell in
                var kinds: [TableCondition.Kind] = [.wholeTable]
                let isFirstRow = look.firstRow && rowIndex == 0
                let isLastRow = look.lastRow && rowIndex == rowCount - 1 && rowCount > 1
                let isFirstColumn = look.firstColumn && cellIndex == 0
                let isLastColumn = look.lastColumn && cellIndex == cellCount - 1 && cellCount > 1
                let bandColumn = cellIndex - (look.firstColumn ? 1 : 0)
                if look.bandedColumns, !isFirstColumn, !isLastColumn, bandColumn >= 0 {
                    kinds.append(bandColumn % 2 == 0 ? .band1Vert : .band2Vert)
                }
                let bandRow = rowIndex - bandedRows
                if look.bandedRows, !isFirstRow, !isLastRow, bandRow >= 0 {
                    kinds.append(bandRow % 2 == 0 ? .band1Horz : .band2Horz)
                }
                if isFirstColumn { kinds.append(.firstCol) }
                if isLastColumn { kinds.append(.lastCol) }
                if isFirstRow { kinds.append(.firstRow) }
                if isLastRow { kinds.append(.lastRow) }
                if isFirstRow, isFirstColumn { kinds.append(.nwCell) }
                if isFirstRow, isLastColumn { kinds.append(.neCell) }
                if isLastRow, isFirstColumn { kinds.append(.swCell) }
                if isLastRow, isLastColumn { kinds.append(.seCell) }

                var appearance = CellAppearance()
                for kind in kinds {
                    guard let condition = conditions[kind] else { continue }
                    appearance.condition = appearance.condition.merged(with: condition)
                }
                appearance.fillHex = cell.shadingHex ?? appearance.condition.fillHex
                return appearance
            }
        }
    }

    /// A context whose defaults carry the cell's table style formatting,
    /// which Word places above the document's defaults and below its styles.
    static func context(_ context: RenderContext, for appearance: CellAppearance) -> RenderContext {
        var styled = context
        styled.backgroundHex = appearance.fillHex
        styled.styles.defaultRunStyle = context.styles.defaultRunStyle.merged(with: appearance.condition.runStyle)
        styled.styles.defaultParagraphProperties = context.styles.defaultParagraphProperties
            .merged(with: appearance.condition.paragraphProperties)
        return styled
    }
}
