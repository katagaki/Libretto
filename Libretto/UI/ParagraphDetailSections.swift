import SwiftUI

/// The paragraph panel's sections for page breaks, borders and shading,
/// and tab stops.
struct ParagraphDetailSections: View {
    @Bindable var state: EditorState

    private var format: SelectionFormat { state.selectionFormat }
    private var controller: DocumentTextController? { state.controller }

    var body: some View {
        Section("Paragraph.Section.Pagination") {
            flag("Paragraph.KeepWithNext", \.keepNext, isOn: format.keepNext)
            flag("Paragraph.KeepLinesTogether", \.keepLines, isOn: format.keepLines)
            flag("Paragraph.WidowControl", \.widowControl, isOn: format.widowControl)
            flag("Paragraph.PageBreakBefore", \.pageBreakBefore, isOn: format.pageBreakBefore)
        }

        Section("Paragraph.Section.Borders") {
            Picker("Paragraph.Borders", selection: Binding(
                get: { BorderPreset(format.borders) },
                set: { preset in controller?.setBorders(preset.borders(line: currentLine)) }
            )) {
                ForEach(BorderPreset.allCases) { preset in Text(preset.label).tag(preset) }
                if BorderPreset(format.borders) == .custom { Text("Paragraph.Borders.Custom").tag(BorderPreset.custom) }
            }
            .accessibilityIdentifier("borders")
            if format.borders != nil {
                Picker("Paragraph.BorderStyle", selection: Binding(
                    get: { currentLine.style },
                    set: { style in
                        var line = currentLine
                        line.style = style
                        line.size = style == "thick" ? 18 : max(4, line.size == 18 ? 4 : line.size)
                        restyleBorders(line)
                    }
                )) {
                    ForEach(Self.lineStyles, id: \.self) { style in
                        Text(LocalizedStringKey("Border.\(style)")).tag(style)
                    }
                }
                SystemColorSwatches(
                    role: .border,
                    selectedHex: currentLine.colorHex.map { "FF" + $0 },
                    customColor: Binding(
                        get: { Color(argbHex: currentLine.colorHex) ?? .primary },
                        set: { color in setBorderColor(color.argbHex) }
                    ),
                    onSelect: { setBorderColor($0.argbHex) },
                    onClear: { setBorderColor(nil) }
                )
            }
            LabeledContent("Paragraph.Shading") { EmptyView() }
            SystemColorSwatches(
                role: .fill,
                selectedHex: format.shadingHex.map { "FF" + $0 },
                customColor: Binding(
                    get: { Color(argbHex: format.shadingHex) ?? .clear },
                    set: { controller?.setShading($0.argbHex) }
                ),
                onSelect: { controller?.setShading($0.argbHex) },
                onClear: { controller?.setShading(nil) }
            )
        }

        Section {
            ForEach(Array(format.tabStops.enumerated()), id: \.offset) { index, stop in
                tabRow(stop, at: index)
            }
            Button("Paragraph.AddTab", systemImage: "plus") {
                let next = (format.tabStops.map(\.position).max() ?? 0) + 1440
                controller?.setTabStops(format.tabStops + [TabStop(position: next)])
            }
            .accessibilityIdentifier("addTab")
        } header: {
            Text("Paragraph.Section.Tabs")
        } footer: {
            Text("Paragraph.Tabs.Footer")
        }
    }

    private func flag(
        _ label: LocalizedStringKey, _ key: WritableKeyPath<ParagraphProperties, Bool?>, isOn: Bool
    ) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: { controller?.setParagraphFlag(key, $0) }))
    }

    // MARK: - Borders

    private static let lineStyles = ["single", "double", "dotted", "dashed", "thick"]

    /// The line the borders are drawn with now, or a plain one.
    private var currentLine: BorderLine {
        let borders = format.borders
        return borders?.top ?? borders?.bottom ?? borders?.left ?? borders?.right ?? BorderLine(style: "single", size: 4, space: 1)
    }

    private func restyleBorders(_ line: BorderLine) {
        guard var borders = format.borders else { return }
        for key in [\ParagraphBorders.top, \.left, \.bottom, \.right, \.between] where borders[keyPath: key] != nil {
            borders[keyPath: key] = line
        }
        controller?.setBorders(borders)
    }

    private func setBorderColor(_ argbHex: String?) {
        var line = currentLine
        line.colorHex = argbHex.map { String($0.suffix(6)).uppercased() }
        restyleBorders(line)
    }

    // MARK: - Tabs

    private func tabRow(_ stop: TabStop, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(
                Self.position(stop.position),
                onIncrement: { change(index) { $0.position += 180 } },
                onDecrement: { change(index) { $0.position = max(0, $0.position - 180) } }
            )
            HStack {
                Picker("Paragraph.Tab.Alignment", selection: Binding(
                    get: { stop.alignment },
                    set: { value in change(index) { $0.alignment = value } }
                )) {
                    ForEach([TabStop.Alignment.left, .center, .right, .decimal], id: \.self) { alignment in
                        Text(LocalizedStringKey("Tab.\(alignment.rawValue)")).tag(alignment)
                    }
                }
                .labelsHidden()
                Picker("Paragraph.Tab.Leader", selection: Binding(
                    get: { stop.leader ?? "none" },
                    set: { value in change(index) { $0.leader = value == "none" ? nil : value } }
                )) {
                    ForEach(["none", "dot", "hyphen", "underscore"], id: \.self) { leader in
                        Text(LocalizedStringKey("Leader.\(leader)")).tag(leader)
                    }
                }
                .labelsHidden()
                Spacer()
                Button(role: .destructive) {
                    var stops = format.tabStops
                    stops.remove(at: index)
                    controller?.setTabStops(stops)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Paragraph.RemoveTab")
            }
        }
    }

    private func change(_ index: Int, _ edit: (inout TabStop) -> Void) {
        var stops = format.tabStops
        guard stops.indices.contains(index) else { return }
        edit(&stops[index])
        controller?.setTabStops(stops)
    }

    /// Twips as a length in the reader's units.
    static func position(_ twips: Int) -> String {
        let inches = Measurement(value: Double(twips) / 1440, unit: UnitLength.inches)
        let length = Locale.current.measurementSystem == .us ? inches : inches.converted(to: .centimeters)
        return length.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                             numberFormatStyle: .number.precision(.fractionLength(0...2))))
    }
}

/// The border arrangements the panel offers.
enum BorderPreset: String, CaseIterable, Identifiable, Hashable {
    case none, box, top, bottom, topAndBottom, sides
    /// Any other arrangement, as read from a file.
    case custom

    static var allCases: [BorderPreset] { [.none, .box, .top, .bottom, .topAndBottom, .sides] }

    var id: String { rawValue }

    init(_ borders: ParagraphBorders?) {
        guard let borders, !borders.isEmpty else {
            self = .none
            return
        }
        let sides = (borders.top != nil, borders.bottom != nil, borders.left != nil, borders.right != nil)
        switch sides {
        case (true, true, true, true): self = .box
        case (true, false, false, false): self = .top
        case (false, true, false, false): self = .bottom
        case (true, true, false, false): self = .topAndBottom
        case (false, false, true, true): self = .sides
        default: self = .custom
        }
    }

    func borders(line: BorderLine) -> ParagraphBorders {
        switch self {
        case .none, .custom: return ParagraphBorders()
        case .box: return ParagraphBorders(top: line, left: line, bottom: line, right: line)
        case .top: return ParagraphBorders(top: line)
        case .bottom: return ParagraphBorders(bottom: line)
        case .topAndBottom: return ParagraphBorders(top: line, bottom: line)
        case .sides: return ParagraphBorders(left: line, right: line)
        }
    }

    var label: LocalizedStringKey { LocalizedStringKey("Paragraph.Borders.\(rawValue)") }
}
