import SwiftUI
import UIKit

/// Everything resolving the model into fonts, colours and paragraph styles needs.
struct RenderContext: Sendable {
    var styles: StyleSheet
    var numbering: NumberingDefinitions
    var package: DocumentPackage
    var scheme: ColorScheme
    /// Points.
    var contentWidth: CGFloat
    var contentHeight: CGFloat
    var images: ImageStore
    /// Six-digit RGB of what the text sits on, such as a shaded table cell,
    /// so its colour adapts against that rather than the page.
    var backgroundHex: String?
    /// Each note reference's number, by `kind:id`.
    var noteNumbers: [String: String] = [:]

    init(document: WordDocument, scheme: ColorScheme, images: ImageStore) {
        styles = document.styles
        numbering = document.numbering
        package = document.package
        self.scheme = scheme
        contentWidth = document.pageSetup.contentWidth
        contentHeight = document.pageSetup.contentHeight
        self.images = images
        noteNumbers = NoteNumbering.numbers(in: document)
    }

    var defaultTextColor: UIColor { scheme == .dark ? .white : .black }
}

/// Decoded pictures, kept across re-renders so editing does not decode them again.
final class ImageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: UIImage] = [:]

    func image(forRelationship id: String, in package: DocumentPackage) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[id] { return cached }
        guard let data = package.data(forRelationship: id), let image = UIImage(data: data) else { return nil }
        images[id] = image
        return image
    }
}

enum Typography {
    // MARK: - Runs

    /// The attributes a run of text is drawn with.
    static func runAttributes(
        _ direct: RunStyle, paragraph: ParagraphProperties, hyperlink: Hyperlink?, revision: Revision? = nil,
        context: RenderContext, fontScale: CGFloat = 1
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyleID = paragraph.styleID ?? context.styles.defaultParagraphStyleID
        var style = context.styles.resolvedRunStyle(direct, paragraphStyleID: paragraphStyleID)
        if hyperlink != nil, style.colorHex == nil {
            // A link the document gave no colour of its own still reads as one.
            style.colorHex = "0563C1"
            style.underline = style.underline ?? true
        }

        var attributes: [NSAttributedString.Key: Any] = [:]
        let font = self.font(for: style, styles: context.styles, scale: fontScale)
        attributes[.font] = font

        let highlightHex = style.highlight.flatMap { highlightColors[$0] }
        if let highlightHex {
            attributes[.backgroundColor] = AdaptiveColor.uiColor(hex: highlightHex, for: context.scheme, isText: false)
        }
        let backgroundHex = highlightHex ?? context.backgroundHex
        attributes[.foregroundColor] = AdaptiveColor.uiTextColor(
            hex: style.colorHex ?? (backgroundHex != nil ? "000000" : nil), on: backgroundHex, for: context.scheme
        ) ?? context.defaultTextColor

        if style.underline == true { attributes[.underlineStyle] = underline(style.underlineStyle).rawValue }
        if style.isStruckThrough == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.isDoubleStruckThrough == true { attributes[.strikethroughStyle] = NSUnderlineStyle.double.rawValue }
        switch style.verticalAlignment {
        case .superscript: attributes[.baselineOffset] = font.pointSize * 0.5
        case .subscript: attributes[.baselineOffset] = -font.pointSize * 0.25
        default: break
        }
        if let position = style.position, position != 0 {
            attributes[.baselineOffset] = (attributes[.baselineOffset] as? CGFloat ?? 0) + CGFloat(position) / 2 * fontScale
        }
        if style.allCaps == true { attributes[.librettoAllCaps] = true }
        if let spacing = style.characterSpacing, spacing != 0 {
            attributes[.kern] = CGFloat(spacing) / 20 * fontScale
        }
        let ink = attributes[.foregroundColor] as? UIColor ?? context.defaultTextColor
        if style.outline == true {
            // Hollow letters: a positive stroke width draws the outline alone.
            attributes[.strokeWidth] = 3.0
            attributes[.strokeColor] = ink
        }
        if style.shadow == true {
            let shadow = NSShadow()
            shadow.shadowOffset = CGSize(width: 1, height: 1)
            shadow.shadowBlurRadius = 1
            shadow.shadowColor = ink.withAlphaComponent(0.45)
            attributes[.shadow] = shadow
        } else if style.emboss == true || style.imprint == true {
            // Raised or pressed in: a light edge on one side of the letters.
            let edge = NSShadow()
            let offset: CGFloat = style.emboss == true ? -0.75 : 0.75
            edge.shadowOffset = CGSize(width: offset, height: offset)
            edge.shadowColor = context.scheme == .dark ? UIColor.black : UIColor.white
            attributes[.shadow] = edge
            attributes[.foregroundColor] = ink.withAlphaComponent(0.6)
        }
        if let revision {
            // In the colour of whoever made the change: added text underlined, removed text struck through.
            let color = reviewerColor(revision.author, scheme: context.scheme)
            attributes[.foregroundColor] = color
            if revision.kind.adds {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = color
            } else {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = color
            }
        }
        return attributes
    }

    /// A colour of its own for each reviewer, as Word gives them.
    static func reviewerColor(_ author: String?, scheme: ColorScheme) -> UIColor {
        let palette: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemPurple, .systemOrange, .systemTeal]
        let hash = (author ?? "").unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let color = palette[abs(hash) % palette.count]
        return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
    }

    /// How a `w:u` kind is drawn; wavy lines, which TextKit lacks, as a single line.
    static func underline(_ kind: String?) -> NSUnderlineStyle {
        switch kind {
        case "double", "wavyDouble": return .double
        case "thick", "wavyHeavy": return .thick
        case "dotted": return [.single, .patternDot]
        case "dottedHeavy": return [.thick, .patternDot]
        case "dash", "dashLong": return [.single, .patternDash]
        case "dashedHeavy", "dashLongHeavy": return [.thick, .patternDash]
        case "dotDash": return [.single, .patternDashDot]
        case "dashDotHeavy": return [.thick, .patternDashDot]
        case "dotDotDash": return [.single, .patternDashDotDot]
        case "dashDotDotHeavy": return [.thick, .patternDashDotDot]
        case "words": return [.single, .byWord]
        default: return .single
        }
    }

    /// Word's `w:highlight` names.
    static let highlightColors: [String: String] = [
        "yellow": "FFFF00", "green": "00FF00", "cyan": "00FFFF", "magenta": "FF00FF", "blue": "0000FF",
        "red": "FF0000", "darkBlue": "000080", "darkCyan": "008080", "darkGreen": "008000",
        "darkMagenta": "800080", "darkRed": "800000", "darkYellow": "808000", "darkGray": "808080",
        "lightGray": "C0C0C0", "black": "000000", "white": "FFFFFF",
    ]

    private static let installedFamilies = Set(UIFont.familyNames)

    /// Office fonts iOS lacks, by what iOS has that looks most like them.
    private static let substitutes: [String: String] = [
        "Cambria": "Georgia", "Constantia": "Georgia", "Book Antiqua": "Palatino",
        "Garamond": "Baskerville", "Century": "Georgia", "Consolas": "Menlo", "Lucida Console": "Menlo",
        "MS Mincho": "Hiragino Mincho ProN", "ＭＳ 明朝": "Hiragino Mincho ProN", "Yu Mincho": "Hiragino Mincho ProN",
        "游明朝": "Hiragino Mincho ProN", "MS Gothic": "Hiragino Sans", "ＭＳ ゴシック": "Hiragino Sans",
        "Yu Gothic": "Hiragino Sans", "游ゴシック": "Hiragino Sans", "Meiryo": "Hiragino Sans", "メイリオ": "Hiragino Sans",
        "SimSun": "PingFang SC", "宋体": "PingFang SC", "Microsoft YaHei": "PingFang SC",
        "PMingLiU": "PingFang TC", "Microsoft JhengHei": "PingFang TC", "Malgun Gothic": "Apple SD Gothic Neo",
        "Batang": "Apple SD Gothic Neo", "맑은 고딕": "Apple SD Gothic Neo",
    ]

    static func font(for style: RunStyle, styles: StyleSheet, scale: CGFloat = 1) -> UIFont {
        var size = CGFloat(style.fontSize ?? 22) / 2 * scale
        if style.verticalAlignment == .superscript || style.verticalAlignment == .subscript { size *= 0.65 }

        var name = style.fontName
        if name == RunStyle.minorThemeFont { name = styles.minorFont }
        if name == RunStyle.majorThemeFont { name = styles.majorFont }
        if let requested = name, !installedFamilies.contains(requested) { name = substitutes[requested] }

        var descriptor: UIFontDescriptor
        if let family = name, installedFamilies.contains(family) {
            descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        } else {
            descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.isBold == true { traits.insert(.traitBold) }
        if style.isItalic == true { traits.insert(.traitItalic) }
        if !traits.isEmpty {
            descriptor = descriptor.withSymbolicTraits(traits.union(descriptor.symbolicTraits))
                ?? UIFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(traits) ?? descriptor
        }
        if style.smallCaps == true {
            // The font's own small capitals: lower case type, small caps selector.
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                UIFontDescriptor.FeatureKey.featureIdentifier: 37, UIFontDescriptor.FeatureKey.typeIdentifier: 1,
            ]]])
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - Paragraphs

    struct Indents {
        /// Points from the text's leading edge.
        var left: CGFloat
        var right: CGFloat
        /// Where the first line starts, relative to `left`.
        var firstLine: CGFloat
    }

    static func resolvedParagraph(_ direct: ParagraphProperties, context: RenderContext) -> ParagraphProperties {
        context.styles.resolvedParagraphProperties(direct)
    }

    /// The list a paragraph is in, its own or its style's.
    static func listReference(_ resolved: ParagraphProperties) -> ListReference? {
        guard let list = resolved.list, list.numberingID != 0 else { return nil }
        return list
    }

    static func indents(
        direct: ParagraphProperties, resolved: ParagraphProperties, context: RenderContext
    ) -> Indents {
        // A list level's indentation sits between the style's and the paragraph's own.
        let level = listReference(resolved).flatMap { context.numbering.level($0.level, of: $0.numberingID) }
        let left = direct.indentLeft ?? level?.indentLeft ?? resolved.indentLeft ?? 0
        let firstLine = direct.indentFirstLine ?? level.flatMap { $0.hanging.map { -$0 } } ?? resolved.indentFirstLine ?? 0
        return Indents(
            left: CGFloat(left) / 20, right: CGFloat(resolved.indentRight ?? 0) / 20,
            firstLine: CGFloat(firstLine) / 20
        )
    }

    static func paragraphStyle(
        _ direct: ParagraphProperties, context: RenderContext, isListItem: Bool
    ) -> NSParagraphStyle {
        let resolved = resolvedParagraph(direct, context: context)
        let indents = self.indents(direct: direct, resolved: resolved, context: context)
        let style = NSMutableParagraphStyle()
        switch resolved.alignment ?? .leading {
        case .leading: style.alignment = .natural
        case .center: style.alignment = .center
        case .trailing: style.alignment = .right
        case .justified: style.alignment = .justified
        }
        style.headIndent = max(0, indents.left)
        // A list item's label hangs in the indent; its text starts at the indent.
        style.firstLineHeadIndent = max(0, isListItem ? indents.left : indents.left + indents.firstLine)
        style.tailIndent = -max(0, indents.right)
        style.paragraphSpacingBefore = CGFloat(resolved.spacingBefore ?? 0) / 20
        style.paragraphSpacing = CGFloat(resolved.spacingAfter ?? 0) / 20
        if let spacing = resolved.lineSpacing {
            switch spacing.rule {
            case .auto:
                // Word's single spacing is a little looser than TextKit's.
                style.lineHeightMultiple = CGFloat(spacing.line) / 240 * 1.0
            case .exact:
                style.minimumLineHeight = CGFloat(spacing.line) / 20
                style.maximumLineHeight = CGFloat(spacing.line) / 20
            case .atLeast:
                style.minimumLineHeight = CGFloat(spacing.line) / 20
            }
        }
        style.defaultTabInterval = 36
        style.tabStops = (resolved.tabStops ?? []).compactMap { stop in
            let location = CGFloat(stop.position) / 20
            switch stop.alignment {
            case .left: return NSTextTab(textAlignment: .natural, location: location)
            case .center: return NSTextTab(textAlignment: .center, location: location)
            case .right: return NSTextTab(textAlignment: .right, location: location)
            case .decimal:
                return NSTextTab(textAlignment: .right, location: location, options: [
                    .columnTerminators: NSTextTab.columnTerminators(for: Locale.current),
                ])
            case .bar, .clear: return nil
            }
        }
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Whether a paragraph is in a list, by its own properties or its style's.
    static func isListItem(_ direct: ParagraphProperties, context: RenderContext) -> Bool {
        listReference(resolvedParagraph(direct, context: context)) != nil
    }
}

// MARK: - List labels

/// Numbers list paragraphs in reading order, the way Word counts them.
struct ListLabeler {
    let context: RenderContext
    /// Per abstract list, the current count at each level. Lists that share
    /// an abstract definition share their count.
    private var counters: [Int: [Int: Int]] = [:]

    init(context: RenderContext) {
        self.context = context
    }

    /// The label for the next paragraph, or `nil` if it is not in a list.
    mutating func label(for direct: ParagraphProperties) -> ListLabelBox? {
        let resolved = Typography.resolvedParagraph(direct, context: context)
        guard let list = Typography.listReference(resolved),
              let abstract = context.numbering.instances[list.numberingID],
              let level = context.numbering.level(list.level, of: list.numberingID) else { return nil }

        var counts = counters[abstract] ?? [:]
        counts[list.level] = (counts[list.level] ?? (level.start - 1)) + 1
        // Moving up a level starts the levels below it over.
        for deeper in counts.keys where deeper > list.level { counts[deeper] = nil }
        counters[abstract] = counts

        let text: String
        if level.format == "bullet" {
            text = Self.bullet(level.text)
        } else if level.format == "none" {
            text = ""
        } else {
            var result = level.text
            for index in (0...8).reversed() {
                let placeholder = "%\(index + 1)"
                guard result.contains(placeholder) else { continue }
                let format = context.numbering.level(index, of: list.numberingID)
                let start = format?.start ?? 1
                let value = counts[index] ?? start
                result = result.replacingOccurrences(
                    of: placeholder, with: Self.format(value, as: format?.format ?? "decimal")
                )
            }
            text = result
        }
        let indents = Typography.indents(direct: direct, resolved: resolved, context: context)
        return ListLabelBox(text: text, indent: max(0, indents.left + indents.firstLine))
    }

    /// Bullets set in Symbol or Wingdings use private-use code points; these
    /// are what they look like.
    static func bullet(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "\u{2022}" }
        switch scalar.value {
        case 0xF0B7, 0xF06C, 0xF09F: return "\u{2022}"
        case 0xF0A7, 0xF06E: return "\u{25AA}"
        case 0xF0D8, 0xF0E0: return "\u{27A2}"
        case 0xF0FC: return "\u{2713}"
        case 0xF000...0xF0FF: return "\u{2022}"
        default: return scalar.value == 0x6F ? "\u{25E6}" : text
        }
    }

    static func format(_ value: Int, as format: String) -> String {
        switch format {
        case "lowerLetter": return letters(value).lowercased()
        case "upperLetter": return letters(value)
        case "lowerRoman": return roman(value).lowercased()
        case "upperRoman": return roman(value)
        case "decimalZero": return value < 10 ? "0\(value)" : String(value)
        case "decimalEnclosedCircle" where (1...20).contains(value):
            return String(Character(UnicodeScalar(0x2460 + value - 1)!))
        default: return String(value)
        }
    }

    private static func letters(_ value: Int) -> String {
        guard value > 0 else { return "" }
        // Word repeats the letter rather than counting on: Y, Z, AA, BB.
        let letter = Character(UnicodeScalar(65 + (value - 1) % 26)!)
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    private static func roman(_ value: Int) -> String {
        guard value > 0, value < 4000 else { return String(value) }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var remaining = value
        var result = ""
        for (amount, numeral) in table {
            while remaining >= amount {
                result += numeral
                remaining -= amount
            }
        }
        return result
    }
}
