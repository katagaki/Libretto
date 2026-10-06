import Foundation
import Testing
@testable import Libretto

@Suite("Table styles")
struct TableStyleTests {
    private func styles() -> StyleSheet {
        var sheet = StyleSheet()
        var style = StyleSheet.Style(id: "Banded", name: "Banded", kind: .table)
        style.tableConditions = [
            .wholeTable: TableCondition(fillHex: "FFFFFF"),
            .firstRow: TableCondition(runStyle: RunStyle(isBold: true, colorHex: "FFFFFF"), fillHex: "4472C4"),
            .band1Horz: TableCondition(fillHex: "D9E2F3"),
            .firstCol: TableCondition(runStyle: RunStyle(isItalic: true)),
        ]
        sheet.styles["Banded"] = style
        return sheet
    }

    private func table(rows: Int, look: TableLook) -> Table {
        var table = Table(
            rows: (0..<rows).map { _ in
                TableRow(cells: [TableCell(blocks: []), TableCell(blocks: [])])
            },
            gridColumns: [1000, 1000], styleID: "Banded", hasBorders: true
        )
        table.look = look
        return table
    }

    @Test("The header row, the bands and the first column each get their own look")
    func conditions() {
        var cells = table(rows: 4, look: TableLook())
        cells.rows[3].cells[1].shadingHex = "FF0000"
        let appearances = TableStyling.appearances(of: cells, styles: styles())
        #expect(appearances[0][1].fillHex == "4472C4")
        #expect(appearances[0][1].condition.runStyle.isBold == true)
        // Bands start after the header row: rows 1 and 3 are the first band.
        #expect(appearances[1][1].fillHex == "D9E2F3")
        #expect(appearances[2][1].fillHex == "FFFFFF")
        // The header row wins over the first column, but keeps its italics.
        #expect(appearances[0][0].condition.runStyle.isItalic == true)
        #expect(appearances[0][0].fillHex == "4472C4")
        // A cell's own shading beats its style's.
        #expect(appearances[3][1].fillHex == "FF0000")
    }

    @Test("A table can turn its style's header row and bands off")
    func look() {
        let plain = TableLook(firstRow: false, firstColumn: false, bandedRows: false)
        let appearances = TableStyling.appearances(of: table(rows: 3, look: plain), styles: styles())
        #expect(appearances.flatMap { $0 }.allSatisfy { $0.fillHex == "FFFFFF" })
    }

    @Test("tblLook reads as hex flags and as attributes")
    func lookFlags() throws {
        let hex = try XMLLite.parse(Data("<tblLook val=\"04A0\"/>".utf8))
        let flags = PropertyReader.tableLook(hex)
        #expect(flags.firstRow && flags.firstColumn && flags.bandedRows && !flags.bandedColumns && !flags.lastRow)
        let attributes = try XMLLite.parse(Data("<tblLook firstRow=\"0\" noHBand=\"1\"/>".utf8))
        let named = PropertyReader.tableLook(attributes)
        #expect(!named.firstRow && !named.bandedRows)
    }
}
