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

/// Lines of text set faintly behind the app's name, drawn like the lines in
/// the app icon: rounded bars in ragged-right paragraphs, as though the top
/// area were a page of type.
struct LaunchText: View {
    var geometry: DocumentLaunchGeometryProxy
    @Environment(\.colorScheme) private var colorScheme

    private let lineHeight: CGFloat = 8
    private let leading: CGFloat = 22
    private let margin: CGFloat = 24

    var body: some View {
        // The title's frame runs on under the browser; the type stops short of it.
        let height = geometry.titleViewFrame.minY + geometry.titleViewFrame.height * 0.6

        let ink = colorScheme == .dark ? Color.white.opacity(0.07) : Color.accentColor.opacity(0.1)

        Canvas { context, size in
            let measure = min(size.width - margin * 2, 640)
            let left = (size.width - measure) / 2
            var y = margin
            var line = 0
            while y < size.height {
                // A paragraph runs a few lines and ends on a short one.
                let length = Self.paragraphLengths[line % Self.paragraphLengths.count]
                for index in 0..<length where y < size.height {
                    let fraction = index == length - 1
                        ? Self.lastLineWidths[line % Self.lastLineWidths.count]
                        : Self.lineWidths[(line + index) % Self.lineWidths.count]
                    let bar = CGRect(x: left, y: y, width: measure * fraction, height: lineHeight)
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

    private static let paragraphLengths = [4, 3, 5, 2, 4]
    private static let lineWidths: [CGFloat] = [1, 0.97, 1, 0.94, 0.99, 0.96]
    private static let lastLineWidths: [CGFloat] = [0.58, 0.36, 0.72, 0.45, 0.64]
}
