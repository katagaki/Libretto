import UIKit

/// Draws tables, row by row, and kept blocks, line by line, as pictures for
/// the page view's text.
enum TableRenderer {
    /// Word's default cell margins.
    static let horizontalPadding: CGFloat = 5.4
    static let verticalPadding: CGFloat = 1.5

    /// Each column's width in points, fitted to the text width when the
    /// table's own grid would be wider.
    static func columnWidths(_ table: Table, availableWidth: CGFloat) -> [CGFloat] {
        let count = max(1, table.columnCount)
        var widths = table.gridColumns.map { CGFloat($0) / 20 }
        if widths.count < count || widths.contains(where: { $0 <= 0 }) {
            widths = Array(repeating: availableWidth / CGFloat(count), count: count)
        }
        let total = widths.reduce(0, +)
        let scale = total > availableWidth ? availableWidth / total : 1
        return widths.map { $0 * scale }
    }

    static func rowImages(_ table: Table, context: RenderContext) -> [(rowID: TableRow.ID, image: UIImage)] {
        let widths = columnWidths(table, availableWidth: context.contentWidth)
        let tableWidth = widths.reduce(0, +)
        let ink = context.defaultTextColor
        let lineColor = table.hasBorders ? ink.withAlphaComponent(0.75) : ink.withAlphaComponent(0.18)

        return table.rows.enumerated().map { rowIndex, row in
            // Lay the row's cells out first: their text decides its height.
            var column = 0
            var cells: [(frame: CGRect, text: NSAttributedString?, fill: UIColor?, continues: Bool)] = []
            var height: CGFloat = 14
            for cell in row.cells {
                let span = max(1, cell.gridSpan)
                let x = widths.prefix(column).reduce(0, +)
                let width = widths.dropFirst(column).prefix(span).reduce(0, +)
                column += span
                let continues = cell.verticalMerge == .continue
                let text = continues ? nil : cellText(cell, context: context)
                if let text {
                    let bounds = text.boundingRect(
                        with: CGSize(width: max(1, width - horizontalPadding * 2), height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                    )
                    height = max(height, ceil(bounds.height) + verticalPadding * 2)
                }
                let fill = cell.shadingHex.flatMap { AdaptiveColor.uiColor(hex: $0, for: context.scheme, isText: false) }
                cells.append((CGRect(x: x, y: 0, width: width, height: 0), text, fill, continues))
            }
            height = min(height, context.contentHeight * 0.95)
            let isLastRow = rowIndex == table.rows.count - 1

            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = false
            let size = CGSize(width: ceil(tableWidth) + 1, height: ceil(height) + (isLastRow ? 1 : 0))
            let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                let graphics = renderer.cgContext
                for cell in cells {
                    let frame = CGRect(x: cell.frame.minX + 0.5, y: 0, width: cell.frame.width, height: height)
                    if let fill = cell.fill {
                        fill.setFill()
                        graphics.fill(frame)
                    }
                    if let text = cell.text {
                        let textFrame = frame.insetBy(dx: horizontalPadding, dy: verticalPadding)
                        text.draw(with: textFrame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    }
                    graphics.setStrokeColor(lineColor.cgColor)
                    graphics.setLineWidth(table.hasBorders ? 0.75 : 0.5)
                    var lines: [(CGPoint, CGPoint)] = [
                        (CGPoint(x: frame.minX, y: 0), CGPoint(x: frame.minX, y: height)),
                        (CGPoint(x: frame.maxX, y: 0), CGPoint(x: frame.maxX, y: height)),
                    ]
                    if !cell.continues { lines.append((CGPoint(x: frame.minX, y: 0.25), CGPoint(x: frame.maxX, y: 0.25))) }
                    if isLastRow { lines.append((CGPoint(x: frame.minX, y: height), CGPoint(x: frame.maxX, y: height))) }
                    for (start, end) in lines {
                        graphics.move(to: start)
                        graphics.addLine(to: end)
                    }
                    graphics.strokePath()
                }
            }
            return (row.id, image)
        }
    }

    /// A cell's paragraphs as text, styled as they would be in the body.
    static func cellText(_ cell: TableCell, context: RenderContext) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var labeler = ListLabeler(context: context)
        for (index, block) in cell.blocks.enumerated() {
            switch block {
            case .paragraph(let paragraph):
                let label = labeler.label(for: paragraph.properties)
                let isLast = index == cell.blocks.count - 1
                var (text, _) = DocumentRenderer.render(paragraph, label: label, context: context, withMark: !isLast)
                if let label, !label.text.isEmpty {
                    let prefixed = NSMutableAttributedString(
                        string: label.text + "\t",
                        attributes: text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
                    )
                    prefixed.append(text)
                    text = prefixed
                }
                output.append(text)
            case .table(let nested):
                output.append(NSAttributedString(
                    string: nested.rows.map { $0.cells.map(\.plainText).joined(separator: " | ") }.joined(separator: "\n")
                        + "\n",
                    attributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: context.defaultTextColor]
                ))
            case .preserved(let preserved):
                output.append(NSAttributedString(
                    string: preserved.displayText + "\n",
                    attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: context.defaultTextColor]
                ))
            }
        }
        // Drawn text has no use for attachments it cannot show.
        output.removeAttribute(.attachment, range: NSRange(location: 0, length: output.length))
        return output
    }

    /// A kept block's text, one picture per line, tinted to show it is not editable.
    static func preservedImages(_ block: PreservedBlock, context: RenderContext) -> [UIImage] {
        let text = block.displayText.isEmpty ? String(localized: "Block.Preserved.Placeholder") : block.displayText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: context.defaultTextColor.withAlphaComponent(0.75),
        ]
        let width = context.contentWidth
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return text.components(separatedBy: "\n").map { line in
            let string = NSAttributedString(string: line.isEmpty ? " " : line, attributes: attributes)
            let bounds = string.boundingRect(
                with: CGSize(width: width - 12, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            )
            let size = CGSize(width: width, height: min(ceil(bounds.height) + 4, context.contentHeight * 0.95))
            return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                UIColor.systemGray.withAlphaComponent(0.12).setFill()
                renderer.cgContext.fill(CGRect(origin: .zero, size: size))
                UIColor.systemGray.withAlphaComponent(0.5).setFill()
                renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: size.height))
                string.draw(
                    with: CGRect(x: 8, y: 2, width: width - 12, height: size.height - 4),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                )
            }
        }
    }
}
