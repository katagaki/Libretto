import Foundation

/// Reads the drawings that are not pictures — shapes and text boxes, charts,
/// SmartArt diagrams — into descriptions Libretto can draw.
enum DrawingObjectReader {
    static let shapeURI = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let diagramURI = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    static let diagramDrawingType = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"

    /// The parts a drawing may refer to: charts' and diagrams'.
    struct Package {
        var parts: [String: Data]
        var relationships: [String: DocumentPackage.Relationship]
        var documentPath: String

        func part(_ id: String) -> XMLElement? {
            guard let relationship = relationships[id], !relationship.isExternal,
                  let data = parts[DOCXPaths.resolve(relationship.target, relativeTo: documentPath)] else { return nil }
            return try? XMLLite.parse(data)
        }
    }

    /// The object an `wp:inline` or `wp:anchor` holds, if it is one Libretto can draw.
    static func object(in container: XMLElement, package: Package) -> DrawingObject? {
        guard let data = descendant("graphicData", in: container) else { return nil }
        switch data.attribute("uri") {
        case shapeURI?:
            return data.firstChild(named: "wsp").map { .shape(shape($0)) }
        case chartURI?:
            guard let id = data.firstChild(named: "chart")?.attribute("id"), let chart = package.part(id) else { return nil }
            return self.chart(chart).map { .chart($0) }
        case diagramURI?:
            // The diagram's data part names the drawing Word last made of it, which is what is drawn.
            guard let model = data.firstChild(named: "relIds")?.attribute("dm"), let dataPart = package.part(model),
                  let drawingID = descendant("dataModelExt", in: dataPart)?.attribute("relId"),
                  let drawing = package.part(drawingID) else { return nil }
            let shapes = descendants("sp", in: drawing).map(diagramShape)
            return shapes.isEmpty ? nil : .diagram(shapes)
        default:
            return nil
        }
    }

    // MARK: - Shapes

    static func shape(_ wsp: XMLElement) -> ShapeSpec {
        var shape = ShapeSpec()
        let properties = wsp.firstChild(named: "spPr")
        let style = wsp.firstChild(named: "style")
        read(properties: properties, style: style, into: &shape)
        if let content = descendant("txbxContent", in: wsp) {
            shape.isTextBox = true
            shape.text = content.children(named: "p").map { HeaderFooterReader.plainText(of: $0) }.joined(separator: "\n")
            if let rPr = descendant("rPr", in: content) {
                shape.textColorHex = rPr.firstChild(named: "color")?.attribute("val").flatMap { $0 == "auto" ? nil : $0.uppercased() }
                shape.fontSize = rPr.firstChild(named: "sz")?.attribute("val").flatMap(Double.init).map { $0 / 2 }
            }
        }
        shape.originalText = shape.text
        return shape
    }

    private static func diagramShape(_ sp: XMLElement) -> ShapeSpec {
        var shape = ShapeSpec()
        let properties = sp.firstChild(named: "spPr")
        read(properties: properties, style: sp.firstChild(named: "style"), into: &shape)
        if let transform = properties?.firstChild(named: "xfrm"),
           let offset = transform.firstChild(named: "off"), let extent = transform.firstChild(named: "ext") {
            func points(_ element: XMLElement, _ name: String) -> Double { (Double(element.attribute(name) ?? "") ?? 0) / 12_700 }
            shape.frame = ShapeFrame(
                x: points(offset, "x"), y: points(offset, "y"), width: points(extent, "cx"), height: points(extent, "cy")
            )
        }
        if let body = sp.firstChild(named: "txBody") {
            shape.text = body.children(named: "p").map { paragraph in
                descendants("t", in: paragraph).map(\.text).joined()
            }.joined(separator: "\n")
            if let run = descendant("rPr", in: body) {
                shape.fontSize = run.attribute("sz").flatMap(Double.init).map { $0 / 100 }
                shape.textColorHex = color(in: run.firstChild(named: "solidFill"))
            }
        }
        shape.textColorHex = shape.textColorHex ?? (shape.fillHex == nil ? "000000" : "FFFFFF")
        shape.originalText = shape.text
        return shape
    }

    /// Fill and line, from the shape's own properties, else its style's theme references.
    private static func read(properties: XMLElement?, style: XMLElement?, into shape: inout ShapeSpec) {
        shape.geometry = properties?.firstChild(named: "prstGeom")?.attribute("prst") ?? "rect"
        if properties?.firstChild(named: "noFill") != nil {
            shape.fillHex = nil
        } else if let fill = properties?.firstChild(named: "solidFill") {
            shape.fillHex = color(in: fill)
        } else if let reference = style?.firstChild(named: "fillRef") {
            shape.fillHex = color(in: reference)
        }
        if let line = properties?.firstChild(named: "ln") {
            if let width = line.attribute("w").flatMap(Double.init) { shape.lineWidth = width / 12_700 }
            if line.firstChild(named: "noFill") != nil {
                shape.lineHex = nil
            } else if let fill = line.firstChild(named: "solidFill") {
                shape.lineHex = color(in: fill)
            } else if let reference = style?.firstChild(named: "lnRef") {
                shape.lineHex = color(in: reference)
            }
        } else if let reference = style?.firstChild(named: "lnRef") {
            shape.lineHex = color(in: reference)
        }
        if let font = style?.firstChild(named: "fontRef") { shape.textColorHex = color(in: font) }
    }

    /// The Office theme's colours, which shapes refer to by role.
    static let themeColors: [String: String] = [
        "accent1": "4472C4", "accent2": "ED7D31", "accent3": "A5A5A5", "accent4": "FFC000", "accent5": "5B9BD5",
        "accent6": "70AD47", "dk1": "000000", "lt1": "FFFFFF", "dk2": "44546A", "lt2": "E7E6E6", "tx1": "000000",
        "bg1": "FFFFFF", "tx2": "44546A", "bg2": "E7E6E6", "hlink": "0563C1", "folHlink": "954F72",
    ]

    /// The colour a fill or reference holds: an RGB value, a theme colour, or a system colour, with any shading applied.
    static func color(in element: XMLElement?) -> String? {
        guard let element else { return nil }
        for child in element.children {
            var base: String?
            switch child.name {
            case "srgbClr": base = child.attribute("val")
            case "schemeClr": base = child.attribute("val").flatMap { themeColors[$0] }
            case "sysClr": base = child.attribute("lastClr")
            case "prstClr": base = ["black": "000000", "white": "FFFFFF", "red": "FF0000", "blue": "0000FF", "green": "00FF00"][child.attribute("val") ?? ""]
            default: continue
            }
            guard let hex = base?.uppercased() else { continue }
            return adjusted(hex, by: child)
        }
        return nil
    }

    /// `a:lumMod` and `a:lumOff`, `a:tint` and `a:shade`, as near as RGB comes.
    private static func adjusted(_ hex: String, by element: XMLElement) -> String {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return hex }
        var red = Double((value >> 16) & 0xFF) / 255
        var green = Double((value >> 8) & 0xFF) / 255
        var blue = Double(value & 0xFF) / 255
        func percent(_ name: String) -> Double? {
            element.firstChild(named: name)?.attribute("val").flatMap(Double.init).map { $0 / 100_000 }
        }
        let modulation = percent("lumMod") ?? 1
        let offset = percent("lumOff") ?? 0
        red = red * modulation + offset
        green = green * modulation + offset
        blue = blue * modulation + offset
        if let tint = percent("tint") {
            red += (1 - red) * (1 - tint)
            green += (1 - green) * (1 - tint)
            blue += (1 - blue) * (1 - tint)
        }
        if let shade = percent("shade") {
            red *= shade
            green *= shade
            blue *= shade
        }
        func byte(_ component: Double) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    // MARK: - Charts

    static func chart(_ root: XMLElement) -> ChartSpec? {
        guard let plot = descendant("plotArea", in: root) else { return nil }
        let kinds: [(String, ChartSpec.Kind)] = [
            ("barChart", .column), ("bar3DChart", .column), ("lineChart", .line), ("line3DChart", .line),
            ("areaChart", .area), ("pieChart", .pie), ("pie3DChart", .pie), ("doughnutChart", .doughnut),
            ("scatterChart", .scatter),
        ]
        guard let (element, kind) = kinds.lazy.compactMap({ name, kind in plot.firstChild(named: name).map { ($0, kind) } }).first
        else { return nil }
        var chart = ChartSpec(kind: kind)
        if kind == .column, element.firstChild(named: "barDir")?.attribute("val") == "bar" { chart.kind = .bar }
        let grouping = element.firstChild(named: "grouping")?.attribute("val") ?? ""
        chart.isStacked = grouping == "stacked" || grouping == "percentStacked"
        if let title = descendant("title", in: root) {
            let text = descendants("t", in: title).map(\.text).joined()
            chart.title = text.isEmpty ? nil : text
        }
        for series in element.children(named: "ser") {
            let name = series.firstChild(named: "tx").map { descendants("v", in: $0).map(\.text).joined() } ?? ""
            let values = points(in: series.firstChild(named: "val") ?? series.firstChild(named: "yVal"))
                .map { Double($0) ?? 0 }
            let color = series.firstChild(named: "spPr").flatMap { color(in: $0.firstChild(named: "solidFill")) }
            chart.series.append(ChartSpec.Series(name: name, values: values, colorHex: color))
            if chart.categories.isEmpty {
                chart.categories = points(in: series.firstChild(named: "cat") ?? series.firstChild(named: "xVal"))
            }
        }
        return chart.series.isEmpty ? nil : chart
    }

    /// A cache's points, in their order, gaps left empty.
    private static func points(in element: XMLElement?) -> [String] {
        guard let element, let cache = descendant("numCache", in: element) ?? descendant("strCache", in: element) else { return [] }
        let count = cache.firstChild(named: "ptCount")?.attribute("val").flatMap { Int($0) } ?? 0
        var result = Array(repeating: "", count: count)
        for point in cache.children(named: "pt") {
            guard let index = point.attribute("idx").flatMap({ Int($0) }) else { continue }
            let value = point.firstChild(named: "v")?.text ?? ""
            if index < result.count { result[index] = value } else { result.append(value) }
        }
        return result
    }

    // MARK: - Helpers

    static func descendant(_ name: String, in element: XMLElement) -> XMLElement? {
        for child in element.children {
            if child.name == name { return child }
            if let found = descendant(name, in: child) { return found }
        }
        return nil
    }

    static func descendants(_ name: String, in element: XMLElement) -> [XMLElement] {
        element.children.flatMap { child in (child.name == name ? [child] : []) + descendants(name, in: child) }
    }
}
