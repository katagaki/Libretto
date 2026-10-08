import UIKit

/// The editor's text for a run of blocks, and what does not fit in it.
struct RenderedText {
    let string: NSMutableAttributedString
    /// The last paragraph, which has no mark of its own to carry its box when
    /// it is empty.
    let finalParagraph: Paragraph
    /// Markers after the last character of the last paragraph.
    let trailingMarkers: [Inline]
}

/// Turns blocks into the attributed text the page view edits and the PDF
/// export draws.
///
/// Paragraphs become their text, each ended by a paragraph mark except the
/// last. Tables become one picture per row, so a long table breaks across
/// pages between rows, and kept blocks one picture per line.
enum DocumentRenderer {
    static func render(_ blocks: [Block], context: RenderContext) -> RenderedText {
        let output = NSMutableAttributedString()
        var labeler = ListLabeler(context: context)
        var finalParagraph = Paragraph()
        var trailing: [Inline] = []

        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            switch block {
            case .paragraph(let paragraph):
                let label = labeler.label(for: paragraph.properties)
                let (text, leftover) = render(paragraph, label: label, context: context, withMark: !isLast)
                output.append(text)
                if isLast {
                    finalParagraph = paragraph
                    trailing = leftover
                }
            case .table, .preserved:
                output.append(renderBlock(block, context: context))
                // A block is followed by a paragraph, which Word insists on.
                if isLast { finalParagraph = Paragraph() }
            }
        }
        return RenderedText(string: output, finalParagraph: finalParagraph, trailingMarkers: trailing)
    }

    // MARK: - Paragraphs

    static func paragraphAttributes(
        _ paragraph: Paragraph, label: ListLabelBox?, context: RenderContext
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .librettoParagraph: ParagraphBox(paragraph),
            .paragraphStyle: Typography.paragraphStyle(
                paragraph.properties, context: context, isListItem: label != nil
            ),
        ]
        if let label { attributes[.librettoListLabel] = label }
        if let dropCap = context.styles.resolvedParagraphProperties(paragraph.properties).dropCap {
            attributes[.librettoDropCap] = DropCapBox(dropCap)
        }
        return attributes
    }

    /// One paragraph's text. Returns markers that found no character to ride
    /// on, which happens only when there is no mark.
    static func render(
        _ paragraph: Paragraph, label: ListLabelBox?, context: RenderContext, withMark: Bool
    ) -> (NSAttributedString, [Inline]) {
        let output = NSMutableAttributedString()
        let base = paragraphAttributes(paragraph, label: label, context: context)
        var pending: [Inline] = []
        var lastFormat = RunFormat()

        for inline in paragraph.inlines {
            if inline.content.isMarker {
                pending.append(inline)
                continue
            }
            var attributes = base.merging(
                runAttributes(
                    inline.format, hyperlink: inline.hyperlink, revision: inline.revision, paragraph: paragraph,
                    context: context
                )
            ) { _, run in run }
            let string: String
            switch inline.content {
            case .text(let text):
                string = text.replacingOccurrences(of: "\n", with: TextCharacters.lineBreak)
            case .tab:
                string = "\t"
            case .lineBreak:
                string = TextCharacters.lineBreak
            case .pageBreak:
                string = TextCharacters.pageBreak
            case .columnBreak:
                string = TextCharacters.columnBreak
            case .image(let image):
                attributes[.attachment] = imageAttachment(
                    image, inline: inline, context: context,
                    maximumHeight: maximumImageHeight(in: base[.paragraphStyle] as? NSParagraphStyle, context: context)
                )
                string = TextCharacters.attachment
            case .paragraphChild(let xml, _) where MathRenderer.isEquation(xml):
                // An equation stands in its line as its picture, sitting on the baseline.
                attributes[.attachment] = equationAttachment(xml, attributes: attributes, context: context)
                attributes[.librettoToken] = InlineBox(inline, display: TextCharacters.attachment)
                string = TextCharacters.attachment
            case .runChild(_, let display), .paragraphChild(_, let display):
                let shown = display ?? ""
                attributes[.librettoToken] = InlineBox(inline, display: shown)
                string = shown
            case .note(let reference):
                let shown = context.noteNumbers["\(reference.kind.rawValue):\(reference.id)"] ?? "*"
                attributes[.librettoToken] = InlineBox(inline, display: shown)
                string = shown
            }
            guard !string.isEmpty else { continue }
            let piece = NSMutableAttributedString(string: string, attributes: attributes)
            if !pending.isEmpty {
                // The whole first character, which may be more than one UTF-16 unit.
                let first = (piece.string as NSString).rangeOfComposedCharacterSequence(at: 0)
                piece.addAttribute(.librettoMarkers, value: MarkersBox(pending), range: first)
                pending = []
            }
            output.append(piece)
            lastFormat = inline.format
        }

        guard withMark else { return (output, pending) }
        // The mark looks like the text before it, so an empty paragraph is as
        // tall as one with text in it.
        var attributes = base.merging(
            runAttributes(lastFormat, hyperlink: nil, revision: paragraph.markRevision, paragraph: paragraph, context: context)
        ) { _, run in run }
        if !pending.isEmpty { attributes[.librettoMarkers] = MarkersBox(pending) }
        output.append(NSAttributedString(string: "\n", attributes: attributes))
        return (output, [])
    }

    static func runAttributes(
        _ format: RunFormat, hyperlink: Hyperlink?, revision: Revision? = nil, paragraph: Paragraph,
        context: RenderContext
    ) -> [NSAttributedString.Key: Any] {
        var attributes = Typography.runAttributes(
            format.style, paragraph: paragraph.properties, hyperlink: hyperlink, revision: revision, context: context
        )
        attributes[.librettoRun] = RunBox(format, hyperlink: hyperlink, revision: revision)
        return attributes
    }

    /// How tall a picture can be and still have its line fit on a page:
    /// the line is taller than the picture by the paragraph's spacing, and
    /// stretched by its line height.
    static func maximumImageHeight(in style: NSParagraphStyle?, context: RenderContext) -> CGFloat {
        let spacing = (style?.paragraphSpacingBefore ?? 0) + (style?.paragraphSpacing ?? 0)
        let multiple = max(1, style?.lineHeightMultiple ?? 1)
        return max(24, (context.contentHeight - spacing) / multiple * 0.9)
    }

    static func imageAttachment(
        _ image: InlineImage, inline: Inline, context: RenderContext, maximumHeight: CGFloat? = nil
    ) -> ImageAttachment {
        let attachment = ImageAttachment()
        attachment.inline = inline
        attachment.image = context.images.image(for: image, in: context.package) ?? UIImage(systemName: "photo")
        // A floating picture takes no room in its line: the page layout sets it where it sits.
        guard image.wrap == .inline else {
            attachment.bounds = CGRect(x: 0, y: 0, width: 0.01, height: 0.01)
            return attachment
        }
        // Never wider than the text, nor taller than a page, or it could not be laid out at all.
        let tallest = maximumHeight ?? context.contentHeight * 0.75
        let scale = min(1, context.contentWidth / max(image.width, 1), tallest / max(image.height, 1))
        attachment.bounds = CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale)
        return attachment
    }

    static func equationAttachment(
        _ xml: String, attributes: [NSAttributedString.Key: Any], context: RenderContext
    ) -> NSTextAttachment {
        let font = attributes[.font] as? UIFont ?? .systemFont(ofSize: 11)
        let color = attributes[.foregroundColor] as? UIColor ?? context.defaultTextColor
        let attachment = NSTextAttachment()
        guard let drawn = context.images.equation(xml, fontSize: font.pointSize, color: color) else { return attachment }
        attachment.image = drawn.image
        attachment.bounds = CGRect(
            x: 0, y: -drawn.descent, width: min(drawn.image.size.width, context.contentWidth), height: drawn.image.size.height
        )
        return attachment
    }

    // MARK: - Blocks

    /// How the line of a block's pictures is set: tight, so rows sit flush.
    static func blockParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        style.lineSpacing = 0
        return style
    }

    static let blockFont = UIFont.systemFont(ofSize: 1)

    static func renderBlock(_ block: Block, context: RenderContext) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lineAttributes: [NSAttributedString.Key: Any] = [
            .font: blockFont, .paragraphStyle: blockParagraphStyle(),
        ]
        let pictures: [(image: UIImage, rowID: TableRow.ID?)]
        switch block {
        case .table(let table):
            pictures = TableRenderer.rowImages(table, context: context).map { ($0.image, $0.rowID) }
        case .preserved(let preserved):
            pictures = TableRenderer.preservedImages(preserved, context: context).map { ($0, nil) }
        case .paragraph:
            pictures = []
        }
        for (index, picture) in pictures.enumerated() {
            let attachment = BlockAttachment()
            attachment.block = block
            attachment.rowID = picture.rowID
            attachment.image = picture.image
            attachment.bounds = CGRect(origin: .zero, size: picture.image.size)
            var attributes = lineAttributes
            attributes[.attachment] = attachment
            output.append(NSAttributedString(string: TextCharacters.attachment, attributes: attributes))
            if index < pictures.count - 1 {
                output.append(NSAttributedString(string: TextCharacters.lineBreak, attributes: lineAttributes))
            }
        }
        var markAttributes = lineAttributes
        markAttributes[.librettoBlock] = BlockBox(block)
        output.append(NSAttributedString(string: "\n", attributes: markAttributes))
        return output
    }

    // MARK: - Restyling

    /// Recomputes how the paragraphs touching `range` look from the model
    /// their attributes carry, after the model in them was changed.
    static func restyle(
        _ storage: NSMutableAttributedString, paragraphsIn range: NSRange, finalParagraph: Paragraph,
        context: RenderContext
    ) {
        let string = storage.string as NSString
        let covered = string.paragraphRange(for: NSRange(
            location: min(range.location, string.length), length: min(range.length, string.length - min(range.location, string.length))
        ))
        storage.beginEditing()
        var location = covered.location
        repeat {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            restyleParagraph(storage, range: paragraphRange, finalParagraph: finalParagraph, context: context)
            location = NSMaxRange(paragraphRange)
        } while location < NSMaxRange(covered)
        storage.endEditing()
    }

    /// The box of the paragraph a range of text belongs to: its mark's, or
    /// failing that, its first character's.
    static func paragraphBox(
        in storage: NSAttributedString, paragraphRange range: NSRange
    ) -> ParagraphBox? {
        guard range.length > 0 else { return nil }
        let last = NSMaxRange(range) - 1
        let string = storage.string as NSString
        if string.character(at: last) == TextCharacters.paragraphBreakUnit,
           let box = storage.attribute(.librettoParagraph, at: last, effectiveRange: nil) as? ParagraphBox {
            return box
        }
        return storage.attribute(.librettoParagraph, at: range.location, effectiveRange: nil) as? ParagraphBox
    }

    private static let displayKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .baselineOffset,
        .underlineColor, .strikethroughColor, .kern, .strokeWidth, .strokeColor, .shadow, .librettoAllCaps,
    ]

    private static func restyleParagraph(
        _ storage: NSMutableAttributedString, range: NSRange, finalParagraph: Paragraph, context: RenderContext
    ) {
        guard range.length > 0 else { return }
        if storage.attribute(.librettoBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) != nil { return }
        let paragraph = paragraphBox(in: storage, paragraphRange: range)?.paragraph ?? finalParagraph
        let label = storage.attribute(.librettoListLabel, at: range.location, effectiveRange: nil) as? ListLabelBox
        let style = Typography.paragraphStyle(paragraph.properties, context: context, isListItem: label != nil)
        storage.addAttribute(.paragraphStyle, value: style, range: range)
        storage.addAttribute(.librettoParagraph, value: ParagraphBox(paragraph), range: range)
        if let dropCap = context.styles.resolvedParagraphProperties(paragraph.properties).dropCap {
            storage.addAttribute(.librettoDropCap, value: DropCapBox(dropCap), range: range)
        } else {
            storage.removeAttribute(.librettoDropCap, range: range)
        }

        storage.enumerateAttribute(.librettoRun, in: range) { value, runRange, _ in
            if storage.attribute(.attachment, at: runRange.location, effectiveRange: nil) is BlockAttachment { return }
            let box = value as? RunBox
            for key in displayKeys { storage.removeAttribute(key, range: runRange) }
            storage.addAttributes(
                Typography.runAttributes(
                    box?.format.style ?? RunStyle(), paragraph: paragraph.properties,
                    hyperlink: box?.hyperlink, revision: box?.revision, context: context
                ),
                range: runRange
            )
        }
    }

    /// Renumbers every list paragraph, after paragraphs came or went or
    /// changed list.
    static func relabel(_ storage: NSMutableAttributedString, finalParagraph: Paragraph, context: RenderContext)
        -> [NSRange] {
        var labeler = ListLabeler(context: context)
        var changed: [NSRange] = []
        let string = storage.string as NSString
        var location = 0
        storage.beginEditing()
        while location < string.length || (location == string.length && location == 0) {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(range) }
            guard range.length > 0 else { break }
            if storage.attribute(.librettoBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) != nil { continue }
            let paragraph = paragraphBox(in: storage, paragraphRange: range)?.paragraph ?? finalParagraph
            let label = labeler.label(for: paragraph.properties)
            let existing = storage.attribute(.librettoListLabel, at: range.location, effectiveRange: nil) as? ListLabelBox
            guard existing != label else { continue }
            if let label {
                storage.addAttribute(.librettoListLabel, value: label, range: range)
            } else {
                storage.removeAttribute(.librettoListLabel, range: range)
            }
            if (existing == nil) != (label == nil) { changed.append(range) }
        }
        storage.endEditing()
        return changed
    }
}
