import SwiftUI
import UIKit

/// Prints a document to PDF, laid out in pages exactly as the page view shows it.
enum PDFExporter {
    static func data(from document: WordDocument) -> Data {
        let geometry = PageGeometry(setup: document.pageSetup, gap: 0)
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let rendered = DocumentRenderer.render(document.body, context: context)

        let storage = NSTextStorage(attributedString: rendered.string)
        let layoutManager = PageLayoutManager(geometry: geometry)
        layoutManager.styles = document.styles
        let container = NSTextContainer()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let pages = layoutManager.layOutPages(in: container, startingWith: 4)

        let bounds = CGRect(origin: .zero, size: geometry.pageSize)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { pdf in
            for page in 0..<pages {
                pdf.beginPage()
                let graphics = pdf.cgContext
                let contentTop = CGFloat(page) * geometry.pitch
                let visible = CGRect(x: 0, y: contentTop, width: geometry.contentWidth, height: geometry.contentHeight)
                let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
                let origin = CGPoint(x: geometry.margins.left, y: geometry.margins.top - contentTop)

                graphics.saveGState()
                graphics.clip(to: CGRect(
                    x: geometry.margins.left - 40, y: geometry.margins.top - 2,
                    width: geometry.contentWidth + 80, height: geometry.contentHeight + 4
                ))
                layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
                graphics.restoreGState()

                HeaderFooterDrawing.draw(
                    document: document, page: page, of: pages, geometry: geometry, color: .darkGray
                )
            }
        }
    }
}

/// The header and footer, drawn as plain text in the page's margins.
enum HeaderFooterDrawing {
    static let font = UIFont.systemFont(ofSize: 9)

    static func frames(document: WordDocument, geometry: PageGeometry) -> (header: CGRect, footer: CGRect) {
        let header = CGRect(
            x: geometry.margins.left, y: CGFloat(document.pageSetup.headerDistance) / 20,
            width: geometry.contentWidth, height: max(12, geometry.margins.top - CGFloat(document.pageSetup.headerDistance) / 20)
        )
        let footerHeight: CGFloat = 24
        let footer = CGRect(
            x: geometry.margins.left,
            y: geometry.pageSize.height - CGFloat(document.pageSetup.footerDistance) / 20 - footerHeight,
            width: geometry.contentWidth, height: footerHeight
        )
        return (header, footer)
    }

    static func attributed(_ text: HeaderFooterText, page: Int, of count: Int, color: UIColor)
        -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        switch text.alignment {
        case .center: style.alignment = .center
        case .trailing: style.alignment = .right
        default: style.alignment = .natural
        }
        // Tabs in headers usually push text to the centre and right tab stops Word's styles define.
        let resolved = text.resolved(page: page + 1, of: count).replacingOccurrences(of: "\t", with: "    ")
        return NSAttributedString(
            string: resolved, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
    }

    static func draw(document: WordDocument, page: Int, of count: Int, geometry: PageGeometry, color: UIColor) {
        let frames = frames(document: document, geometry: geometry)
        if let header = document.header {
            attributed(header, page: page, of: count, color: color)
                .draw(with: frames.header, options: [.usesLineFragmentOrigin], context: nil)
        }
        if let footer = document.footer {
            let text = attributed(footer, page: page, of: count, color: color)
            let height = text.boundingRect(
                with: CGSize(width: frames.footer.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], context: nil
            ).height
            var frame = frames.footer
            frame.origin.y = frame.maxY - ceil(height)
            frame.size.height = ceil(height)
            text.draw(with: frame, options: [.usesLineFragmentOrigin], context: nil)
        }
    }
}
