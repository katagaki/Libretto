import SwiftUI
import UIKit

/// Where the pages are, in the text container's coordinates.
///
/// The whole document is set in one tall text container, one page's text
/// width wide. Page `n`'s text occupies `n × pitch` to `n × pitch +
/// contentHeight`; the band between one page's text and the next — bottom
/// margin, the gap between pages, top margin — is excluded from the
/// container, so lines skip it and the text breaks into pages by itself,
/// while staying one text that edits, selects and scrolls as one.
struct PageGeometry: Equatable {
    var pageSize: CGSize
    var margins: UIEdgeInsets
    /// Space between pages on screen; none in a PDF.
    var gap: CGFloat

    init(setup: PageSetup, gap: CGFloat) {
        pageSize = setup.size
        margins = UIEdgeInsets(
            top: CGFloat(setup.marginTop) / 20, left: CGFloat(setup.marginLeft) / 20,
            bottom: CGFloat(setup.marginBottom) / 20, right: CGFloat(setup.marginRight) / 20
        )
        // Margins so wide there is no page left would leave nowhere for text.
        let minimum: CGFloat = 72
        if pageSize.width - margins.left - margins.right < minimum {
            margins.left = (pageSize.width - minimum) / 2
            margins.right = margins.left
        }
        if pageSize.height - margins.top - margins.bottom < minimum {
            margins.top = (pageSize.height - minimum) / 2
            margins.bottom = margins.top
        }
        self.gap = gap
    }

    var contentWidth: CGFloat { pageSize.width - margins.left - margins.right }
    var contentHeight: CGFloat { pageSize.height - margins.top - margins.bottom }
    /// From one page's top to the next, on screen and in the container alike.
    var pitch: CGFloat { pageSize.height + gap }

    /// The band between page `index`'s text and the next page's.
    func band(after index: Int, reserving reserve: CGFloat = 0) -> CGRect {
        CGRect(
            x: -1, y: CGFloat(index) * pitch + contentHeight - reserve, width: contentWidth + 2,
            height: pitch - contentHeight + reserve
        )
    }

    func page(containing y: CGFloat) -> Int {
        max(0, Int(floor(y / pitch)))
    }

    /// The pages text that ends at `height` in the container needs.
    func pageCount(forUsedHeight height: CGFloat) -> Int {
        max(1, page(containing: max(0, height - 0.5)) + 1)
    }

    /// Where page `index` sits in a column of pages.
    func pageFrame(_ index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * pitch, width: pageSize.width, height: pageSize.height)
    }

    func totalHeight(pages: Int) -> CGFloat {
        CGFloat(pages) * pitch - gap
    }
}

/// Lays text out in pages: page breaks end the page, and list labels are
/// drawn in the indent.
final class PageLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var geometry: PageGeometry
    var styles = StyleSheet()
    /// The appearance borders and shading are drawn for.
    var scheme: ColorScheme = .light
    /// The text comments are on, shaded behind it; the comment at the
    /// selection more strongly than the rest.
    var commentRanges: [NSRange] = []
    var activeCommentRanges: [NSRange] = []

    init(geometry: PageGeometry) {
        self.geometry = geometry
        super.init()
        delegate = self
        allowsNonContiguousLayout = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Sets the container up for `pages` pages of text.
    func configure(_ container: NSTextContainer, pages: Int) {
        container.size = CGSize(width: geometry.contentWidth, height: geometry.totalHeight(pages: pages + 1))
        container.lineFragmentPadding = 0
        container.exclusionPaths = (0..<pages).map {
            UIBezierPath(rect: geometry.band(after: $0, reserving: noteHeights[$0] ?? 0))
        } + dropCapExclusions.map { UIBezierPath(rect: $0) }
    }

    // MARK: - Footnotes

    /// Notes to set at the foot of the page their reference falls on: where
    /// the reference is in the text, and the note as it is drawn.
    var footnotes: [(location: Int, text: NSAttributedString)] = []
    /// What each page keeps clear at its foot for its notes, and the notes.
    private(set) var noteHeights: [Int: CGFloat] = [:]
    private(set) var notesByPage: [Int: [NSAttributedString]] = [:]

    /// Space between the text and a page's notes, where the separator is drawn.
    static let noteSeparatorSpace: CGFloat = 12

    /// Lays everything out, adding pages until the text fits, and making
    /// room at the foot of each page for the notes referred to on it.
    /// Returns how many pages it takes.
    ///
    /// Room made for notes can push a reference on to the next page, so the
    /// notes are placed again until they settle, a few times at most.
    @discardableResult
    func layOutPages(in container: NSTextContainer, startingWith estimate: Int) -> Int {
        var pages = layOutText(in: container, startingWith: estimate)
        // Drop caps are placed the same way: where the paragraph they start falls decides where they go.
        for _ in 0..<4 {
            let placed = footnotes.isEmpty && noteHeights.isEmpty ? (byPage: [:], heights: [:]) : placeNotes()
            let caps = placeDropCaps()
            notesByPage = placed.byPage
            dropCaps = caps
            let exclusions = caps.compactMap(\.exclusion)
            guard placed.heights != noteHeights || exclusions != dropCapExclusions else { break }
            noteHeights = placed.heights
            dropCapExclusions = exclusions
            configure(container, pages: pages)
            pages = layOutText(in: container, startingWith: pages)
        }
        return pages
    }

    // MARK: - Drop caps

    struct PlacedDropCap {
        /// The drop cap's paragraph, which takes no room of its own.
        var paragraph: NSRange
        var letter: NSAttributedString
        /// Where the letter's top left corner goes, in the container.
        var origin: CGPoint
        /// What the next paragraph's lines go around, unless the letter is in the margin.
        var exclusion: CGRect?
    }

    private(set) var dropCaps: [PlacedDropCap] = []
    private var dropCapExclusions: [CGRect] = []

    private func placeDropCaps() -> [PlacedDropCap] {
        guard let storage = textStorage else { return [] }
        let string = storage.string as NSString
        var result: [PlacedDropCap] = []
        storage.enumerateAttribute(.librettoDropCap, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let box = value as? DropCapBox else { return }
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            let next = NSMaxRange(paragraph)
            let text = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
            guard !text.isEmpty, next < string.length else { return }
            let glyph = glyphIndexForCharacter(at: next)
            guard glyph < numberOfGlyphs else { return }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let font = storage.attribute(.font, at: next, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 11)
            let style = storage.attribute(.paragraphStyle, at: next, effectiveRange: nil) as? NSParagraphStyle
            let lineHeight = font.lineHeight * max(1, style?.lineHeightMultiple ?? 1)
            let top = line.minY + (style?.paragraphSpacingBefore ?? 0)
            let lines = CGFloat(max(1, box.dropCap.lines))
            // As tall, cap to baseline, as the lines it drops into.
            let capFont = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? UIFont ?? font
            let capHeight = (lines - 1) * lineHeight + font.capHeight
            let size = capHeight / max(capFont.capHeight / capFont.pointSize, 0.1)
            let letterFont = capFont.withSize(size)
            let color = storage.attribute(.foregroundColor, at: paragraph.location, effectiveRange: nil) ?? UIColor.label
            let letter = NSAttributedString(string: text, attributes: [.font: letterFont, .foregroundColor: color])
            let width = ceil(letter.size().width)
            let baseline = top + (lines - 1) * lineHeight + font.ascender
            let gap: CGFloat = 4
            let x = box.dropCap.inMargin ? -(width + gap) : 0
            result.append(PlacedDropCap(
                paragraph: paragraph, letter: letter, origin: CGPoint(x: x, y: baseline - letterFont.ascender),
                exclusion: box.dropCap.inMargin ? nil
                    : CGRect(x: -1, y: top, width: width + gap + 1, height: lines * lineHeight - 1)
            ))
        }
        return result
    }

    private func placeNotes() -> (byPage: [Int: [NSAttributedString]], heights: [Int: CGFloat]) {
        guard let storage = textStorage else { return ([:], [:]) }
        var byPage: [Int: [NSAttributedString]] = [:]
        for note in footnotes where note.location < storage.length {
            let glyph = glyphIndexForCharacter(at: note.location)
            guard glyph < numberOfGlyphs else { continue }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            byPage[geometry.page(containing: line.midY), default: []].append(note.text)
        }
        let heights = byPage.mapValues { texts in
            let height = texts.reduce(Self.noteSeparatorSpace) { total, text in
                total + ceil(text.boundingRect(
                    with: CGSize(width: geometry.contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                ).height) + 2
            }
            // Never so much that the page has no room left for its own text.
            return min(height, geometry.contentHeight * 0.6)
        }
        return (byPage, heights)
    }

    /// Draws a page's notes at its foot, under a short rule.
    static func drawNotes(_ notes: [NSAttributedString], in frame: CGRect, color: UIColor) {
        guard !notes.isEmpty else { return }
        color.withAlphaComponent(0.5).setFill()
        UIRectFill(CGRect(x: frame.minX, y: frame.minY + noteSeparatorSpace / 2 - 0.25, width: min(144, frame.width / 3), height: 0.5))
        var y = frame.minY + noteSeparatorSpace
        for text in notes {
            let rect = CGRect(x: frame.minX, y: y, width: frame.width, height: frame.maxY - y)
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
            y += ceil(text.boundingRect(
                with: CGSize(width: frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            ).height) + 2
            if y >= frame.maxY { break }
        }
    }

    /// The text, laid out on as many pages as it takes.
    private func layOutText(in container: NSTextContainer, startingWith estimate: Int) -> Int {
        var pages = max(1, estimate)
        if container.exclusionPaths.count != pages { configure(container, pages: pages) }
        ensureLayout(for: container)
        if NSMaxRange(glyphRange(for: container)) < numberOfGlyphs {
            // Adding a few pages at a time lays everything out again each
            // time; measuring the text once without pages, then laying it out
            // on roughly as many pages as that needs, is far quicker.
            container.exclusionPaths = []
            container.size = CGSize(width: geometry.contentWidth, height: 10_000_000)
            ensureLayout(for: container)
            let unpaged = usedRect(for: container).maxY
            pages = max(pages + 1, Int(ceil(unpaged / geometry.contentHeight * 1.1)) + 1)
            configure(container, pages: pages)
        }
        var reached = -1
        for _ in 0..<64 {
            ensureLayout(for: container)
            let used = usedRect(for: container).maxY
            let needed = geometry.pageCount(forUsedHeight: used)
            let laidOut = NSMaxRange(glyphRange(for: container))
            if laidOut >= numberOfGlyphs, needed <= pages { return needed }
            // A line taller than a page fits on none, and layout stops at it:
            // more pages only lay the same text out again.
            if laidOut >= numberOfGlyphs || laidOut == reached { return max(needed, 1) }
            reached = laidOut
            pages = max(needed, pages) + max(4, pages / 4)
            configure(container, pages: pages)
        }
        return pages
    }

    // MARK: - Capitals

    /// Text in capitals keeps its letters as typed; it is drawn with the
    /// glyphs of their capitals.
    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
        font: UIFont, forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let first = characterIndexes[0]
        let last = characterIndexes[glyphRange.length - 1]
        guard first < storage.length else { return 0 }
        var hasCaps = false
        storage.enumerateAttribute(
            .librettoAllCaps, in: NSRange(location: first, length: min(storage.length, last + 1) - first)
        ) { value, _, stop in
            if value != nil {
                hasCaps = true
                stop.pointee = true
            }
        }
        guard hasCaps else { return 0 }
        let string = storage.string as NSString
        var replaced = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var changed = false
        for offset in 0..<glyphRange.length {
            let index = characterIndexes[offset]
            guard index < storage.length, storage.attribute(.librettoAllCaps, at: index, effectiveRange: nil) != nil,
                  let scalar = UnicodeScalar(string.character(at: index)),
                  CharacterSet.lowercaseLetters.contains(scalar) else { continue }
            let upper = Array(String(Character(scalar)).uppercased().utf16)
            guard upper.count == 1 else { continue }
            var unit = upper[0]
            var glyph = CGGlyph()
            if CTFontGetGlyphsForCharacters(font as CTFont, &unit, &glyph, 1) {
                replaced[offset] = glyph
                changed = true
            }
        }
        guard changed else { return 0 }
        replaced.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(
                buffer.baseAddress!, properties: properties, characterIndexes: characterIndexes, font: font,
                forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    // MARK: - Page breaks

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, charIndex < storage.length else { return action }
        let string = storage.string as NSString
        guard string.character(at: charIndex) == TextCharacters.pageBreakUnit else { return action }
        // A break that ends its paragraph keeps the paragraph's mark beside
        // it, as Word does, so the next paragraph is the one to start the page.
        let endsParagraph = charIndex + 1 < string.length
            && string.character(at: charIndex + 1) == TextCharacters.paragraphBreakUnit
        return endsParagraph ? .zeroAdvancement : .lineBreak
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = textStorage else { return false }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard characters.length > 0 else { return false }
        if storage.attribute(.librettoDropCap, at: characters.location, effectiveRange: nil) != nil {
            // A drop cap's line takes no room: its letter sits beside the next paragraph.
            var rect = lineFragmentRect.pointee
            rect.size.height = 0.01
            lineFragmentRect.pointee = rect
            lineFragmentUsedRect.pointee = CGRect(origin: rect.origin, size: CGSize(width: 0, height: 0.01))
            baselineOffset.pointee = 0
            return true
        }
        let string = storage.string as NSString
        let last = NSMaxRange(characters) - 1
        var endsPage = string.character(at: last) == TextCharacters.pageBreakUnit
            || (last > 0 && string.character(at: last) == TextCharacters.paragraphBreakUnit
                && string.character(at: last - 1) == TextCharacters.pageBreakUnit)
        if !endsPage, string.character(at: last) == TextCharacters.paragraphBreakUnit, last + 1 < string.length,
           storage.attribute(.librettoBlock, at: last + 1, effectiveRange: nil) == nil,
           let box = storage.attribute(.librettoParagraph, at: last + 1, effectiveRange: nil) as? ParagraphBox {
            let next = styles.resolvedParagraphProperties(box.paragraph.properties)
            if next.pageBreakBefore == true {
                endsPage = true
            } else {
                // What the next paragraph keeps together, if it would not fit on what is left of the page.
                let rect = lineFragmentRect.pointee
                let page = geometry.page(containing: rect.minY + 0.5)
                let bottom = CGFloat(page) * geometry.pitch + geometry.contentHeight - (noteHeights[page] ?? 0)
                let left = bottom - rect.maxY
                if left > 0, let needed = keptHeight(startingAt: last + 1, properties: next, available: left),
                   needed > left, needed < geometry.contentHeight * 0.9 {
                    endsPage = true
                }
            }
        }
        guard endsPage else { return false }
        var rect = lineFragmentRect.pointee
        let nextPageTop = CGFloat(geometry.page(containing: rect.minY + 0.5) + 1) * geometry.pitch
        guard nextPageTop > rect.maxY else { return false }
        rect.size.height = nextPageTop - rect.minY
        lineFragmentRect.pointee = rect
        return true
    }

    // MARK: - Keeping text together

    /// How much of the paragraph starting at `start` must go on one page:
    /// all of it, to keep its lines together or keep it with the next, with
    /// that one's first line; its first two lines, to leave no widow at the
    /// page's foot; or `nil` if it can break anywhere. Measured only when
    /// it might not fit in what is `available`.
    private func keptHeight(startingAt start: Int, properties: ParagraphProperties, available: CGFloat) -> CGFloat? {
        guard let storage = textStorage else { return nil }
        let keepsWhole = properties.keepLines == true || properties.keepNext == true
        guard keepsWhole || properties.widowControl == true else { return nil }
        let string = storage.string as NSString
        let range = string.paragraphRange(for: NSRange(location: start, length: 0))
        let font = storage.attribute(.font, at: start, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 11)
        let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
        let line = font.lineHeight * max(1, style?.lineHeightMultiple ?? 1)
        let before = style?.paragraphSpacingBefore ?? 0
        // Plenty of room for two lines and then some: nothing more to work out.
        if !keepsWhole, available > before + line * 2.5 { return nil }
        func height(of range: NSRange) -> CGFloat {
            ceil(storage.attributedSubstring(from: range).boundingRect(
                with: CGSize(width: geometry.contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            ).height)
        }
        let whole = height(of: range)
        var needed = keepsWhole ? whole : min(whole, before + line * 2)
        if properties.keepNext == true, NSMaxRange(range) < string.length {
            let following = storage.attribute(.font, at: NSMaxRange(range), effectiveRange: nil) as? UIFont ?? font
            needed += following.lineHeight
        }
        return needed
    }

    // MARK: - Borders and shading

    private struct Decoration {
        var properties: ParagraphProperties
        var paragraph: NSRange
        var page: Int
        var rect: CGRect
    }

    /// Paragraph shading, and borders, a box per page; paragraphs alike
    /// share a box, with the line between them if they have one.
    private func drawParagraphDecorations(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let string = storage.string as NSString
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var decorations: [Decoration] = []
        var location = string.paragraphRange(for: NSRange(location: min(shown.location, max(0, string.length - 1)), length: 0)).location
        // One paragraph beyond what is shown, so the last one shown knows whether its box carries on.
        var end = NSMaxRange(shown)
        if end < string.length { end = NSMaxRange(string.paragraphRange(for: NSRange(location: end, length: 0))) }
        while location < end, location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            guard storage.attribute(.librettoBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) == nil,
                  let box = DocumentRenderer.paragraphBox(in: storage, paragraphRange: range) else { continue }
            let properties = styles.resolvedParagraphProperties(box.paragraph.properties)
            guard properties.shadingHex != nil || properties.borders.map({ !$0.isEmpty }) == true else { continue }
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            var boxes: [Int: CGRect] = [:]
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) {
                rect, _, _, _, _ in
                let page = self.geometry.page(containing: rect.midY)
                boxes[page] = boxes[page].map { $0.union(rect) } ?? rect
            }
            let first = boxes.keys.min()
            let last = boxes.keys.max()
            for (page, var rect) in boxes {
                // The box holds the text, not the paragraph's spacing.
                if page == first { rect.origin.y += style?.paragraphSpacingBefore ?? 0; rect.size.height -= style?.paragraphSpacingBefore ?? 0 }
                if page == last { rect.size.height -= style?.paragraphSpacing ?? 0 }
                let left = min(style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0)
                rect.origin.x = left
                rect.size.width = container.size.width - left + (style?.tailIndent ?? 0)
                decorations.append(Decoration(properties: properties, paragraph: range, page: page, rect: rect))
            }
        }
        decorations.sort { ($0.paragraph.location, $0.page) < ($1.paragraph.location, $1.page) }

        let ink = scheme == .dark ? UIColor.white : UIColor.black
        for (index, decoration) in decorations.enumerated() {
            func joins(_ other: Decoration?) -> Bool {
                guard let other else { return false }
                return other.page == decoration.page && other.properties.borders == decoration.properties.borders
                    && other.properties.shadingHex == decoration.properties.shadingHex
                    && other.paragraph.location != decoration.paragraph.location
                    && (NSMaxRange(other.paragraph) == decoration.paragraph.location
                        || NSMaxRange(decoration.paragraph) == other.paragraph.location)
            }
            let joinsAbove = joins(index > 0 ? decorations[index - 1] : nil)
            let joinsBelow = joins(index + 1 < decorations.count ? decorations[index + 1] : nil)
            let borders = decoration.properties.borders ?? ParagraphBorders()
            var rect = decoration.rect
            // The border's own space around the text.
            let pad = { (line: BorderLine?) in CGFloat(line?.space ?? 0) }
            rect.origin.x -= pad(borders.left)
            rect.size.width += pad(borders.left) + pad(borders.right)
            if !joinsAbove { rect.origin.y -= pad(borders.top); rect.size.height += pad(borders.top) }
            if !joinsBelow { rect.size.height += pad(borders.bottom) }
            if joinsBelow, index + 1 < decorations.count {
                // Shading runs on into the next paragraph's box, with no gap.
                rect.size.height = max(rect.height, decorations[index + 1].rect.minY - rect.minY)
            }
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
            if let fill = decoration.properties.shadingHex.flatMap({ AdaptiveColor.uiColor(hex: $0, for: scheme, isText: false) }) {
                fill.setFill()
                UIRectFillUsingBlendMode(frame, .normal)
            }
            func stroke(_ line: BorderLine?, from start: CGPoint, to end: CGPoint) {
                guard let line else { return }
                let color = line.colorHex.flatMap { AdaptiveColor.uiColor(hex: $0, for: scheme, isText: true) } ?? ink
                Self.strokeBorder(line, from: start, to: end, color: color)
            }
            if !joinsAbove {
                stroke(borders.top, from: CGPoint(x: frame.minX, y: frame.minY), to: CGPoint(x: frame.maxX, y: frame.minY))
            } else {
                stroke(borders.between, from: CGPoint(x: frame.minX, y: frame.minY), to: CGPoint(x: frame.maxX, y: frame.minY))
            }
            if !joinsBelow {
                stroke(borders.bottom, from: CGPoint(x: frame.minX, y: frame.maxY), to: CGPoint(x: frame.maxX, y: frame.maxY))
            }
            stroke(borders.left, from: CGPoint(x: frame.minX, y: frame.minY), to: CGPoint(x: frame.minX, y: frame.maxY))
            stroke(borders.right, from: CGPoint(x: frame.maxX, y: frame.minY), to: CGPoint(x: frame.maxX, y: frame.maxY))
        }
    }

    /// One border line, in its style: single, double, dotted, dashed or thick.
    static func strokeBorder(_ line: BorderLine, from start: CGPoint, to end: CGPoint, color: UIColor) {
        let width = max(0.5, CGFloat(line.size) / 8)
        let path = UIBezierPath()
        path.lineWidth = width
        color.setStroke()
        switch line.style {
        case "dotted": path.setLineDash([width, width * 2], count: 2, phase: 0)
        case "dashed", "dashSmallGap", "dotDash", "dotDotDash": path.setLineDash([width * 4, width * 2], count: 2, phase: 0)
        default: break
        }
        if line.style == "double" || line.style.hasPrefix("thinThick") || line.style.hasPrefix("thickThin") {
            // Two lines, the gap between them as wide as each.
            let isHorizontal = abs(end.y - start.y) < abs(end.x - start.x)
            let shift = width
            for offset in [-shift, shift] {
                let delta = isHorizontal ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0)
                path.move(to: CGPoint(x: start.x + delta.x, y: start.y + delta.y))
                path.addLine(to: CGPoint(x: end.x + delta.x, y: end.y + delta.y))
            }
        } else {
            path.move(to: start)
            path.addLine(to: end)
        }
        path.stroke()
    }

    // MARK: - Comments

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawParagraphDecorations(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !commentRanges.isEmpty, let container = textContainers.first else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for range in commentRanges where range.length > 0 && NSIntersectionRange(range, shown).length > 0 {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let alpha: CGFloat = activeCommentRanges.contains(range) ? 0.5 : 0.25
            UIColor.systemYellow.withAlphaComponent(alpha).setFill()
            enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                UIRectFillUsingBlendMode(rect.offsetBy(dx: origin.x, dy: origin.y), .normal)
            }
        }
    }

    // MARK: - List labels

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if dropCaps.isEmpty {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        } else {
            // A drop cap's own line is not drawn; its letter is, large, beside the next paragraph.
            var remaining = [glyphsToShow]
            for cap in dropCaps {
                let hidden = glyphRange(forCharacterRange: cap.paragraph, actualCharacterRange: nil)
                remaining = remaining.flatMap { range -> [NSRange] in
                    guard NSIntersectionRange(range, hidden).length > 0 else { return [range] }
                    var pieces: [NSRange] = []
                    if hidden.location > range.location {
                        pieces.append(NSRange(location: range.location, length: hidden.location - range.location))
                    }
                    if NSMaxRange(range) > NSMaxRange(hidden) {
                        pieces.append(NSRange(location: NSMaxRange(hidden), length: NSMaxRange(range) - NSMaxRange(hidden)))
                    }
                    return pieces
                }
                let shown = NSRange(location: hidden.location, length: hidden.length + 1)
                if NSIntersectionRange(shown, glyphsToShow).length > 0 {
                    cap.letter.draw(at: CGPoint(x: origin.x + cap.origin.x, y: origin.y + cap.origin.y))
                }
            }
            for range in remaining where range.length > 0 { super.drawGlyphs(forGlyphRange: range, at: origin) }
        }
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let string = storage.string as NSString
        drawTabLeaders(in: characters, at: origin)
        storage.enumerateAttribute(.librettoListLabel, in: characters) { value, range, _ in
            guard let label = value as? ListLabelBox, !label.text.isEmpty else { return }
            // Only where a paragraph starts within what is being drawn.
            var location = range.location
            while location < NSMaxRange(range) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                if paragraph.location >= characters.location {
                    drawLabel(label, atParagraphStart: paragraph.location, origin: origin)
                }
                location = NSMaxRange(paragraph)
            }
        }
    }

    /// Dots, dashes or a rule across the space a tab with a leader takes.
    private func drawTabLeaders(in characters: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let string = storage.string as NSString
        var index = characters.location
        while index < NSMaxRange(characters) {
            let found = string.range(
                of: "\t", options: .literal, range: NSRange(location: index, length: NSMaxRange(characters) - index)
            )
            guard found.location != NSNotFound else { break }
            index = found.location + 1
            guard let box = storage.attribute(.librettoParagraph, at: found.location, effectiveRange: nil) as? ParagraphBox,
                  let stops = styles.resolvedParagraphProperties(box.paragraph.properties).tabStops,
                  stops.contains(where: { $0.leader != nil }) else { continue }
            let glyph = glyphIndexForCharacter(at: found.location)
            // From where the tab starts to where the next glyph does, on the same line.
            var lineGlyphs = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            // A tab is a control glyph, with no place of its own: it starts where the glyph before it ends.
            let start = glyph > lineGlyphs.location
                ? boundingRect(forGlyphRange: NSRange(location: glyph - 1, length: 1), in: container).maxX
                : fragment.minX
            let end = glyph + 1 < NSMaxRange(lineGlyphs)
                ? fragment.minX + location(forGlyphAt: glyph + 1).x
                : lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX
            let rect = CGRect(x: start, y: fragment.minY, width: end - start, height: fragment.height)
            guard rect.width > 6,
                  let leader = stops.first(where: { CGFloat($0.position) / 20 >= rect.maxX - 1 })?.leader else { continue }
            let mark: String
            switch leader {
            case "hyphen": mark = "-"
            case "underscore", "heavy": mark = "_"
            case "middleDot": mark = "·"
            default: mark = "."
            }
            let attributes = storage.attributes(at: found.location, effectiveRange: nil)
            let font = attributes[.font] as? UIFont ?? .systemFont(ofSize: 11)
            let drawn: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: attributes[.foregroundColor] ?? UIColor.label,
            ]
            // A mark and the space after it, as many as fit.
            let unit = ((mark + " ") as NSString).size(withAttributes: drawn).width
            let count = Int((rect.width - 4) / max(unit, 1))
            guard count > 0 else { continue }
            let leaderText = Array(repeating: mark, count: count).joined(separator: " ")
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = location(forGlyphAt: glyph).y
            let width = (leaderText as NSString).size(withAttributes: drawn).width
            (leaderText as NSString).draw(
                at: CGPoint(x: origin.x + rect.maxX - width - 2, y: origin.y + line.minY + baseline - font.ascender),
                withAttributes: drawn
            )
        }
    }

    private func drawLabel(_ label: ListLabelBox, atParagraphStart index: Int, origin: CGPoint) {
        guard let storage = textStorage, index < storage.length else { return }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = location(forGlyphAt: glyph).y
        var attributes = storage.attributes(at: index, effectiveRange: nil)
        let font = attributes[.font] as? UIFont ?? .systemFont(ofSize: 11)
        attributes = [.font: font, .foregroundColor: attributes[.foregroundColor] ?? UIColor.label]
        let point = CGPoint(
            x: origin.x + line.minX + label.indent,
            y: origin.y + line.minY + baseline - font.ascender
        )
        NSAttributedString(string: label.text, attributes: attributes).draw(at: point)
    }
}
