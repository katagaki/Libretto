import SwiftUI

/// A quiet wash of the app icon's blue across the document browser's top
/// area: a pale, paper-like tint in light mode and a deep ink in dark mode.
struct LaunchBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.accentColor
            .mix(with: colorScheme == .dark ? .black : .white, by: colorScheme == .dark ? 0.78 : 0.9)
            .ignoresSafeArea()
    }
}

/// Lines of text set faintly across the top area, drawn like the lines in the
/// app icon: rounded bars in ragged-right paragraphs, as though the top area
/// were a page of type, with a picture set inline that the opening paragraph
/// wraps around.
struct LaunchText: View {
    var geometry: DocumentLaunchGeometryProxy
    @Environment(\.colorScheme) private var colorScheme

    private let lineHeight: CGFloat = 8
    private let leading: CGFloat = 22
    private let margin: CGFloat = 24
    private let gutter: CGFloat = 14

    var body: some View {
        // The title's frame runs on under the browser; the type stops short of it.
        let height = geometry.titleViewFrame.minY + geometry.titleViewFrame.height * 0.6

        let ink = colorScheme == .dark ? Color.white.opacity(0.07) : Color.accentColor.opacity(0.1)

        Canvas { context, size in
            let measure = min(size.width - margin * 2, 640)
            let left = (size.width - measure) / 2
            var y = margin
            var line = 0
            var picture = CGRect.null
            while y < size.height {
                // A paragraph runs a few lines and ends on a short one.
                let length = Self.paragraphLengths[line % Self.paragraphLengths.count]
                // The picture sits at the start of the opening paragraph.
                if line == 0 {
                    let height = leading * CGFloat(Self.pictureLines) - (leading - lineHeight)
                    picture = CGRect(x: left, y: y, width: min(height * 4 / 3, measure * 0.45), height: height)
                    drawPicture(in: picture, context: context, ink: ink)
                }
                for index in 0..<length where y < size.height {
                    let fraction = index == length - 1
                        ? Self.lastLineWidths[line % Self.lastLineWidths.count]
                        : Self.lineWidths[(line + index) % Self.lineWidths.count]
                    // Lines beside the picture start past it and run to the same right edge.
                    let start = y < picture.maxY ? picture.maxX + gutter : left
                    let width = (left + measure - start) * fraction
                    let bar = CGRect(x: start, y: y, width: width, height: lineHeight)
                    context.fill(Path(roundedRect: bar, cornerRadius: lineHeight / 2), with: .color(ink))
                    y += leading
                }
                y += leading * 0.6
                line += length
            }
        }
        // Fade the type out before it reaches the browser.
        .mask {
            LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: geometry.frame.width, height: max(height, 0))
        .position(x: geometry.frame.midX, y: max(height, 0) / 2)
        .accessibilityHidden(true)
    }

    /// A landscape placeholder in the same faint ink: a frame, a sun and two hills.
    private func drawPicture(in frame: CGRect, context: GraphicsContext, ink: Color) {
        context.fill(Path(roundedRect: frame, cornerRadius: 6), with: .color(ink))

        let sun = frame.width * 0.12
        context.fill(Path(ellipseIn: CGRect(x: frame.maxX - frame.width * 0.3, y: frame.minY + frame.height * 0.18,
                                            width: sun, height: sun)), with: .color(ink))

        var hills = Path()
        hills.move(to: CGPoint(x: frame.minX, y: frame.maxY))
        hills.addLine(to: CGPoint(x: frame.minX, y: frame.maxY - frame.height * 0.2))
        hills.addLine(to: CGPoint(x: frame.minX + frame.width * 0.35, y: frame.minY + frame.height * 0.4))
        hills.addLine(to: CGPoint(x: frame.minX + frame.width * 0.6, y: frame.maxY - frame.height * 0.3))
        hills.addLine(to: CGPoint(x: frame.minX + frame.width * 0.75, y: frame.maxY - frame.height * 0.45))
        hills.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - frame.height * 0.15))
        hills.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        hills.closeSubpath()
        var context = context
        context.clip(to: Path(roundedRect: frame, cornerRadius: 6))
        context.fill(hills, with: .color(ink))
    }

    private static let pictureLines = 5
    private static let paragraphLengths = [4, 3, 5, 2, 4]
    private static let lineWidths: [CGFloat] = [1, 0.97, 1, 0.94, 0.99, 0.96]
    private static let lastLineWidths: [CGFloat] = [0.58, 0.36, 0.72, 0.45, 0.64]
}
