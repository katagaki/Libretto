import UIKit

/// Lays out and draws Office Math (OMML): fractions, scripts, radicals,
/// big operators, delimiters, functions, accents, bars, limits, matrices and
/// equation arrays, each a box with a width, an ascent and a descent.
enum MathRenderer {
    static let namespace = "http://schemas.openxmlformats.org/officeDocument/2006/math"

    nonisolated(unsafe) private static let equationPattern = #/^<(?:[\w.\-]+:)?oMath(?:Para)?\b/#

    /// Whether a kept element is an equation.
    static func isEquation(_ xml: String) -> Bool { xml.firstMatch(of: equationPattern) != nil }

    /// An equation drawn: the picture, and how far it reaches below the baseline.
    static func image(forXML xml: String, fontSize: CGFloat, color: UIColor) -> (image: UIImage, descent: CGFloat)? {
        var namespaces = DOCXPatcher.namespaceBindings(for: xml)
        namespaces["m"] = namespace
        guard let element = XMLLite.fragment(xml, namespaces: namespaces) else { return nil }
        let box = Layout(size: fontSize, color: color).box(element)
        let pad: CGFloat = 1
        let size = CGSize(width: ceil(box.width) + pad * 2, height: ceil(box.ascent + box.descent) + pad * 2)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            box.draw(CGPoint(x: pad, y: pad + box.ascent))
        }
        return (image, box.descent + pad)
    }

    /// Something laid out: drawn with its baseline's left end at a point.
    struct Box {
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var draw: (CGPoint) -> Void

        static var empty: Box { Box(width: 0, ascent: 0, descent: 0) { _ in } }

        static func space(_ width: CGFloat) -> Box { Box(width: width, ascent: 0, descent: 0) { _ in } }

        /// Boxes side by side on one baseline.
        static func row(_ boxes: [Box]) -> Box {
            guard !boxes.isEmpty else { return .empty }
            return Box(
                width: boxes.reduce(0) { $0 + $1.width }, ascent: boxes.map(\.ascent).max() ?? 0,
                descent: boxes.map(\.descent).max() ?? 0
            ) { origin in
                var x = origin.x
                for box in boxes {
                    box.draw(CGPoint(x: x, y: origin.y))
                    x += box.width
                }
            }
        }
    }

    /// Lays out at one size: scripts and limits shrink as they nest.
    struct Layout {
        var size: CGFloat
        var color: UIColor

        private var smaller: Layout { Layout(size: max(5, size * 0.7), color: color) }
        /// Where fraction bars and minus signs sit above the baseline.
        private var axis: CGFloat { size * 0.27 }

        private func font(italic: Bool) -> UIFont {
            let names = italic ? ["STIXTwoMath-Italic", "TimesNewRomanPS-ItalicMT", "Georgia-Italic"]
                : ["STIXTwoMath-Regular", "TimesNewRomanPSMT", "Georgia"]
            for name in names { if let font = UIFont(name: name, size: size) { return font } }
            return italic ? UIFont.italicSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        }

        func text(_ string: String, italic: Bool = false) -> Box {
            let font = self.font(italic: italic)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let width = (string as NSString).size(withAttributes: attributes).width
            return Box(width: width, ascent: font.ascender, descent: -font.descender) { origin in
                (string as NSString).draw(at: CGPoint(x: origin.x, y: origin.y - font.ascender), withAttributes: attributes)
            }
        }

        private static let operators: Set<Character> = ["+", "−", "-", "=", "<", ">", "±", "∓", "×", "÷", "≤", "≥", "≠", "≈",
                                                         "≡", "→", "←", "⇒", "⇔", "∈", "∉", "⊂", "⊃", "∪", "∩", "·", "∝"]

        /// A run's text: letters in italic unless the run says plain, operators spaced out.
        private func run(_ element: XMLElement) -> Box {
            let content = element.children(named: "t").map(\.text).joined()
            let plain = element.firstChild(named: "rPr")?.firstChild(named: "sty")?.attribute("val") == "p"
            var boxes: [Box] = []
            var pending = ""
            var pendingItalic = false
            func flush() {
                if !pending.isEmpty { boxes.append(text(pending, italic: pendingItalic)) }
                pending = ""
            }
            for character in content {
                if Self.operators.contains(character) {
                    flush()
                    let symbol = character == "-" ? "−" : String(character)
                    boxes += [.space(size * 0.22), text(symbol), .space(size * 0.22)]
                    continue
                }
                let italic = !plain && character.isLetter
                if italic != pendingItalic { flush() }
                pendingItalic = italic
                pending.append(character)
            }
            flush()
            return .row(boxes)
        }

        /// An element's children, side by side, their properties left out.
        func row(_ element: XMLElement?) -> Box {
            guard let element else { return .empty }
            return .row(element.children.filter { !$0.name.hasSuffix("Pr") }.map(box))
        }

        private func property(_ element: XMLElement, _ properties: String, _ name: String) -> String? {
            element.firstChild(named: properties)?.firstChild(named: name)?.attribute("val")
        }

        func box(_ element: XMLElement) -> Box {
            switch element.name {
            case "oMathPara":
                let lines = element.children(named: "oMath").map(box)
                return stack(lines, centered: true)
            case "oMath", "e", "num", "den", "sup", "sub", "deg", "fName", "lim":
                return row(element)
            case "r":
                return run(element)
            case "f":
                return fraction(element)
            case "sSup", "sSub", "sSubSup":
                return scripts(base: row(element.firstChild(named: "e")), sub: element.firstChild(named: "sub"),
                               sup: element.firstChild(named: "sup"))
            case "sPre":
                let scripts = self.scripts(base: .empty, sub: element.firstChild(named: "sub"), sup: element.firstChild(named: "sup"))
                return .row([scripts, row(element.firstChild(named: "e"))])
            case "rad":
                return radical(element)
            case "nary":
                return nary(element)
            case "d":
                return delimited(element)
            case "func":
                return .row([row(element.firstChild(named: "fName")), .space(size * 0.17), row(element.firstChild(named: "e"))])
            case "acc":
                return accent(element)
            case "bar":
                return overline(row(element.firstChild(named: "e")), below: property(element, "barPr", "pos") != "top")
            case "groupChr":
                let character = property(element, "groupChrPr", "chr") ?? "\u{23DF}"
                let below = property(element, "groupChrPr", "pos") != "top"
                return limit(row(element.firstChild(named: "e")), Layout(size: size, color: color).text(character), below: below)
            case "limLow", "limUpp":
                return limit(row(element.firstChild(named: "e")), smaller.row(element.firstChild(named: "lim")), below: element.name == "limLow")
            case "m":
                return matrix(element)
            case "eqArr":
                return stack(element.children(named: "e").map(row), centered: false)
            case "borderBox":
                let inner = row(element.firstChild(named: "e"))
                return Box(width: inner.width + 4, ascent: inner.ascent + 2, descent: inner.descent + 2) { origin in
                    inner.draw(CGPoint(x: origin.x + 2, y: origin.y))
                    color.setStroke()
                    UIBezierPath(rect: CGRect(x: origin.x + 0.5, y: origin.y - inner.ascent - 1.5, width: inner.width + 3,
                                              height: inner.ascent + inner.descent + 3)).stroke()
                }
            case "phant":
                let inner = row(element.firstChild(named: "e"))
                return Box(width: inner.width, ascent: inner.ascent, descent: inner.descent) { _ in }
            default:
                return element.name.hasSuffix("Pr") ? .empty : row(element)
            }
        }

        // MARK: Pieces

        private func fraction(_ element: XMLElement) -> Box {
            let type = property(element, "fPr", "type")
            let inner = Layout(size: size * 0.9, color: color)
            let numerator = inner.row(element.firstChild(named: "num"))
            let denominator = inner.row(element.firstChild(named: "den"))
            if type == "lin" || type == "skw" {
                return .row([numerator, text("/"), denominator])
            }
            let gap = size * 0.12
            let width = max(numerator.width, denominator.width) + size * 0.3
            let axis = self.axis
            return Box(
                width: width, ascent: axis + gap + numerator.descent + numerator.ascent,
                descent: denominator.ascent + gap + denominator.descent - axis
            ) { origin in
                numerator.draw(CGPoint(x: origin.x + (width - numerator.width) / 2, y: origin.y - axis - gap - numerator.descent))
                denominator.draw(CGPoint(x: origin.x + (width - denominator.width) / 2, y: origin.y - axis + gap + denominator.ascent))
                if type != "noBar" {
                    color.setFill()
                    UIRectFill(CGRect(x: origin.x + 1, y: origin.y - axis - 0.4, width: width - 2, height: 0.8))
                }
            }
        }

        private func scripts(base: Box, sub: XMLElement?, sup: XMLElement?) -> Box {
            let raised = sup.map { smaller.row($0) }
            let lowered = sub.map { smaller.row($0) }
            let raise = max(size * 0.42, base.ascent - (raised?.ascent ?? 0) * 0.5)
            let lower = max(size * 0.2, base.descent)
            let scriptsWidth = max(raised?.width ?? 0, lowered?.width ?? 0)
            return Box(
                width: base.width + scriptsWidth + 1,
                ascent: max(base.ascent, raise + (raised?.ascent ?? 0)),
                descent: max(base.descent, lower + (lowered?.descent ?? 0))
            ) { origin in
                base.draw(origin)
                raised?.draw(CGPoint(x: origin.x + base.width + 1, y: origin.y - raise))
                lowered?.draw(CGPoint(x: origin.x + base.width + 1, y: origin.y + lower))
            }
        }

        private func radical(_ element: XMLElement) -> Box {
            let inner = row(element.firstChild(named: "e"))
            let hidesDegree = property(element, "radPr", "degHide") == "1" || property(element, "radPr", "degHide") == "on"
            let degree = hidesDegree ? nil : element.firstChild(named: "deg").map { smaller.row($0) }
            let gap = size * 0.12
            let sign = size * 0.55
            let lead = max(sign, (degree?.width ?? 0) + sign * 0.4)
            let height = inner.ascent + inner.descent + gap * 2
            return Box(width: lead + inner.width + 2, ascent: inner.ascent + gap * 2, descent: inner.descent) { origin in
                let top = origin.y - inner.ascent - gap * 1.5
                let bottom = origin.y + inner.descent
                let path = UIBezierPath()
                path.move(to: CGPoint(x: origin.x + lead - sign, y: bottom - height * 0.35))
                path.addLine(to: CGPoint(x: origin.x + lead - sign * 0.7, y: bottom - height * 0.42))
                path.addLine(to: CGPoint(x: origin.x + lead - sign * 0.4, y: bottom))
                path.addLine(to: CGPoint(x: origin.x + lead - 1, y: top))
                path.addLine(to: CGPoint(x: origin.x + lead + inner.width + 2, y: top))
                path.lineWidth = max(0.8, size * 0.06)
                color.setStroke()
                path.stroke()
                degree?.draw(CGPoint(x: origin.x, y: bottom - height * 0.5))
                inner.draw(CGPoint(x: origin.x + lead + 1, y: origin.y))
            }
        }

        private func nary(_ element: XMLElement) -> Box {
            let character = property(element, "naryPr", "chr") ?? "\u{222B}"
            let isIntegral = ["\u{222B}", "\u{222C}", "\u{222D}", "\u{222E}"].contains(character)
            let underOver = (property(element, "naryPr", "limLoc") ?? (isIntegral ? "subSup" : "undOvr")) == "undOvr"
            let symbol = Layout(size: size * 1.4, color: color).text(character)
            let lower = element.firstChild(named: "sub").map { smaller.row($0) } ?? .empty
            let upper = element.firstChild(named: "sup").map { smaller.row($0) } ?? .empty
            let body = row(element.firstChild(named: "e"))
            let operatorBox: Box
            if underOver {
                operatorBox = limit(limit(symbol, lower, below: true), upper, below: false)
            } else {
                let raise = symbol.ascent * 0.7
                let drop = symbol.descent + lower.ascent * 0.5
                operatorBox = Box(
                    width: symbol.width + max(lower.width, upper.width) + 1,
                    ascent: max(symbol.ascent, raise + upper.ascent), descent: max(symbol.descent, drop + lower.descent)
                ) { origin in
                    symbol.draw(origin)
                    upper.draw(CGPoint(x: origin.x + symbol.width + 1, y: origin.y - raise))
                    lower.draw(CGPoint(x: origin.x + symbol.width * 0.7, y: origin.y + drop))
                }
            }
            return .row([operatorBox, .space(size * 0.17), body])
        }

        private func delimited(_ element: XMLElement) -> Box {
            let open = property(element, "dPr", "begChr") ?? "("
            let close = property(element, "dPr", "endChr") ?? ")"
            let separator = property(element, "dPr", "sepChr") ?? "|"
            var parts: [Box] = []
            for (index, item) in element.children(named: "e").enumerated() {
                if index > 0 { parts.append(text(separator)) }
                parts.append(row(item))
            }
            let inner = Box.row(parts)
            // Delimiters as tall as what they hold.
            let height = max(size, inner.ascent + inner.descent)
            let fence = Layout(size: min(size * 3, height * 1.05), color: color)
            let left = open.isEmpty ? .empty : fence.text(open)
            let right = close.isEmpty ? .empty : fence.text(close)
            let shift = (left.ascent - left.descent) / 2 - (inner.ascent - inner.descent) / 2
            func centred(_ box: Box) -> Box {
                Box(width: box.width, ascent: box.ascent - shift, descent: box.descent + shift) { origin in
                    box.draw(CGPoint(x: origin.x, y: origin.y + shift))
                }
            }
            return .row([centred(left), inner, centred(right)])
        }

        private func accent(_ element: XMLElement) -> Box {
            let mark = property(element, "accPr", "chr") ?? "\u{0302}"
            let inner = row(element.firstChild(named: "e"))
            let spacing: [String: String] = [
                "\u{0302}": "^", "\u{0303}": "~", "\u{0307}": "˙", "\u{0308}": "¨", "\u{0301}": "´", "\u{0300}": "`",
                "\u{20D7}": "→", "\u{2192}": "→", "\u{030C}": "ˇ", "\u{0306}": "˘",
            ]
            if mark == "\u{0305}" || mark == "\u{0304}" || mark == "\u{00AF}" { return overline(inner, below: false) }
            let symbol = smaller.text(spacing[mark] ?? mark)
            return limit(inner, symbol, below: false)
        }

        private func overline(_ inner: Box, below: Bool) -> Box {
            let gap = size * 0.1
            return Box(width: inner.width, ascent: inner.ascent + (below ? 0 : gap * 2), descent: inner.descent + (below ? gap * 2 : 0)) { origin in
                inner.draw(origin)
                color.setFill()
                let y = below ? origin.y + inner.descent + gap : origin.y - inner.ascent - gap
                UIRectFill(CGRect(x: origin.x, y: y - 0.35, width: inner.width, height: 0.7))
            }
        }

        /// Something set centred above or below another.
        private func limit(_ base: Box, _ attached: Box, below: Bool) -> Box {
            let width = max(base.width, attached.width)
            let gap = size * 0.05
            return Box(
                width: width,
                ascent: below ? base.ascent : base.ascent + gap + attached.ascent + attached.descent,
                descent: below ? base.descent + gap + attached.ascent + attached.descent : base.descent
            ) { origin in
                base.draw(CGPoint(x: origin.x + (width - base.width) / 2, y: origin.y))
                let y = below ? origin.y + base.descent + gap + attached.ascent : origin.y - base.ascent - gap - attached.descent
                attached.draw(CGPoint(x: origin.x + (width - attached.width) / 2, y: y))
            }
        }

        private func matrix(_ element: XMLElement) -> Box {
            let rows = element.children(named: "mr").map { $0.children(named: "e").map(row) }
            let columns = rows.map(\.count).max() ?? 0
            let widths = (0..<columns).map { column in rows.compactMap { $0.indices.contains(column) ? $0[column].width : nil }.max() ?? 0 }
            let gap = size * 0.6
            let heights = rows.map { cells in (cells.map(\.ascent).max() ?? 0, cells.map(\.descent).max() ?? 0) }
            let total = heights.reduce(0) { $0 + $1.0 + $1.1 } + CGFloat(max(0, rows.count - 1)) * size * 0.2
            let width = widths.reduce(0, +) + gap * CGFloat(max(0, columns - 1))
            let axis = self.axis
            return Box(width: width, ascent: total / 2 + axis, descent: total / 2 - axis) { origin in
                var y = origin.y - total / 2 - axis
                for (index, cells) in rows.enumerated() {
                    y += heights[index].0
                    var x = origin.x
                    for (column, cell) in cells.enumerated() {
                        cell.draw(CGPoint(x: x + (widths[column] - cell.width) / 2, y: y))
                        x += widths[column] + gap
                    }
                    y += heights[index].1 + size * 0.2
                }
            }
        }

        /// Lines one above another, the first on the baseline.
        private func stack(_ lines: [Box], centered: Bool) -> Box {
            guard let first = lines.first else { return .empty }
            let width = lines.map(\.width).max() ?? 0
            let leading = size * 0.3
            let rest = lines.dropFirst().reduce(0) { $0 + $1.ascent + $1.descent + leading }
            return Box(width: width, ascent: first.ascent, descent: first.descent + rest) { origin in
                var y = origin.y
                for (index, line) in lines.enumerated() {
                    if index > 0 { y += lines[index - 1].descent + leading + line.ascent }
                    line.draw(CGPoint(x: origin.x + (centered ? (width - line.width) / 2 : 0), y: y))
                }
            }
        }
    }
}
