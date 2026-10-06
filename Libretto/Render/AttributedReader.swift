import UIKit

/// Reads the editor's text back into blocks, from the model its attributes carry.
enum AttributedReader {
    struct Result {
        var blocks: [Block]
        /// Whether the text no longer looks like what it reads as — rows gone
        /// from a table, text typed on a table's line — and should be
        /// rendered afresh.
        var needsRender = false
    }

    static func blocks(
        from text: NSAttributedString, finalParagraph: Paragraph, trailingMarkers: [Inline]
    ) -> Result {
        var needsRender = false
        let string = text.string as NSString
        var blocks: [Block] = []
        var start = 0
        while true {
            let markRange = string.range(
                of: "\n", options: .literal, range: NSRange(location: start, length: string.length - start)
            )
            let hasMark = markRange.location != NSNotFound
            let end = hasMark ? markRange.location : string.length
            let segment = NSRange(location: start, length: end - start)
            blocks += read(
                segment, mark: hasMark ? end : nil, in: text,
                finalParagraph: finalParagraph, trailingMarkers: hasMark ? [] : trailingMarkers,
                needsRender: &needsRender
            )
            guard hasMark else { break }
            start = end + 1
        }
        return Result(blocks: uniquingParagraphs(blocks), needsRender: needsRender)
    }

    // MARK: - Segments

    private static func read(
        _ segment: NSRange, mark: Int?, in text: NSAttributedString,
        finalParagraph: Paragraph, trailingMarkers: [Inline], needsRender: inout Bool
    ) -> [Block] {
        let isBlockLine = mark.map { text.attribute(.librettoBlock, at: $0, effectiveRange: nil) != nil } ?? false
        var attachments: [BlockAttachment] = []
        if segment.length > 0 {
            text.enumerateAttribute(.attachment, in: segment) { value, _, _ in
                if let attachment = value as? BlockAttachment { attachments.append(attachment) }
            }
        }
        guard isBlockLine || !attachments.isEmpty else {
            let box = mark.flatMap { text.attribute(.librettoParagraph, at: $0, effectiveRange: nil) as? ParagraphBox }
                ?? (segment.length > 0
                    ? text.attribute(.librettoParagraph, at: segment.location, effectiveRange: nil) as? ParagraphBox
                    : nil)
            var paragraph = box?.paragraph ?? finalParagraph
            var inlines = self.inlines(in: segment, of: text, skippingUnformatted: false)
            if let mark, let markers = text.attribute(.librettoMarkers, at: mark, effectiveRange: nil) as? MarkersBox {
                inlines += markers.markers
            }
            inlines += trailingMarkers
            paragraph.inlines = InlineNormalizer.normalized(inlines)
            return [.paragraph(paragraph)]
        }

        // A line of block pictures: whichever of its rows are still there.
        var result: [Block] = []
        var index = 0
        while index < attachments.count {
            let block = attachments[index].block
            var rows: Set<TableRow.ID> = []
            while index < attachments.count, attachments[index].block.id == block.id {
                if let row = attachments[index].rowID { rows.insert(row) }
                index += 1
            }
            switch block {
            case .table(var table):
                let kept = table.rows.filter { rows.contains($0.id) }
                if kept.count != table.rows.count { needsRender = true }
                table.rows = kept
                if !table.rows.isEmpty { result.append(.table(table)) }
            default:
                result.append(block)
            }
        }
        // Text typed beside a block becomes a paragraph after it.
        let typed = inlines(in: segment, of: text, skippingUnformatted: true)
        if !typed.isEmpty || !isBlockLine || attachments.isEmpty { needsRender = true }
        if !typed.isEmpty {
            result.append(.paragraph(Paragraph(inlines: InlineNormalizer.normalized(typed))))
        }
        return result
    }

    private static func inlines(
        in segment: NSRange, of text: NSAttributedString, skippingUnformatted: Bool
    ) -> [Inline] {
        guard segment.length > 0 else { return [] }
        let string = text.string as NSString
        var result: [Inline] = []
        var seenMarkers: Set<ObjectIdentifier> = []
        var token: (box: InlineBox, text: String)?

        func flushToken() {
            guard let current = token else { return }
            token = nil
            if current.text == current.box.display {
                result.append(current.box.inline)
            } else if !current.text.isEmpty {
                // Edited: what it was is gone, and what is left is plain text.
                result.append(Inline(.text(current.text), format: current.box.inline.format,
                                     hyperlink: current.box.inline.hyperlink))
            }
        }

        text.enumerateAttributes(in: segment) { attributes, range, _ in
            if let markers = attributes[.librettoMarkers] as? MarkersBox,
               seenMarkers.insert(ObjectIdentifier(markers)).inserted {
                flushToken()
                result += markers.markers
            }
            if let box = attributes[.librettoToken] as? InlineBox {
                if token?.box !== box { flushToken() }
                token = (box, (token?.text ?? "") + string.substring(with: range))
                return
            }
            flushToken()

            if let attachment = attributes[.attachment] as? ImageAttachment {
                result.append(attachment.inline)
                return
            }
            if attributes[.attachment] is BlockAttachment { return }
            let run = attributes[.librettoRun] as? RunBox
            if skippingUnformatted, run == nil { return }
            let format = run?.format ?? RunFormat()
            let hyperlink = run?.hyperlink

            // UTF-16 units, gathered whole: a character outside the Basic
            // Multilingual Plane, an emoji say, is two of them.
            var pending: [unichar] = []
            func flushText() {
                if !pending.isEmpty {
                    let text = String(utf16CodeUnits: pending, count: pending.count)
                    result.append(Inline(.text(text), format: format, hyperlink: hyperlink))
                }
                pending = []
            }
            for offset in 0..<range.length {
                let unit = string.character(at: range.location + offset)
                switch unit {
                case TextCharacters.tabUnit:
                    flushText()
                    result.append(Inline(.tab, format: format, hyperlink: hyperlink))
                case TextCharacters.lineBreakUnit, 0x0D, 0x2029:
                    flushText()
                    result.append(Inline(.lineBreak, format: format, hyperlink: hyperlink))
                case TextCharacters.pageBreakUnit:
                    flushText()
                    result.append(Inline(.pageBreak, format: format, hyperlink: hyperlink))
                case TextCharacters.attachmentUnit:
                    // An attachment from elsewhere, which there is no part for.
                    flushText()
                default:
                    pending.append(unit)
                }
            }
            flushText()
        }
        flushToken()
        return result
    }

    /// Splitting a paragraph leaves two with the same box. The last keeps
    /// what belongs to the paragraph mark, as in Word; the others get copies.
    private static func uniquingParagraphs(_ blocks: [Block]) -> [Block] {
        var remaining: [UUID: Int] = [:]
        for block in blocks { remaining[block.id, default: 0] += 1 }
        guard remaining.values.contains(where: { $0 > 1 }) else { return blocks }
        return blocks.map { block in
            let id = block.id
            remaining[id, default: 1] -= 1
            guard remaining[id, default: 0] > 0 else { return block }
            switch block {
            case .paragraph(let paragraph): return .paragraph(paragraph.splitCopy())
            case .table(var table):
                table.id = UUID()
                table.originalXML = nil
                return .table(table)
            case .preserved(var preserved):
                preserved.id = UUID()
                return .preserved(preserved)
            }
        }
    }
}
