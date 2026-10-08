import UIKit

/// Editing a table cell where it is on the page: a text view laid over the
/// cell, holding its paragraphs as the page shows them, read back into the
/// cell when editing ends.
@MainActor
final class CellEditingSession: NSObject, UITextViewDelegate {
    let tableID: Table.ID
    let position: CellPosition
    let editor = CellEditorView()
    /// The cell's last paragraph, which carries its properties when its mark is not in the text.
    private let finalParagraph: Paragraph
    weak var controller: DocumentTextController?
    private var isEnding = false

    init(tableID: Table.ID, position: CellPosition, text: NSAttributedString, finalParagraph: Paragraph) {
        self.tableID = tableID
        self.position = position
        self.finalParagraph = finalParagraph
        super.init()
        editor.attributedText = text
        editor.delegate = self
        editor.session = self
    }

    /// The cell's paragraphs as edited.
    var blocks: [Block] {
        let read = AttributedReader.blocks(from: editor.attributedText, finalParagraph: finalParagraph, trailingMarkers: [])
        let paragraphs = read.blocks.filter { if case .paragraph = $0 { return true } else { return false } }
        return paragraphs.isEmpty ? [.paragraph(Paragraph())] : paragraphs
    }

    func textViewDidChange(_ textView: UITextView) {
        controller?.fitCellEditor()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard !isEnding else { return }
        isEnding = true
        controller?.endCellEditing()
    }

    /// Tab goes on to the next cell, Shift-Tab back to the one before.
    func moveToCell(forward: Bool) {
        isEnding = true
        controller?.endCellEditing(thenMove: forward ? 1 : -1)
    }
}

final class CellEditorView: UITextView {
    weak var session: CellEditingSession?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isScrollEnabled = false
        backgroundColor = .systemBackground
        layer.borderColor = UIColor.tintColor.cgColor
        layer.borderWidth = 1.5
        layer.cornerRadius = 2
        textContainerInset = UIEdgeInsets(
            top: TableRenderer.verticalPadding, left: TableRenderer.horizontalPadding,
            bottom: TableRenderer.verticalPadding, right: TableRenderer.horizontalPadding
        )
        textContainer.lineFragmentPadding = 0
        allowsEditingTextAttributes = false
        smartInsertDeleteType = .no
        accessibilityIdentifier = "cellEditor"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(nextCell)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(previousCell)),
        ].map { command in
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func nextCell() { session?.moveToCell(forward: true) }
    @objc private func previousCell() { session?.moveToCell(forward: false) }
}

extension DocumentTextController: UIGestureRecognizerDelegate {
    /// The table row picture at a point in the text view, and the point within it.
    private func tableRow(at point: CGPoint) -> (attachment: BlockAttachment, table: Table, rect: CGRect)? {
        guard storage.length > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
              let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? BlockAttachment,
              attachment.rowID != nil, case .table(let table) = attachment.block else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        return (attachment, table, rect)
    }

    /// The cell a point falls in: its position, and its frame in the text view.
    private func cell(at point: CGPoint) -> (table: Table, position: CellPosition, frame: CGRect)? {
        guard let (attachment, table, rect) = tableRow(at: point),
              let rowIndex = table.rows.firstIndex(where: { $0.id == attachment.rowID }) else { return nil }
        let widths = TableRenderer.columnWidths(table, availableWidth: context.contentWidth)
        let x = point.x - rect.minX
        let row = table.rows[rowIndex]
        let starts = TableEditing.gridStarts(of: row)
        for (index, cell) in row.cells.enumerated() {
            let start = widths.prefix(starts[index]).reduce(0, +)
            let width = widths.dropFirst(starts[index]).prefix(max(1, cell.gridSpan)).reduce(0, +)
            guard x >= start, x < start + width else { continue }
            var position = CellPosition(row: rowIndex, column: starts[index])
            // A cell that carries on a merge is edited as the cell it merges with.
            while position.row > 0, let at = TableEditing.cellIndex(in: table.rows[position.row], coveringColumn: position.column),
                  table.rows[position.row].cells[at].verticalMerge == .continue {
                position.row -= 1
            }
            return (table, position, CGRect(x: rect.minX + start + 0.5, y: rect.minY, width: width, height: rect.height))
        }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: textView)
        return cell(at: point) != nil || floatingImage(at: point) != nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc func tappedTableCell(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: textView)
        // A floating picture is picked out by its character, which takes no room in the text.
        if let location = floatingImage(at: point) {
            DispatchQueue.main.async {
                self.textView.selectedRange = NSRange(location: location, length: 1)
                self.selectionDidChange()
            }
            return
        }
        guard let (table, position, _) = cell(at: point) else { return }
        beginCellEditing(table: table, at: position)
    }

    /// Lays an editor over a cell, holding its text.
    func beginCellEditing(table: Table, at position: CellPosition) {
        if cellSession != nil { endCellEditing() }
        guard let table = currentTable(table.id) ?? Optional(table), table.rows.indices.contains(position.row),
              let index = TableEditing.cellIndex(in: table.rows[position.row], coveringColumn: position.column) else { return }
        let cell = table.rows[position.row].cells[index]
        let appearance = TableStyling.appearances(of: table, styles: document.styles)[position.row][index]
        let cellContext = TableStyling.context(context, for: appearance)
        let rendered = DocumentRenderer.render(cell.blocks, context: cellContext)
        let session = CellEditingSession(
            tableID: table.id, position: position, text: rendered.string, finalParagraph: rendered.finalParagraph
        )
        session.controller = self
        if let fill = appearance.fillHex.flatMap({ AdaptiveColor.uiColor(hex: $0, for: scheme, isText: false) }) {
            session.editor.backgroundColor = fill
        }
        cellSession = session
        textView.addSubview(session.editor)
        fitCellEditor()
        session.editor.becomeFirstResponder()
        session.editor.selectedRange = NSRange(location: session.editor.textStorage.length, length: 0)
    }

    /// The table as the text has it now.
    private func currentTable(_ id: Table.ID) -> Table? {
        guard let range = lineRange(ofBlock: id),
              let box = storage.attribute(.librettoBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) as? BlockBox,
              case .table(let table) = box.block else { return nil }
        return table
    }

    /// Sizes the editor to the cell, and to its text if that is taller.
    func fitCellEditor() {
        guard let session = cellSession, let table = currentTable(session.tableID),
              let rowRange = lineRange(ofBlock: session.tableID) else { return }
        // The row's picture: the attachment for this row on the table's line.
        let rowID = table.rows.indices.contains(session.position.row) ? table.rows[session.position.row].id : nil
        var rowRect: CGRect?
        storage.enumerateAttribute(.attachment, in: rowRange) { value, range, stop in
            guard let attachment = value as? BlockAttachment, attachment.rowID == rowID else { return }
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            rowRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            stop.pointee = true
        }
        guard let rowRect, let index = TableEditing.cellIndex(in: table.rows[session.position.row], coveringColumn: session.position.column)
        else { return }
        let widths = TableRenderer.columnWidths(table, availableWidth: context.contentWidth)
        let start = widths.prefix(session.position.column).reduce(0, +)
        let width = widths.dropFirst(session.position.column).prefix(max(1, table.rows[session.position.row].cells[index].gridSpan))
            .reduce(0, +)
        let fitted = session.editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        session.editor.frame = CGRect(
            x: rowRect.minX + start + 0.5, y: rowRect.minY, width: width, height: max(rowRect.height, fitted.height)
        )
    }

    /// Reads the edited text back into its cell, and, with `step`, edits the next cell or the one before.
    func endCellEditing(thenMove step: Int = 0) {
        guard let session = cellSession else { return }
        cellSession = nil
        session.editor.removeFromSuperview()
        guard var table = currentTable(session.tableID), table.rows.indices.contains(session.position.row),
              let index = TableEditing.cellIndex(in: table.rows[session.position.row], coveringColumn: session.position.column)
        else { return }
        let blocks = session.blocks
        if blocks.flatMap(\.paragraphs) != table.rows[session.position.row].cells[index].blocks.flatMap(\.paragraphs) {
            table.rows[session.position.row].cells[index].blocks = blocks
            replaceTable(table)
        }
        guard step != 0 else { return }
        // Cells in reading order: along the row, then on to the next.
        var positions: [CellPosition] = []
        for (rowIndex, row) in table.rows.enumerated() {
            for (cellIndex, cell) in row.cells.enumerated() where cell.verticalMerge != .continue {
                positions.append(CellPosition(row: rowIndex, column: TableEditing.gridStarts(of: row)[cellIndex]))
            }
        }
        guard let current = positions.firstIndex(of: session.position) else { return }
        let next = current + step
        guard positions.indices.contains(next) else { return }
        beginCellEditing(table: table, at: positions[next])
    }
}
