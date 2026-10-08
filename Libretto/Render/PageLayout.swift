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
        }
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
        guard !footnotes.isEmpty || !noteHeights.isEmpty else {
            notesByPage = [:]
            return pages
        }
        for _ in 0..<4 {
            let placed = placeNotes()
            notesByPage = placed.byPage
            guard placed.heights != noteHeights else { break }
            noteHeights = placed.heights
            configure(container, pages: pages)
            pages = layOutText(in: container, startingWith: pages)
        }
        return pages
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
        let string = storage.string as NSString
        let last = NSMaxRange(characters) - 1
        var endsPage = string.character(at: last) == TextCharacters.pageBreakUnit
            || (last > 0 && string.character(at: last) == TextCharacters.paragraphBreakUnit
                && string.character(at: last - 1) == TextCharacters.pageBreakUnit)
        if !endsPage, string.character(at: last) == TextCharacters.paragraphBreakUnit, last + 1 < string.length,
           let box = storage.attribute(.librettoParagraph, at: last + 1, effectiveRange: nil) as? ParagraphBox,
           styles.resolvedParagraphProperties(box.paragraph.properties).pageBreakBefore == true {
            endsPage = true
        }
        guard endsPage else { return false }
        var rect = lineFragmentRect.pointee
        let nextPageTop = CGFloat(geometry.page(containing: rect.minY + 0.5) + 1) * geometry.pitch
        guard nextPageTop > rect.maxY else { return false }
        rect.size.height = nextPageTop - rect.minY
        lineFragmentRect.pointee = rect
        return true
    }

    // MARK: - Comments

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
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
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let string = storage.string as NSString
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
