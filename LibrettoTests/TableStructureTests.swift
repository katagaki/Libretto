import Foundation
import Testing
@testable import Libretto

@Suite("Table structure")
struct TableStructureTests {
    /// A table of `rows` by `columns`, each cell's text its position.
    private func table(_ rows: Int, _ columns: Int) -> Table {
        Table(
            rows: (0..<rows).map { row in
                TableRow(cells: (0..<columns).map { column in
                    TableCell(blocks: [.paragraph(Paragraph(text: "\(row)\(column)"))])
                })
            },
            gridColumns: Array(repeating: 1440, count: columns), preservedPropertiesXML: nil, styleID: nil, hasBorders: true
        )
    }

    private func texts(_ table: Table) -> [[String]] {
        table.rows.map { $0.cells.map(\.plainText) }
    }

    private func written(_ table: Table) throws -> (xml: String, reread: Table) {
        var document = WordDocument()
        document.body = [.table(table), .paragraph(Paragraph())]
        let parts = try ZipArchive.entries(in: DOCXWriter.data(from: document))
        let reread = try DOCXReader.document(fromParts: parts)
        guard case .table(let back) = reread.body[0] else { throw CocoaError(.fileReadCorruptFile) }
        return (String(decoding: parts["word/document.xml"]!, as: UTF8.self), back)
    }

    @Test("Rows and columns go in anywhere, and come out")
    func rowsAndColumns() {
        var table = table(2, 2)
        TableEditing.insertRow(in: &table, at: 0, below: true)
        TableEditing.insertColumn(in: &table, at: 0, after: false)
        #expect(texts(table) == [["", "00", "01"], ["", "", ""], ["", "10", "11"]])
        #expect(table.gridColumns.count == 3)
        #expect(table.gridColumns.reduce(0, +) == 2880)
        TableEditing.deleteRow(in: &table, at: 1)
        TableEditing.deleteColumn(in: &table, at: 0)
        #expect(texts(table) == [["00", "01"], ["10", "11"]])
    }

    @Test("Merged cells span and continue, gather their text, and split back")
    func mergeAndSplit() throws {
        var table = table(3, 3)
        #expect(!TableEditing.canMerge(table, rows: 0...0, columns: 0...0))
        TableEditing.merge(in: &table, rows: 0...1, columns: 0...1)
        #expect(table.rows[0].cells[0].gridSpan == 2)
        #expect(table.rows[0].cells[0].verticalMerge == .restart)
        #expect(table.rows[1].cells[0].verticalMerge == .continue)
        #expect(table.rows[0].cells[0].plainText == "00\n01\n10\n11")
        #expect(texts(table)[2] == ["20", "21", "22"])
        // Half of the merged cell cannot be merged with what is beside it.
        #expect(!TableEditing.canMerge(table, rows: 0...0, columns: 1...2))

        let (xml, reread) = try written(table)
        #expect(xml.contains("<w:tcPr><w:gridSpan w:val=\"2\"/><w:vMerge w:val=\"restart\"/></w:tcPr>"))
        #expect(xml.contains("<w:tcPr><w:gridSpan w:val=\"2\"/><w:vMerge/></w:tcPr>"))
        #expect(reread.rows[1].cells[0].verticalMerge == .continue)

        TableEditing.split(in: &table, at: CellPosition(row: 0, column: 0))
        #expect(table.rows.allSatisfy { $0.cells.count == 3 && $0.cells.allSatisfy { $0.gridSpan == 1 && $0.verticalMerge == nil } })
    }

    @Test("Inserting a column inside a spanning cell widens it")
    func columnInsideSpan() {
        var table = table(2, 3)
        TableEditing.merge(in: &table, rows: 0...0, columns: 0...1)
        TableEditing.insertColumn(in: &table, at: 0, after: true)
        #expect(table.rows[0].cells[0].gridSpan == 3)
        #expect(table.rows[1].cells.count == 4)
    }

    @Test("Shading, borders, a style, its look, widths and header rows are written into the table's properties")
    func appearance() throws {
        var table = table(2, 2)
        var styles = WordDocument().styles
        let style = styles.ensureTableStyle(BuiltInTableStyle.gridAccent.rawValue)
        TableEditing.setStyle(in: &table, styleID: style, styles: styles)
        var look = table.look
        look.bandedRows = false
        TableEditing.setLook(in: &table, look)
        TableEditing.setShading(in: &table, cells: [CellPosition(row: 1, column: 1)], hex: "FFF2CC")
        TableEditing.setHeader(in: &table, row: 0, true)
        TableEditing.setColumnWidth(in: &table, column: 0, to: 2880)
        #expect(table.hasBorders)

        let (xml, reread) = try written(table)
        #expect(xml.contains("<w:tblPr><w:tblStyle w:val=\"GridTable4-Accent1\"/>"))
        #expect(xml.contains("w:noHBand=\"1\""))
        #expect(xml.contains("<w:trPr><w:tblHeader/></w:trPr>"))
        #expect(xml.contains("w:fill=\"FFF2CC\""))
        #expect(reread.gridColumns == [2880, 1440])
        #expect(reread.rows[0].isHeader)
        #expect(reread.rows[1].cells[1].shadingHex == "FFF2CC")
        #expect(!reread.look.bandedRows)

        TableEditing.setBorders(in: &table, .none)
        #expect(!table.hasBorders)
        #expect(try written(table).xml.contains("<w:insideV w:val=\"nil\"/>"))
    }

    @Test("A table style the document lacks is added with its definition")
    func addsTableStyle() throws {
        var document = WordDocument()
        let id = document.styles.ensureTableStyle(BuiltInTableStyle.gridAccent.rawValue)
        let conditions = document.styles.tableConditions(styleID: id)
        #expect(conditions[.firstRow]?.fillHex == "4472C4")
        let styles = String(decoding: try ZipArchive.entries(in: DOCXWriter.data(from: document))["word/styles.xml"]!, as: UTF8.self)
        #expect(styles.contains("w:styleId=\"GridTable4-Accent1\""))
        #expect(!document.styles.tableStyles.contains { $0.id == "TableGrid" && $0.name == "Grid Table 4 Accent 1" })
    }
}

@MainActor
@Suite("Tables across pages")
struct TablePagesTests {
    @Test("Header rows are drawn again at the top of each page a table runs on to")
    func repeatsHeader() throws {
        var table = Table(
            rows: (0..<80).map { row in
                TableRow(cells: [TableCell(blocks: [.paragraph(Paragraph(text: row == 0 ? "Region" : "Row \(row)"))])])
            },
            gridColumns: [4000], preservedPropertiesXML: nil, styleID: nil, hasBorders: true
        )
        TableEditing.setHeader(in: &table, row: 0, true)
        var document = WordDocument()
        document.body = [.table(table), .paragraph(Paragraph())]
        let controller = DocumentTextController(document: document, scheme: .light)
        let layout = controller.layoutManager
        let storage = controller.textView.textStorage
        // The first row on the second page.
        var found: (glyph: Int, rect: CGRect)?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard value is BlockAttachment else { return }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if controller.geometry.page(containing: rect.midY) == 1 {
                found = (glyph, rect)
                stop.pointee = true
            }
        }
        let (glyph, rect) = try #require(found)
        let rowHeight = layout.attachmentSize(forGlyphAt: glyph).height
        // Room for the header row above it, as tall as a row.
        #expect(rect.height > rowHeight * 1.8)
        #expect(abs(rect.minY - controller.geometry.textTop(1)) < 1)
    }
}
