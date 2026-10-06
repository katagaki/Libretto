import SwiftUI

/// Mobile view: the document reflowed to the width of the screen, for reading.
///
/// Page size, margins and fixed indents are let go of; text is set at the
/// reader's Dynamic Type size with headings kept in proportion, pictures fit
/// the width, and wide tables scroll sideways rather than shrinking.
struct MobileReaderView: View {
    var document: WordDocument
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = MobileLayout(document: document, scheme: colorScheme)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(layout.items) { item in
                    MobileItemView(item: item)
                }
                Text(String(format: String(localized: "Mobile.WordCount"), document.wordCount))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                    .accessibilityIdentifier("wordCount")
            }
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 96)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("mobileReader")
        // Text sizes are worked out from the Dynamic Type size.
        .id(dynamicTypeSize)
    }
}

// MARK: - Layout

struct MobileItem: Identifiable {
    let id: String
    let content: Content

    enum Content {
        case paragraph(MobileParagraph)
        case spacer
        case image(UIImage, width: CGFloat)
        case table(MobileTable)
        case preserved(String)
    }
}

struct MobileParagraph {
    var text: AttributedString
    var label: AttributedString?
    var alignment: TextAlignment
    var indent: CGFloat
    var spacingBefore: CGFloat
    var spacingAfter: CGFloat
    var lineSpacing: CGFloat
    var isHeading: Bool
}

struct MobileTable {
    var rows: [[AttributedString]]
    var columnCount: Int
    var hasBorders: Bool
}

/// Works out what the reader shows, block by block.
struct MobileLayout {
    let items: [MobileItem]

    init(document: WordDocument, scheme: ColorScheme) {
        let context = RenderContext(document: document, scheme: scheme, images: ImageStore())
        let body = UIFont.preferredFont(forTextStyle: .body).pointSize
        let documentBody = CGFloat(document.styles.resolvedRunStyle(RunStyle(), paragraphStyleID: nil).fontSize ?? 22) / 2
        let builder = MobileTextBuilder(context: context, readerSize: body, documentSize: max(documentBody, 6))
        var labeler = ListLabeler(context: context)
        var items: [MobileItem] = []
        var lastWasSpacer = true

        for (index, block) in document.body.enumerated() {
            let id = "\(index)-\(block.id)"
            switch block {
            case .paragraph(let paragraph):
                let label = labeler.label(for: paragraph.properties)
                // Pictures stand on their own, at the width of the screen.
                for (offset, inline) in paragraph.inlines.enumerated() {
                    if case .image(let image) = inline.content,
                       let picture = context.images.image(forRelationship: image.relationshipID, in: document.package) {
                        items.append(MobileItem(id: "\(id)-image-\(offset)", content: .image(picture, width: image.width)))
                        lastWasSpacer = false
                    }
                }
                let built = builder.paragraph(paragraph, label: label)
                if built.text.characters.allSatisfy(\.isWhitespace), built.label == nil {
                    // Empty paragraphs are how documents make space; one is enough.
                    if !lastWasSpacer { items.append(MobileItem(id: id, content: .spacer)) }
                    lastWasSpacer = true
                } else {
                    items.append(MobileItem(id: id, content: .paragraph(built)))
                    lastWasSpacer = false
                }
            case .table(let table):
                let rows = table.rows.map { row in
                    row.cells.map { cell in
                        cell.verticalMerge == .continue ? AttributedString() : builder.cell(cell)
                    }
                }
                items.append(MobileItem(id: id, content: .table(MobileTable(
                    rows: rows, columnCount: rows.map(\.count).max() ?? 0, hasBorders: table.hasBorders
                ))))
                lastWasSpacer = false
            case .preserved(let preserved):
                if !preserved.displayText.trimmed.isEmpty {
                    items.append(MobileItem(id: id, content: .preserved(preserved.displayText)))
                    lastWasSpacer = false
                }
            }
        }
        self.items = items
    }
}

/// Builds reader text from paragraphs, at reader sizes.
struct MobileTextBuilder {
    let context: RenderContext
    let readerSize: CGFloat
    let documentSize: CGFloat

    /// Headings grow less than they do on paper, so a title still fits a phone.
    private func scale(forPointSize size: CGFloat) -> CGFloat {
        let target = readerSize * pow(size / documentSize, 0.6)
        return target / max(size, 1)
    }

    func paragraph(_ paragraph: Paragraph, label: ListLabelBox?) -> MobileParagraph {
        let resolved = context.styles.resolvedParagraphProperties(paragraph.properties)
        let indents = Typography.indents(direct: paragraph.properties, resolved: resolved, context: context)
        let text = attributed(paragraph)
        var labelText: AttributedString?
        if let label, !label.text.isEmpty {
            let first = paragraph.inlines.first { if case .text = $0.content { return true } else { return false } }
            labelText = runText(label.text, format: first?.format ?? RunFormat(), paragraph: paragraph)
        }
        let alignment: TextAlignment
        switch resolved.alignment ?? .leading {
        case .center: alignment = .center
        case .trailing: alignment = .trailing
        default: alignment = .leading
        }
        let isHeading = context.styles.headingLevel(ofStyle: paragraph.properties.styleID) != nil
            || context.styles.choice(forStyle: paragraph.properties.styleID) == .title
        let multiple = resolved.lineSpacing?.multiple ?? 1
        return MobileParagraph(
            text: text, label: labelText, alignment: alignment,
            indent: min(32, max(0, indents.left - (label == nil ? 0 : 18)) / 2),
            spacingBefore: min(24, CGFloat(resolved.spacingBefore ?? 0) / 20 * 0.8),
            spacingAfter: min(18, max(6, CGFloat(resolved.spacingAfter ?? 0) / 20 * 0.8)),
            lineSpacing: max(0, (multiple - 1) * readerSize * 0.6 + 2),
            isHeading: isHeading
        )
    }

    func cell(_ cell: TableCell) -> AttributedString {
        var result = AttributedString()
        for (index, paragraph) in cell.blocks.flatMap(\.paragraphs).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += attributed(paragraph)
        }
        return result
    }

    private func attributed(_ paragraph: Paragraph) -> AttributedString {
        var result = AttributedString()
        for inline in paragraph.inlines {
            let string: String
            switch inline.content {
            case .text(let text): string = text
            case .tab: string = "  "
            case .lineBreak: string = "\n"
            case .pageBreak, .image: continue
            case .runChild(_, let display), .paragraphChild(_, let display):
                guard let display, !display.isEmpty else { continue }
                string = display
            }
            var piece = runText(string, format: inline.format, paragraph: paragraph)
            if let url = inline.hyperlink?.url { piece.link = url }
            result += piece
        }
        return result
    }

    private func runText(_ string: String, format: RunFormat, paragraph: Paragraph) -> AttributedString {
        let resolved = context.styles.resolvedRunStyle(
            format.style, paragraphStyleID: paragraph.properties.styleID ?? context.styles.defaultParagraphStyleID
        )
        let size = CGFloat(resolved.fontSize ?? 22) / 2
        let attributes = Typography.runAttributes(
            format.style, paragraph: paragraph.properties, hyperlink: nil, context: context,
            fontScale: scale(forPointSize: size)
        )
        var piece = AttributedString(resolved.allCaps == true ? string.uppercased() : string)
        if let font = attributes[.font] as? UIFont { piece.font = Font(font) }
        if let color = attributes[.foregroundColor] as? UIColor { piece.foregroundColor = Color(uiColor: color) }
        if let background = attributes[.backgroundColor] as? UIColor { piece.backgroundColor = Color(uiColor: background) }
        if attributes[.underlineStyle] != nil { piece.underlineStyle = .single }
        if attributes[.strikethroughStyle] != nil { piece.strikethroughStyle = .single }
        if let offset = attributes[.baselineOffset] as? CGFloat { piece.baselineOffset = offset }
        return piece
    }
}

// MARK: - Views

private struct MobileItemView: View {
    let item: MobileItem

    var body: some View {
        switch item.content {
        case .paragraph(let paragraph):
            MobileParagraphView(paragraph: paragraph)
        case .spacer:
            Spacer().frame(height: 10)
        case .image(let image, let width):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: width)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityLabel("Mobile.Picture")
        case .table(let table):
            MobileTableView(table: table)
                .padding(.vertical, 8)
        case .preserved(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 2)
                }
                .padding(.vertical, 8)
        }
    }
}

private struct MobileParagraphView: View {
    let paragraph: MobileParagraph

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let label = paragraph.label {
                Text(label)
                    .frame(minWidth: 16, alignment: .trailing)
            }
            Text(paragraph.text)
                .lineSpacing(paragraph.lineSpacing)
                .multilineTextAlignment(paragraph.alignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, paragraph.indent)
        .padding(.top, paragraph.spacingBefore)
        .padding(.bottom, paragraph.spacingAfter)
        .accessibilityAddTraits(paragraph.isHeading ? .isHeader : [])
    }

    private var frameAlignment: Alignment {
        switch paragraph.alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }
}

private struct MobileTableView: View {
    let table: MobileTable
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// A few columns fit the screen; more scroll sideways at a readable width.
    private var scrolls: Bool { table.columnCount > (horizontalSizeClass == .compact ? 3 : 5) }

    var body: some View {
        if scrolls {
            ScrollView(.horizontal) {
                grid(columnWidth: 150)
            }
            .scrollIndicators(.visible)
        } else {
            grid(columnWidth: nil)
        }
    }

    private func grid(columnWidth: CGFloat?) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        let text = column < table.rows[row].count ? table.rows[row][column] : AttributedString()
                        Text(text)
                            .font(.subheadline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(width: columnWidth, alignment: .topLeading)
                            .frame(maxWidth: columnWidth == nil ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
                            .border(Color.secondary.opacity(table.hasBorders ? 0.5 : 0.2), width: 0.5)
                    }
                }
            }
        }
    }
}
