import SwiftUI
import UIKit

/// Prints a document to PDF, laid out in pages exactly as the page view shows it.
enum PDFExporter {
    static func data(from document: WordDocument) -> Data {
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let rendered = DocumentRenderer.render(document.body, context: context)

        let storage = NSTextStorage(attributedString: rendered.string)
        if let language = document.sourceLanguage {
            SyntaxHighlighter.apply(language, to: storage, scheme: .light, plainColor: context.defaultTextColor)
        }
        let layoutManager = PageLayoutManager(geometry: PageGeometry(setup: document.pageSetup, gap: 0))
        layoutManager.styles = document.styles
        layoutManager.footnotes = NoteLayout.notes(in: storage, document: document, context: context)
        layoutManager.sections = SectionLayout.spans(in: storage, final: document.pageSetup)
        let container = NSTextContainer()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let pages = layoutManager.layOutPages(in: container, startingWith: 4)
        // The pages as they settled, each section's at its own size.
        let geometry = layoutManager.geometry
        let texts = WordDocumentHeaderFooter(
            document: document, sections: layoutManager.sections.map(\.setup), pageSections: layoutManager.pageSections
        )

        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: geometry.pageSize)).pdfData { pdf in
            for page in 0..<pages {
                let shape = geometry.shape(page)
                // Each page its own size: the media box must say so, as well as the bounds.
                var box = CGRect(origin: .zero, size: shape.size)
                pdf.beginPage(withBounds: box, pageInfo: [
                    kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size),
                ])
                let graphics = pdf.cgContext
                let top = geometry.textTop(page)
                let visible = CGRect(x: 0, y: top, width: geometry.contentWidth, height: shape.contentHeight)
                let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
                let origin = CGPoint(x: geometry.textLeft, y: shape.margins.top - top)

                graphics.saveGState()
                graphics.clip(to: CGRect(
                    x: shape.margins.left - 40, y: shape.margins.top - 2,
                    width: shape.contentWidth + 80, height: shape.contentHeight + 4
                ))
                layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
                graphics.restoreGState()

                HeaderFooterDrawing.draw(texts, page: page, of: pages, shape: shape, color: .darkGray)
                if let notes = layoutManager.notesByPage[page], let height = layoutManager.noteHeights[page] {
                    PageLayoutManager.drawNotes(notes, in: CGRect(
                        x: shape.margins.left, y: shape.margins.top + shape.contentHeight - height,
                        width: shape.contentWidth, height: height
                    ), color: .black)
                }
            }
        }
    }
}

/// The header and footer, drawn as plain text in the page's margins.
enum HeaderFooterDrawing {
    static let font = UIFont.systemFont(ofSize: 9)

    static func frames(_ section: WordDocumentHeaderFooter.Section, shape: PageGeometry.Shape) -> (header: CGRect, footer: CGRect) {
        let header = CGRect(
            x: shape.margins.left, y: section.headerDistance,
            width: shape.contentWidth, height: max(12, shape.margins.top - section.headerDistance)
        )
        let footerHeight: CGFloat = 24
        let footer = CGRect(
            x: shape.margins.left, y: shape.size.height - section.footerDistance - footerHeight,
            width: shape.contentWidth, height: footerHeight
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

    static func draw(_ texts: WordDocumentHeaderFooter, page: Int, of count: Int, shape: PageGeometry.Shape, color: UIColor) {
        let frames = frames(texts.section(forPage: page), shape: shape)
        if let header = texts.header(forPage: page) {
            attributed(header, page: page, of: count, color: color)
                .draw(with: frames.header, options: [.usesLineFragmentOrigin], context: nil)
        }
        if let footer = texts.footer(forPage: page) {
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
