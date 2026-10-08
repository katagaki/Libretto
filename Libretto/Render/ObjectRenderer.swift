import UIKit

/// Draws shapes, text boxes, charts and SmartArt diagrams as pictures, for
/// the pages, the reader and the PDF to show.
enum ObjectRenderer {
    static func image(for object: DrawingObject, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let canvas = CGSize(width: max(1, size.width), height: max(1, size.height))
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: canvas)
            switch object {
            case .shape(let shape):
                draw(shape, in: bounds, context: context.cgContext)
            case .diagram(let shapes):
                drawDiagram(shapes, in: bounds, context: context.cgContext)
            case .chart(let chart):
                ChartDrawing(chart: chart, bounds: bounds).draw()
            }
        }
    }

    static func color(_ hex: String?, fallback: UIColor = .clear) -> UIColor {
        guard let hex, hex.count == 6, let value = Int(hex, radix: 16) else { return fallback }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    }

    // MARK: - Shapes

    static func draw(_ shape: ShapeSpec, in rect: CGRect, context: CGContext) {
        let inset = rect.insetBy(dx: shape.lineWidth / 2 + 0.5, dy: shape.lineWidth / 2 + 0.5)
        let path = self.path(shape.geometry, in: inset)
        if let fill = shape.fillHex {
            color(fill).setFill()
            path.fill()
        }
        if let line = shape.lineHex {
            color(line).setStroke()
            path.lineWidth = max(0.5, shape.lineWidth)
            path.stroke()
        }
        guard !shape.text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = shape.isTextBox ? .natural : .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: shape.fontSize ?? 11),
            .foregroundColor: color(shape.textColorHex, fallback: shape.isTextBox || shape.fillHex == nil ? .black : .white),
            .paragraphStyle: style,
        ]
        let text = NSAttributedString(string: shape.text, attributes: attributes)
        let area = inset.insetBy(dx: 7, dy: 4)
        let height = ceil(text.boundingRect(with: CGSize(width: area.width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        // A text box's text runs from the top; a shape's sits in its middle.
        let top = shape.isTextBox ? area.minY : area.midY - min(height, area.height) / 2
        text.draw(with: CGRect(x: area.minX, y: top, width: area.width, height: min(height, area.height)),
                  options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
    }

    /// A preset geometry's outline, as near as these come to Word's.
    static func path(_ geometry: String, in rect: CGRect) -> UIBezierPath {
        let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
        func polygon(_ points: [(CGFloat, CGFloat)]) -> UIBezierPath {
            let path = UIBezierPath()
            for (index, point) in points.enumerated() {
                let location = CGPoint(x: x + w * point.0, y: y + h * point.1)
                if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
            }
            path.close()
            return path
        }
        switch geometry {
        case "roundRect", "flowChartAlternateProcess", "wedgeRoundRectCallout":
            return UIBezierPath(roundedRect: rect, cornerRadius: min(w, h) * 0.16)
        case "ellipse", "flowChartConnector", "donut", "cloud", "wedgeEllipseCallout":
            return UIBezierPath(ovalIn: rect)
        case "triangle", "flowChartExtract":
            return polygon([(0.5, 0), (1, 1), (0, 1)])
        case "rtTriangle":
            return polygon([(0, 0), (1, 1), (0, 1)])
        case "diamond", "flowChartDecision":
            return polygon([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])
        case "parallelogram", "flowChartInputOutput":
            return polygon([(0.25, 0), (1, 0), (0.75, 1), (0, 1)])
        case "trapezoid":
            return polygon([(0.2, 0), (0.8, 0), (1, 1), (0, 1)])
        case "pentagon", "homePlate":
            return geometry == "homePlate" ? polygon([(0, 0), (0.8, 0), (1, 0.5), (0.8, 1), (0, 1)])
                : polygon([(0.5, 0), (1, 0.38), (0.81, 1), (0.19, 1), (0, 0.38)])
        case "hexagon":
            return polygon([(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)])
        case "octagon":
            return polygon([(0.3, 0), (0.7, 0), (1, 0.3), (1, 0.7), (0.7, 1), (0.3, 1), (0, 0.7), (0, 0.3)])
        case "chevron":
            return polygon([(0, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0, 1), (0.25, 0.5)])
        case "rightArrow":
            return polygon([(0, 0.25), (0.6, 0.25), (0.6, 0), (1, 0.5), (0.6, 1), (0.6, 0.75), (0, 0.75)])
        case "leftArrow":
            return polygon([(1, 0.25), (0.4, 0.25), (0.4, 0), (0, 0.5), (0.4, 1), (0.4, 0.75), (1, 0.75)])
        case "upArrow":
            return polygon([(0.25, 1), (0.25, 0.4), (0, 0.4), (0.5, 0), (1, 0.4), (0.75, 0.4), (0.75, 1)])
        case "downArrow":
            return polygon([(0.25, 0), (0.25, 0.6), (0, 0.6), (0.5, 1), (1, 0.6), (0.75, 0.6), (0.75, 0)])
        case "plus", "mathPlus":
            return polygon([(0.35, 0), (0.65, 0), (0.65, 0.35), (1, 0.35), (1, 0.65), (0.65, 0.65), (0.65, 1),
                            (0.35, 1), (0.35, 0.65), (0, 0.65), (0, 0.35), (0.35, 0.35)])
        case "star5":
            let points = (0..<10).map { index -> (CGFloat, CGFloat) in
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                let radius: CGFloat = index % 2 == 0 ? 0.5 : 0.2
                return (0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius + 0.03)
            }
            return polygon(points)
        case "line", "straightConnector1", "bentConnector3", "curvedConnector3":
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        default:
            return UIBezierPath(rect: rect)
        }
    }

    // MARK: - Diagrams

    private static func drawDiagram(_ shapes: [ShapeSpec], in bounds: CGRect, context: CGContext) {
        let frames = shapes.compactMap(\.frame)
        let width = frames.map { $0.x + $0.width }.max() ?? 1
        let height = frames.map { $0.y + $0.height }.max() ?? 1
        let scale = min(bounds.width / max(width, 1), bounds.height / max(height, 1))
        for shape in shapes {
            guard let frame = shape.frame else { continue }
            var scaled = shape
            scaled.fontSize = (shape.fontSize ?? 11) * scale
            draw(scaled, in: CGRect(x: frame.x * scale, y: frame.y * scale, width: frame.width * scale, height: frame.height * scale),
                 context: context)
        }
    }
}

/// A chart drawn from its cached values: title, plot, axes and legend.
private struct ChartDrawing {
    let chart: ChartSpec
    let bounds: CGRect

    static let palette = ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47", "264478", "9E480E"]

    private let labelFont = UIFont.systemFont(ofSize: 8)

    private func seriesColor(_ index: Int) -> UIColor {
        ObjectRenderer.color(chart.series[index].colorHex ?? Self.palette[index % Self.palette.count])
    }

    private func label(_ text: String, at point: CGPoint, alignment: NSTextAlignment = .center, width: CGFloat = 60) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: UIColor.darkGray, .paragraphStyle: style]
        let x = alignment == .center ? point.x - width / 2 : alignment == .right ? point.x - width : point.x
        (text as NSString).draw(in: CGRect(x: x, y: point.y, width: width, height: 11), withAttributes: attributes)
    }

    func draw() {
        UIColor.white.setFill()
        UIRectFill(bounds)
        var area = bounds.insetBy(dx: 8, dy: 8)
        if let title = chart.title {
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.black]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: CGPoint(x: area.midX - size.width / 2, y: area.minY), withAttributes: attributes)
            area.origin.y += size.height + 6
            area.size.height -= size.height + 6
        }
        let isRound = chart.kind == .pie || chart.kind == .doughnut
        let legend = isRound ? chart.categories : chart.series.map(\.name)
        if legend.count > 1 || isRound {
            drawLegend(legend, in: CGRect(x: area.minX, y: area.maxY - 12, width: area.width, height: 12), round: isRound)
            area.size.height -= 18
        }
        if isRound {
            drawPie(in: area)
        } else {
            drawAxes(in: area)
        }
    }

    private func drawLegend(_ names: [String], in rect: CGRect, round: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: UIColor.darkGray]
        let widths = names.map { ($0 as NSString).size(withAttributes: attributes).width + 16 }
        var x = rect.midX - widths.reduce(0, +) / 2
        for (index, name) in names.enumerated() {
            let color = round ? ObjectRenderer.color(Self.palette[index % Self.palette.count]) : seriesColor(index)
            color.setFill()
            UIRectFill(CGRect(x: x, y: rect.minY + 2, width: 7, height: 7))
            (name as NSString).draw(at: CGPoint(x: x + 10, y: rect.minY), withAttributes: attributes)
            x += widths[index]
        }
    }

    private func drawPie(in area: CGRect) {
        let values = chart.series.first?.values.map { max(0, $0) } ?? []
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let radius = min(area.width, area.height) / 2
        let center = CGPoint(x: area.midX, y: area.midY)
        var angle = -CGFloat.pi / 2
        for (index, value) in values.enumerated() {
            let sweep = CGFloat(value / total) * 2 * .pi
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: true)
            path.close()
            ObjectRenderer.color(Self.palette[index % Self.palette.count]).setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = 1
            path.stroke()
            angle += sweep
        }
        if chart.kind == .doughnut {
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - radius / 2, y: center.y - radius / 2, width: radius, height: radius)).fill()
        }
    }

    /// A round number of steps from zero to past the largest value.
    private func scale(for maximum: Double) -> (top: Double, step: Double) {
        guard maximum > 0 else { return (1, 0.2) }
        let rough = maximum / 5
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? rough
        return (ceil(maximum / step) * step, step)
    }

    private func drawAxes(in area: CGRect) {
        let count = max(chart.categories.count, chart.series.map(\.values.count).max() ?? 0)
        guard count > 0 else { return }
        let maximum = chart.isStacked
            ? (0..<count).map { index in chart.series.reduce(0) { $0 + max(0, $1.values.indices.contains(index) ? $1.values[index] : 0) } }.max() ?? 0
            : chart.series.flatMap(\.values).max() ?? 0
        let (top, step) = scale(for: maximum)
        let horizontal = chart.kind == .bar
        let plot = CGRect(x: area.minX + (horizontal ? 50 : 28), y: area.minY + 4,
                          width: area.width - (horizontal ? 54 : 32), height: area.height - 18)
        // Gridlines and their values.
        UIColor(white: 0.85, alpha: 1).setStroke()
        var value = 0.0
        while value <= top + step / 2 {
            let fraction = CGFloat(value / top)
            let path = UIBezierPath()
            if horizontal {
                let x = plot.minX + plot.width * fraction
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
                label(Self.format(value), at: CGPoint(x: x, y: plot.maxY + 3))
            } else {
                let y = plot.maxY - plot.height * fraction
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
                label(Self.format(value), at: CGPoint(x: plot.minX - 3, y: y - 5), alignment: .right, width: 26)
            }
            path.lineWidth = 0.5
            path.stroke()
            value += step
        }
        let band = (horizontal ? plot.height : plot.width) / CGFloat(count)
        for index in 0..<count where index < chart.categories.count {
            if horizontal {
                label(chart.categories[index], at: CGPoint(x: plot.minX - 3, y: plot.minY + band * (CGFloat(index) + 0.5) - 5),
                      alignment: .right, width: 46)
            } else {
                label(chart.categories[index], at: CGPoint(x: plot.minX + band * (CGFloat(index) + 0.5), y: plot.maxY + 3),
                      width: band)
            }
        }
        func position(_ value: Double) -> CGFloat { CGFloat(value / top) }
        switch chart.kind {
        case .column, .bar:
            let seriesCount = CGFloat(chart.isStacked ? 1 : chart.series.count)
            let barWidth = band * 0.7 / max(1, seriesCount)
            var stacks = Array(repeating: 0.0, count: count)
            for (seriesIndex, series) in chart.series.enumerated() {
                seriesColor(seriesIndex).setFill()
                for (index, value) in series.values.enumerated() where index < count {
                    let base = chart.isStacked ? stacks[index] : 0
                    let offset = chart.isStacked ? 0 : CGFloat(seriesIndex) * barWidth
                    let start = band * CGFloat(index) + band * 0.15 + offset
                    let rect = horizontal
                        ? CGRect(x: plot.minX + plot.width * position(base), y: plot.minY + start,
                                 width: plot.width * position(max(0, value)), height: barWidth)
                        : CGRect(x: plot.minX + start, y: plot.maxY - plot.height * position(base + max(0, value)),
                                 width: barWidth, height: plot.height * position(max(0, value)))
                    UIRectFill(rect)
                    stacks[index] += max(0, value)
                }
            }
        case .line, .area, .scatter:
            for (seriesIndex, series) in chart.series.enumerated() {
                let points = series.values.enumerated().map { index, value in
                    CGPoint(x: plot.minX + band * (CGFloat(index) + 0.5), y: plot.maxY - plot.height * position(value))
                }
                guard let first = points.first else { continue }
                let path = UIBezierPath()
                path.move(to: first)
                points.dropFirst().forEach(path.addLine)
                let color = seriesColor(seriesIndex)
                if chart.kind == .area, let last = points.last {
                    path.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                    path.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                    path.close()
                    color.withAlphaComponent(0.65).setFill()
                    path.fill()
                } else if chart.kind == .line {
                    color.setStroke()
                    path.lineWidth = 2
                    path.stroke()
                }
                color.setFill()
                for point in points where chart.kind != .area {
                    UIBezierPath(ovalIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
                }
            }
        case .pie, .doughnut:
            break
        }
        UIColor.gray.setStroke()
        let axis = UIBezierPath()
        axis.move(to: CGPoint(x: plot.minX, y: plot.minY))
        axis.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        axis.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        axis.lineWidth = 0.75
        axis.stroke()
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
