import Foundation

/// The bullets, numbering and multilevel lists the list panel offers.
enum ListPreset: String, CaseIterable, Identifiable, Sendable {
    case bullet, circle, square, dash, arrow, check, diamond
    case decimal, decimalParenthesis, lowerLetter, upperLetter, lowerRoman, upperRoman
    case outline, legal, outlineRoman, bulletLevels

    var id: String { rawValue }

    static let bullets: [ListPreset] = [.bullet, .circle, .square, .dash, .arrow, .check, .diamond]
    static let numbers: [ListPreset] = [.decimal, .decimalParenthesis, .lowerLetter, .upperLetter, .lowerRoman, .upperRoman]
    static let multilevel: [ListPreset] = [.outline, .legal, .outlineRoman, .bulletLevels]

    var kind: ListKind {
        Self.bullets.contains(self) || self == .bulletLevels ? .bulleted : .numbered
    }

    /// What the panel shows for it: its first level's label, or its first three levels'.
    var sample: String {
        let levels = self.levels
        let count = Self.multilevel.contains(self) ? 3 : 1
        return (0..<count).map { index in
            guard let level = levels[index] else { return "" }
            if level.format == "bullet" { return level.text }
            var text = level.text
            for placeholder in 1...9 { text = text.replacingOccurrences(of: "%\(placeholder)", with: ListLabeler.format(1, as: levels[placeholder - 1]?.format ?? "decimal")) }
            return text
        }.joined(separator: "  ")
    }

    /// Nine levels, each indented half an inch further, the label hanging a quarter inch.
    var levels: [Int: NumberingDefinitions.ListLevel] {
        func level(_ index: Int, format: String, text: String) -> NumberingDefinitions.ListLevel {
            NumberingDefinitions.ListLevel(format: format, text: text, indentLeft: 720 * (index + 1), hanging: 360)
        }
        let standardBullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        return Dictionary(uniqueKeysWithValues: (0..<9).map { index in
            let bullet: (String) -> NumberingDefinitions.ListLevel = { first in
                level(index, format: "bullet", text: index == 0 ? first : standardBullets[index % 3])
            }
            let numbered: (String, String) -> NumberingDefinitions.ListLevel = { format, pattern in
                // Deeper levels follow Word's usual decimal, letter, roman cycle.
                let formats = ["decimal", "lowerLetter", "lowerRoman"]
                return index == 0 ? level(0, format: format, text: pattern)
                    : level(index, format: formats[index % 3], text: "%\(index + 1).")
            }
            switch self {
            case .bullet: return (index, bullet("\u{2022}"))
            case .circle: return (index, bullet("\u{25E6}"))
            case .square: return (index, bullet("\u{25AA}"))
            case .dash: return (index, bullet("\u{2013}"))
            case .arrow: return (index, bullet("\u{27A2}"))
            case .check: return (index, bullet("\u{2713}"))
            case .diamond: return (index, bullet("\u{2756}"))
            case .decimal: return (index, numbered("decimal", "%1."))
            case .decimalParenthesis: return (index, numbered("decimal", "%1)"))
            case .lowerLetter: return (index, numbered("lowerLetter", "%1."))
            case .upperLetter: return (index, numbered("upperLetter", "%1."))
            case .lowerRoman: return (index, numbered("lowerRoman", "%1."))
            case .upperRoman: return (index, numbered("upperRoman", "%1."))
            case .outline:
                let formats = ["decimal", "lowerLetter", "lowerRoman"]
                return (index, level(index, format: formats[index % 3], text: "%\(index + 1)."))
            case .legal:
                let text = (1...(index + 1)).map { "%\($0)." }.joined()
                return (index, level(index, format: "decimal", text: text))
            case .outlineRoman:
                let formats = ["upperRoman", "upperLetter", "decimal", "lowerLetter", "lowerRoman"]
                return (index, level(index, format: formats[index % formats.count], text: "%\(index + 1)."))
            case .bulletLevels:
                return (index, level(index, format: "bullet", text: standardBullets[index % 3]))
            }
        })
    }
}
