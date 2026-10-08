import Foundation

/// Equations typed on one line, read into Office Math and written back out:
/// `a/b` a fraction, `x^2` and `x_i` scripts, `sqrt(x)` a root,
/// `sum_(i=1)^n`, `prod` and `int` big operators, `sin` and the like
/// functions, brackets that grow, and `\alpha`, `\pm`, `\infty` and the like.
enum LinearMath {
    static let names: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ",
        "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "·", "le": "≤", "ge": "≥", "ne": "≠", "approx": "≈",
        "equiv": "≡", "infty": "∞", "to": "→", "partial": "∂", "nabla": "∇", "in": "∈", "notin": "∉", "subset": "⊂",
        "supset": "⊃", "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃", "propto": "∝", "degree": "°",
    ]
    static let operators: [String: String] = ["sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮"]
    static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "log", "ln", "exp", "lim", "max", "min", "det"]

    // MARK: - Reading

    private enum Token: Equatable {
        case text(String)
        case word(String)
        case symbol(Character)
    }

    private static func tokens(_ input: String) -> [Token] {
        var result: [Token] = []
        var characters = Array(input)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "\\" {
                var name = ""
                index += 1
                while index < characters.count, characters[index].isLetter { name.append(characters[index]); index += 1 }
                result.append(.text(names[name] ?? name))
            } else if character.isLetter {
                var word = ""
                while index < characters.count, characters[index].isLetter { word.append(characters[index]); index += 1 }
                result.append(.word(word))
            } else if character.isNumber || character == "." {
                var number = ""
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    number.append(characters[index]); index += 1
                }
                result.append(.text(number))
            } else if "()^_/".contains(character) {
                result.append(.symbol(character))
                index += 1
            } else {
                result.append(.text(String(character == "*" ? "·" : character)))
                index += 1
            }
        }
        characters = []
        return result
    }

    /// The equation as an `m:oMath` element.
    static func omml(_ input: String) -> String {
        var parser = Parser(tokens: tokens(input))
        return "<m:oMath>\(parser.expression())</m:oMath>"
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0

        init(tokens: [Token]) { self.tokens = tokens }

        private var current: Token? { position < tokens.count ? tokens[position] : nil }

        static func run(_ text: String, plain: Bool = false) -> String {
            let style = plain ? "<m:rPr><m:sty m:val=\"p\"/></m:rPr>" : ""
            return "<m:r>\(style)<m:t>\(XMLLite.escape(text))</m:t></m:r>"
        }

        /// Terms until a closing bracket or the end.
        mutating func expression() -> String {
            var output = ""
            while let token = current, token != .symbol(")") {
                output += term()
            }
            return output
        }

        /// An atom with its scripts, and the denominator if it is a fraction's numerator.
        mutating func term() -> String {
            var base = atom()
            if base.isOperator { return bigOperator(base.xml) }
            var lower: String?
            var upper: String?
            while let token = current, token == .symbol("_") || token == .symbol("^") {
                position += 1
                let script = atom(unwrapping: true).xml
                if token == .symbol("_") { lower = script } else { upper = script }
            }
            switch (lower, upper) {
            case let (low?, high?): base.xml = "<m:sSubSup><m:e>\(base.xml)</m:e><m:sub>\(low)</m:sub><m:sup>\(high)</m:sup></m:sSubSup>"
            case let (low?, nil): base.xml = "<m:sSub><m:e>\(base.xml)</m:e><m:sub>\(low)</m:sub></m:sSub>"
            case let (nil, high?): base.xml = "<m:sSup><m:e>\(base.xml)</m:e><m:sup>\(high)</m:sup></m:sSup>"
            default: break
            }
            if current == .symbol("/") {
                position += 1
                let denominator = term()
                return "<m:f><m:num>\(base.unwrapped)</m:num><m:den>\(Self.unwrap(denominator))</m:den></m:f>"
            }
            return base.xml
        }

        struct Atom {
            var xml: String
            /// What it holds without its brackets, for a fraction's or script's part.
            var unwrapped: String
            var isOperator = false
        }

        static func unwrap(_ xml: String) -> String {
            guard xml.hasPrefix("<m:d><m:e>"), xml.hasSuffix("</m:e></m:d>") else { return xml }
            return String(xml.dropFirst("<m:d><m:e>".count).dropLast("</m:e></m:d>".count))
        }

        mutating func atom(unwrapping: Bool = false) -> Atom {
            guard let token = current else { return Atom(xml: "", unwrapped: "") }
            position += 1
            switch token {
            case .symbol("("):
                let inner = expression()
                if current == .symbol(")") { position += 1 }
                let wrapped = "<m:d><m:e>\(inner)</m:e></m:d>"
                return Atom(xml: unwrapping ? inner : wrapped, unwrapped: inner)
            case .word(let word):
                if word == "sqrt" {
                    let inner = atom(unwrapping: true).xml
                    let xml = "<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e>\(inner)</m:e></m:rad>"
                    return Atom(xml: xml, unwrapped: xml)
                }
                if let symbol = operators[word] { return Atom(xml: symbol, unwrapped: symbol, isOperator: true) }
                if functions.contains(word) {
                    let argument = current == nil ? "" : atom().xml
                    let xml = "<m:func><m:fName>\(Self.run(word, plain: true))</m:fName><m:e>\(argument)</m:e></m:func>"
                    return Atom(xml: xml, unwrapped: xml)
                }
                // Letters in a row are a product of variables, each its own letter.
                let xml = Self.run(word)
                return Atom(xml: xml, unwrapped: xml)
            case .text(let text):
                let xml = Self.run(text)
                return Atom(xml: xml, unwrapped: xml)
            case .symbol(let symbol):
                let xml = Self.run(String(symbol))
                return Atom(xml: xml, unwrapped: xml)
            }
        }

        /// A sum, product or integral: its limits, then what it applies to.
        mutating func bigOperator(_ symbol: String) -> String {
            var lower = ""
            var upper = ""
            while let token = current, token == .symbol("_") || token == .symbol("^") {
                position += 1
                let script = atom(unwrapping: true).xml
                if token == .symbol("_") { lower = script } else { upper = script }
            }
            let isIntegral = symbol.hasPrefix("∫") || symbol == "∬" || symbol == "∮"
            let body = current == nil ? "" : term()
            return """
                <m:nary><m:naryPr><m:chr m:val="\(symbol)"/><m:limLoc m:val="\(isIntegral ? "subSup" : "undOvr")"/>\
                \(lower.isEmpty ? "<m:subHide m:val=\"1\"/>" : "")\(upper.isEmpty ? "<m:supHide m:val=\"1\"/>" : "")</m:naryPr>\
                <m:sub>\(lower)</m:sub><m:sup>\(upper)</m:sup><m:e>\(body)</m:e></m:nary>
                """
        }
    }

    // MARK: - Writing

    /// An equation's Office Math as a line to edit, as near as the syntax comes.
    static func linear(fromXML xml: String) -> String {
        var namespaces = DOCXPatcher.namespaceBindings(for: xml)
        namespaces["m"] = MathRenderer.namespace
        guard let element = XMLLite.fragment(xml, namespaces: namespaces) else { return "" }
        return linear(element).trimmed
    }

    private static func grouped(_ text: String) -> String {
        text.count <= 1 || text.allSatisfy({ $0.isLetter || $0.isNumber }) ? text : "(\(text))"
    }

    private static func linear(_ element: XMLElement) -> String {
        func child(_ name: String) -> String { element.firstChild(named: name).map(linear) ?? "" }
        func children() -> String { element.children.filter { !$0.name.hasSuffix("Pr") }.map(linear).joined() }
        let reverse = Dictionary(names.map { ($1, "\\" + $0) }, uniquingKeysWith: { first, _ in first })
        switch element.name {
        case "r":
            let text = element.children(named: "t").map(\.text).joined()
            return text.map { character in
                let symbol = String(character)
                if let name = reverse[symbol] { return name + (" ") }
                return symbol
            }.joined()
        case "f": return "\(grouped(child("num")))/\(grouped(child("den")))"
        case "sSup": return "\(child("e"))^\(grouped(child("sup")))"
        case "sSub": return "\(child("e"))_\(grouped(child("sub")))"
        case "sSubSup": return "\(child("e"))_\(grouped(child("sub")))^\(grouped(child("sup")))"
        case "rad": return "sqrt(\(child("e")))"
        case "nary":
            let symbol = element.firstChild(named: "naryPr")?.firstChild(named: "chr")?.attribute("val") ?? "∫"
            let name = operators.first { $0.value == symbol }?.key ?? "int"
            var output = name
            let lower = child("sub")
            let upper = child("sup")
            if !lower.isEmpty { output += "_\(grouped(lower))" }
            if !upper.isEmpty { output += "^\(grouped(upper))" }
            return output + " " + child("e")
        case "d":
            let parts = element.children(named: "e").map(linear)
            return "(" + parts.joined(separator: "|") + ")"
        case "func": return "\(child("fName")) \(grouped(child("e")))"
        default: return children()
        }
    }
}
