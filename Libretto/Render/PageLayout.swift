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
    func band(after index: Int) -> CGRect {
        CGRect(x: -1, y: CGFloat(index) * pitch + contentHeight, width: contentWidth + 2, height: pitch - contentHeight)
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
        container.exclusionPaths = (0..<pages).map { UIBezierPath(rect: geometry.band(after: $0)) }
    }

    /// Lays everything out, adding pages until the text fits, and returns
    /// how many it takes.
    @discardableResult
    func layOutPages(in container: NSTextContainer, startingWith estimate: Int) -> Int {
        var pages = max(1, estimate)
        if container.exclusionPaths.count != pages { configure(container, pages: pages) }
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
