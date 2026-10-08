import SwiftUI

/// Symbols and special characters to put in at the selection, the ones used
/// lately first.
struct SymbolPanel: View {
    @Bindable var state: EditorState
    @AppStorage("recentSymbols") private var recent = ""

    /// Characters with names, which look alike or not at all.
    private static let special: [(symbol: String, name: LocalizedStringKey)] = [
        ("\u{2014}", "Symbol.EmDash"), ("\u{2013}", "Symbol.EnDash"), ("\u{00A0}", "Symbol.NonBreakingSpace"),
        ("\u{2011}", "Symbol.NonBreakingHyphen"), ("\u{00AD}", "Symbol.OptionalHyphen"), ("\u{2026}", "Symbol.Ellipsis"),
        ("\u{00A9}", "Symbol.Copyright"), ("\u{00AE}", "Symbol.Registered"), ("\u{2122}", "Symbol.Trademark"),
        ("\u{00A7}", "Symbol.Section"), ("\u{00B6}", "Symbol.Paragraph"), ("\u{00B0}", "Symbol.Degree"),
    ]

    private static let groups: [(title: LocalizedStringKey, symbols: String)] = [
        ("Symbol.Group.Punctuation", "“”‘’«»‹›•·†‡‰′″¡¿"),
        ("Symbol.Group.Math", "±×÷≠≈≤≥∞√∑∏∫∂∆∇∈∉∩∪⊂⊃∀∃¬∧∨⁰¹²³⁴⁵⁶⁷⁸⁹½⅓¼¾"),
        ("Symbol.Group.Arrows", "←→↑↓↔↕⇐⇒⇑⇓⇔↗↘↙↖"),
        ("Symbol.Group.Greek", "αβγδεζηθικλμνξοπρστυφχψωΓΔΘΛΞΠΣΦΨΩ"),
        ("Symbol.Group.Currency", "€£¥¢₩₹₽₺฿₫"),
        ("Symbol.Group.Other", "✓✗★☆♠♣♥♦☐☑☒♪♫☀☁☂✉✎⌘⌥⇧"),
    ]

    private let columns = [GridItem(.adaptive(minimum: 40), spacing: 6)]

    var body: some View {
        Form {
            if !recent.isEmpty {
                Section("Symbol.Recent") { grid(recent) }
            }
            Section("Symbol.Special") {
                ForEach(Self.special, id: \.symbol) { item in
                    Button { insert(item.symbol) } label: {
                        HStack {
                            Text(item.name).foregroundStyle(Color.primary)
                            Spacer()
                            Text(item.symbol == "\u{00A0}" ? "°" : item.symbol)
                                .foregroundStyle(item.symbol == "\u{00A0}" ? .clear : .secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(Self.groups, id: \.symbols) { group in
                Section(group.title) { grid(group.symbols) }
            }
        }
        .formStyle(.grouped)
    }

    private func grid(_ symbols: String) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Button { insert(String(symbol)) } label: {
                    Text(String(symbol))
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(symbol))
            }
        }
        .padding(.vertical, 4)
    }

    private func insert(_ symbol: String) {
        state.controller?.insertSymbol(symbol)
        // The last sixteen used, the latest first.
        let printable = symbol == "\u{00A0}" || symbol == "\u{00AD}" ? "" : symbol
        recent = String((printable + recent.replacingOccurrences(of: printable, with: "")).prefix(16))
    }
}
