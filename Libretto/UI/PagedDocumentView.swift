import UIKit

/// A zoomable column of pages, with the document's one text view laid over
/// them so its text falls on the pages' printable areas.
final class PagedDocumentView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// Space between pages, and around the column.
    static let pageGap: CGFloat = 20
    private static let inset: CGFloat = 16

    let scrollView = UIScrollView()
    private let canvas = UIView()
    private let textView: UITextView
    private var pageViews: [PageBackgroundView] = []

    private var geometry: PageGeometry?
    private var pages = 0
    private var texts = WordDocumentHeaderFooter()
    private var notes = PageNotes()
    /// Until the user pinches, the pages are kept fitted to the width.
    private var fitsWidth = true
    private var lastWidth: CGFloat = 0
    /// The pages run under the keyboard; they scroll clear of it.
    private lazy var keyboard = KeyboardOverlap(view: self)

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .automatic
        scrollView.maximumZoomScale = 4
        scrollView.accessibilityIdentifier = "pages"
        addSubview(scrollView)
        scrollView.addSubview(canvas)
        canvas.addSubview(textView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedMargin(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Pages

    func update(geometry: PageGeometry, pages: Int, texts: WordDocumentHeaderFooter, notes: PageNotes = PageNotes()) {
        let changed = geometry != self.geometry
        guard changed || pages != self.pages || texts != self.texts || notes != self.notes else { return }
        self.geometry = geometry
        self.pages = pages
        self.texts = texts
        self.notes = notes
        if changed { fitsWidth = true }

        while pageViews.count < pages {
            let page = PageBackgroundView()
            canvas.insertSubview(page, belowSubview: textView)
            pageViews.append(page)
        }
        while pageViews.count > pages {
            pageViews.removeLast().removeFromSuperview()
        }
        layoutCanvas()
    }

    private var unzoomedSize: CGSize {
        guard let geometry else { return .zero }
        return CGSize(
            width: geometry.widestPage + Self.inset * 2,
            height: geometry.totalHeight(pages: pages) + Self.inset * 2
        )
    }

    private func layoutCanvas() {
        guard let geometry else { return }
        let size = unzoomedSize
        let zoom = scrollView.zoomScale
        canvas.bounds = CGRect(origin: .zero, size: size)
        canvas.center = CGPoint(x: size.width * zoom / 2, y: size.height * zoom / 2)
        scrollView.contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)

        for (index, page) in pageViews.enumerated() {
            page.frame = geometry.pageFrame(index).offsetBy(dx: Self.inset, dy: Self.inset)
            page.configure(texts, page: index, of: pages, shape: geometry.shape(index))
            page.configureNotes(notes.byPage[index] ?? [], height: notes.heights[index] ?? 0, shape: geometry.shape(index))
        }
        textView.frame = CGRect(
            x: Self.inset + geometry.textLeft, y: Self.inset + geometry.margins.top,
            width: geometry.contentWidth, height: max(1, geometry.totalHeight(pages: pages) - geometry.margins.top)
        )
        updateZoomLimits()
        centerContent()
    }

    private func updateZoomLimits() {
        let width = unzoomedSize.width
        guard width > 0, bounds.width > 0 else { return }
        // Fitted, but never blown up past actual size on a wide screen.
        let fit = min(1, bounds.width / width)
        scrollView.minimumZoomScale = fit * 0.5
        if fitsWidth, abs(scrollView.zoomScale - fit) > 0.001 {
            scrollView.zoomScale = fit
        }
    }

    private func centerContent() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        if scrollView.contentInset.left != horizontal {
            scrollView.contentInset.left = horizontal
            scrollView.contentInset.right = horizontal
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            fitsWidth = true
            updateZoomLimits()
        }
        centerContent()
        let keyboardInset = keyboard.contentInset(for: scrollView)
        if scrollView.contentInset.bottom != keyboardInset {
            scrollView.contentInset.bottom = keyboardInset
            scrollView.verticalScrollIndicatorInsets.bottom = keyboardInset
        }
    }

    // MARK: - Scrolling

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        fitsWidth = false
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    /// Brings a rect of the text view into view, above the keyboard.
    func scrollToVisible(_ rect: CGRect) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return }
        let target = textView.convert(rect, to: scrollView).insetBy(dx: -8, dy: -32)
        // Measured against what the insets leave showing, the keyboard's among them.
        let insets = scrollView.adjustedContentInset
        let visible = scrollView.bounds.inset(by: insets)
        var offset = scrollView.contentOffset
        if target.maxX > visible.maxX { offset.x += target.maxX - visible.maxX }
        if target.minX < visible.minX { offset.x -= visible.minX - target.minX }
        if target.maxY > visible.maxY { offset.y += target.maxY - visible.maxY }
        if target.minY < visible.minY { offset.y -= visible.minY - target.minY }
        let size = scrollView.contentSize
        offset.x = min(max(offset.x, -insets.left), max(-insets.left, size.width + insets.right - scrollView.bounds.width))
        offset.y = min(max(offset.y, -insets.top), max(-insets.top, size.height + insets.bottom - scrollView.bounds.height))
        scrollView.contentOffset = offset
    }

    /// A tap in a page's margin puts the caret on the nearest text.
    @objc private func tappedMargin(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: textView)
        let clamped = CGPoint(
            x: min(max(point.x, 0), textView.bounds.width), y: min(max(point.y, 0), textView.bounds.height)
        )
        guard let position = textView.closestPosition(to: clamped) else { return }
        textView.selectedTextRange = textView.textRange(from: position, to: position)
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        return !view.isDescendant(of: textView)
    }
}

/// The headers and footers, as the page backgrounds need them: which each
/// page shows, and where.
///
/// Each section shows its own, and carries on the section before's for any
/// kind it has none of, as Word does; its first page is the section's first.
struct WordDocumentHeaderFooter: Equatable {
    struct Section: Equatable {
        var headers: [HeaderFooterKind: HeaderFooterText] = [:]
        var footers: [HeaderFooterKind: HeaderFooterText] = [:]
        var titlePage = false
        /// Points from the page's top and bottom edges.
        var headerDistance: CGFloat = 35
        var footerDistance: CGFloat = 35
    }

    var sections: [Section] = [Section()]
    /// Which section each page is in, as laid out; pages past the end are in the last.
    var pageSections: [Int] = []
    var evenAndOdd = false

    init() {}

    init(document: WordDocument, sections setups: [PageSetup]? = nil, pageSections: [Int] = []) {
        var headers: [HeaderFooterKind: HeaderFooterText] = [:]
        var footers: [HeaderFooterKind: HeaderFooterText] = [:]
        sections = (setups ?? [document.pageSetup]).map { setup in
            for kind in HeaderFooterKind.allCases {
                if let id = setup.headerFooters.headers[kind] { headers[kind] = document.headerFooters[id] }
                if let id = setup.headerFooters.footers[kind] { footers[kind] = document.headerFooters[id] }
            }
            return Section(
                headers: headers, footers: footers, titlePage: setup.headerFooters.titlePage,
                headerDistance: CGFloat(setup.headerDistance) / 20, footerDistance: CGFloat(setup.footerDistance) / 20
            )
        }
        if sections.isEmpty { sections = [Section()] }
        self.pageSections = pageSections
        evenAndOdd = document.evenAndOddHeaders
    }

    func section(forPage index: Int) -> Section {
        let section = index < pageSections.count ? pageSections[index] : sections.count - 1
        return sections[min(max(0, section), sections.count - 1)]
    }

    private func kind(forPage index: Int) -> HeaderFooterKind {
        let section = index < pageSections.count ? pageSections[index] : sections.count - 1
        let isFirst = index == 0 || (index < pageSections.count && pageSections[index - 1] != section)
        if isFirst, self.section(forPage: index).titlePage { return .first }
        if evenAndOdd, index % 2 == 1 { return .even }
        return .default
    }

    /// What page `index` shows, if anything: an empty header shows nothing.
    func header(forPage index: Int) -> HeaderFooterText? {
        section(forPage: index).headers[kind(forPage: index)].flatMap { $0.text.trimmed.isEmpty ? nil : $0 }
    }

    func footer(forPage index: Int) -> HeaderFooterText? {
        section(forPage: index).footers[kind(forPage: index)].flatMap { $0.text.trimmed.isEmpty ? nil : $0 }
    }
}

/// The notes each page sets at its foot, and the room they take.
struct PageNotes: Equatable {
    var byPage: [Int: [NSAttributedString]] = [:]
    var heights: [Int: CGFloat] = [:]
}

/// A page's footnotes, under a short rule.
private final class NotesView: UIView {
    var notes: [NSAttributedString] = [] {
        didSet { if notes != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ rect: CGRect) {
        PageLayoutManager.drawNotes(notes, in: bounds, color: .label)
    }
}

final class PageBackgroundView: UIView {
    private let headerLabel = UILabel()
    private let footerLabel = UILabel()
    private let notesView = NotesView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        for label in [headerLabel, footerLabel] {
            label.font = HeaderFooterDrawing.font
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            addSubview(label)
        }
        addSubview(notesView)
    }

    func configureNotes(_ notes: [NSAttributedString], height: CGFloat, shape: PageGeometry.Shape) {
        notesView.isHidden = notes.isEmpty
        notesView.notes = notes
        notesView.frame = CGRect(
            x: shape.margins.left, y: shape.margins.top + shape.contentHeight - height,
            width: shape.contentWidth, height: height
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(_ texts: WordDocumentHeaderFooter, page: Int, of count: Int, shape: PageGeometry.Shape) {
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        let section = texts.section(forPage: page)
        for (label, text, isFooter) in [(headerLabel, texts.header(forPage: page), false),
                                        (footerLabel, texts.footer(forPage: page), true)] {
            guard let text else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.attributedText = HeaderFooterDrawing.attributed(text, page: page, of: count, color: .secondaryLabel)
            let width = shape.contentWidth
            let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let height = min(size.height, isFooter ? shape.margins.bottom : shape.margins.top)
            // Word measures the header down from the top edge, the footer up from the bottom.
            let y = isFooter
                ? bounds.height - section.footerDistance - height
                : section.headerDistance
            label.frame = CGRect(x: shape.margins.left, y: y, width: width, height: height)
        }
    }
}
