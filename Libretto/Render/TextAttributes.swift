import UIKit

/// What the editor's attributed text carries besides how it looks.
///
/// The text the page view edits is a rendering of the model, with the model
/// riding along in these attributes. Reading the text back into blocks uses
/// only these, never the fonts and colours, which are derived from them.
extension NSAttributedString.Key {
    /// A `ParagraphBox`, on every character of a paragraph, its mark included.
    static let librettoParagraph = NSAttributedString.Key("libretto.paragraph")
    /// A `RunBox`, on every character a run of text produced.
    static let librettoRun = NSAttributedString.Key("libretto.run")
    /// An `InlineBox` on the characters a kept element shows as.
    static let librettoToken = NSAttributedString.Key("libretto.token")
    /// A `MarkersBox` on the character after markers that take no room.
    static let librettoMarkers = NSAttributedString.Key("libretto.markers")
    /// A `ListLabelBox` on a list paragraph, drawn in its margin.
    static let librettoListLabel = NSAttributedString.Key("libretto.listLabel")
    /// A `BlockBox` on the mark ending a table or kept block's line.
    static let librettoBlock = NSAttributedString.Key("libretto.block")
}

/// Keys that belong to the character they were put on, and must not be
/// carried on to text typed after it.
let librettoPositionalKeys: [NSAttributedString.Key] = [
    .librettoToken, .librettoMarkers, .librettoBlock, .attachment,
]

final class ParagraphBox: NSObject, Sendable {
    let paragraph: Paragraph

    init(_ paragraph: Paragraph) {
        self.paragraph = paragraph
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ParagraphBox else { return false }
        return other === self || other.paragraph == paragraph
    }

    override var hash: Int { paragraph.id.hashValue }
}

final class RunBox: NSObject, Sendable {
    let format: RunFormat
    let hyperlink: Hyperlink?

    init(_ format: RunFormat, hyperlink: Hyperlink?) {
        self.format = format
        self.hyperlink = hyperlink
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? RunBox else { return false }
        return other === self || (other.format == format && other.hyperlink == hyperlink)
    }

    override var hash: Int { format.hashValue }
}

/// A kept element, identified by the box itself: two tokens that happen to
/// hold the same element are still two tokens.
final class InlineBox: NSObject, Sendable {
    let inline: Inline
    /// The text it was shown as, to tell whether that has been edited.
    let display: String

    init(_ inline: Inline, display: String) {
        self.inline = inline
        self.display = display
    }
}

final class MarkersBox: NSObject, Sendable {
    let markers: [Inline]

    init(_ markers: [Inline]) {
        self.markers = markers
    }
}

final class ListLabelBox: NSObject, Sendable {
    let text: String
    /// Where the label starts, from the text container's leading edge.
    let indent: CGFloat

    init(text: String, indent: CGFloat) {
        self.text = text
        self.indent = indent
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ListLabelBox else { return false }
        return other.text == text && other.indent == indent
    }

    override var hash: Int { text.hashValue }
}

final class BlockBox: NSObject, Sendable {
    let block: Block

    init(_ block: Block) {
        self.block = block
    }
}

/// A picture in the text.
final class ImageAttachment: NSTextAttachment {
    var inline = Inline(.text(""))
}

/// One line of a block shown as pictures: a table row, or a line of a kept block.
final class BlockAttachment: NSTextAttachment {
    var block: Block = .paragraph(Paragraph())
    /// The table row this line draws, for tables.
    var rowID: TableRow.ID?
}

// MARK: - Special characters

enum TextCharacters {
    static let paragraphBreak: Character = "\n"
    static let lineBreak = "\u{2028}"
    static let pageBreak = "\u{0C}"
    static let attachment = "\u{FFFC}"

    static let paragraphBreakUnit: unichar = 0x0A
    static let lineBreakUnit: unichar = 0x2028
    static let pageBreakUnit: unichar = 0x0C
    static let attachmentUnit: unichar = 0xFFFC
    static let tabUnit: unichar = 0x09
}
