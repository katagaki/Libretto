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
    private var header: HeaderFooterText?
    private var footer: HeaderFooterText?
    private var headerDistance: CGFloat = 35
    private var footerDistance: CGFloat = 35
    /// Until the user pinches, the pages are kept fitted to the width.
    private var fitsWidth = true
    private var lastWidth: CGFloat = 0

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

    func update(geometry: PageGeometry, pages: Int, setup: PageSetup, header: HeaderFooterText?, footer: HeaderFooterText?) {
        let changed = geometry != self.geometry
        let headerDistance = CGFloat(setup.headerDistance) / 20
        let footerDistance = CGFloat(setup.footerDistance) / 20
        guard changed || pages != self.pages || header != self.header || footer != self.footer
                || headerDistance != self.headerDistance || footerDistance != self.footerDistance else { return }
        self.geometry = geometry
        self.pages = pages
        self.header = header
        self.footer = footer
        self.headerDistance = headerDistance
        self.footerDistance = footerDistance
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
            width: geometry.pageSize.width + Self.inset * 2,
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

        let document = WordDocumentHeaderFooter(
            header: header, footer: footer, headerDistance: headerDistance, footerDistance: footerDistance
        )
        for (index, page) in pageViews.enumerated() {
            page.frame = geometry.pageFrame(index).offsetBy(dx: Self.inset, dy: Self.inset)
            page.configure(document, page: index, of: pages, geometry: geometry)
        }
        textView.frame = CGRect(
            x: Self.inset + geometry.margins.left, y: Self.inset + geometry.margins.top,
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
        scrollView.scrollRectToVisible(target, animated: false)
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

/// The header and footer, as the page backgrounds need them.
struct WordDocumentHeaderFooter {
    var header: HeaderFooterText?
    var footer: HeaderFooterText?
    /// Points from the page's top and bottom edges.
    var headerDistance: CGFloat
    var footerDistance: CGFloat
}

/// One sheet of paper, with its header and footer drawn in the margins.
final class PageBackgroundView: UIView {
    private let headerLabel = UILabel()
    private let footerLabel = UILabel()

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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(_ texts: WordDocumentHeaderFooter, page: Int, of count: Int, geometry: PageGeometry) {
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        for (label, text, isFooter) in [(headerLabel, texts.header, false), (footerLabel, texts.footer, true)] {
            guard let text else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.attributedText = HeaderFooterDrawing.attributed(text, page: page, of: count, color: .secondaryLabel)
            let width = geometry.contentWidth
            let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let height = min(size.height, isFooter ? geometry.margins.bottom : geometry.margins.top)
            // Word measures the header down from the top edge, the footer up from the bottom.
            let y = isFooter
                ? bounds.height - texts.footerDistance - height
                : texts.headerDistance
            label.frame = CGRect(x: geometry.margins.left, y: y, width: width, height: height)
        }
    }
}
