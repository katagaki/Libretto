import SwiftUI

/// The blue the document browser's top area is washed in: the app icon's
/// colour running down into a deeper indigo.
struct LaunchBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.mix(with: .white, by: 0.12), Color.accentColor.mix(with: .indigo, by: 0.55)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay {
            // A soft light falling from above, so the pages look lit.
            RadialGradient(colors: [.white.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// A fan of three pages set in the corner beside the app's name, drawn like
/// the page in the app icon: a sheet with its corner folded over and lines of
/// text set on it.
struct LaunchPages: View {
    var geometry: DocumentLaunchGeometryProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFanned = false

    var body: some View {
        let frame = geometry.frame
        let title = geometry.titleViewFrame
        // The title's frame runs from above the name down past the button;
        // the pages keep to its upper part, clear of the button.
        let top = frame.minY + 16
        let bottom = title.minY + title.height * 0.26
        let height = min(max(bottom - top, 0), 150)
        let width = height * 0.76

        ZStack {
            LaunchPage(lineCount: 5)
                .frame(width: width * 0.9, height: height * 0.9)
                .rotationEffect(.degrees(isFanned ? -16 : 0), anchor: .bottom)
                .offset(x: isFanned ? -width * 0.32 : 0, y: height * 0.05)
            LaunchPage(lineCount: 4)
                .frame(width: width * 0.9, height: height * 0.9)
                .rotationEffect(.degrees(isFanned ? 14 : 0), anchor: .bottom)
                .offset(x: isFanned ? width * 0.32 : 0, y: height * 0.05)
            LaunchPage(lineCount: 6, hasHeading: true)
                .frame(width: width, height: height)
        }
        .rotationEffect(.degrees(4))
        .position(x: frame.maxX - width * 0.95 - 12, y: bottom - height / 2)
        .opacity(height > 72 ? 1 : 0)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.3).delay(0.15)) {
                isFanned = true
            }
        }
    }
}

/// One sheet of paper with its top corner folded over.
struct LaunchPage: View {
    var lineCount: Int
    var hasHeading = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fold = size.width * 0.26
            let inset = size.width * 0.14
            let lineHeight = size.height * 0.035

            ZStack(alignment: .topLeading) {
                FoldedSheet(fold: fold)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                FoldedCorner(fold: fold)
                    .fill(Color.accentColor.mix(with: .white, by: 0.7))

                VStack(alignment: .leading, spacing: lineHeight * 1.5) {
                    if hasHeading {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: (size.width - inset * 2) * 0.55, height: lineHeight * 1.5)
                            .padding(.bottom, lineHeight * 0.5)
                    }
                    ForEach(0..<lineCount, id: \.self) { index in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: (size.width - inset * 2) * (index == lineCount - 1 ? 0.6 : 1),
                                   height: lineHeight)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.top, fold + lineHeight * 1.5)
            }
        }
        // Paper stays white whatever the appearance.
        .environment(\.colorScheme, .light)
    }
}

/// The outline of a sheet with its top-right corner cut away for the fold.
private struct FoldedSheet: Shape {
    var fold: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = rect.width * 0.06
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// The folded-over flap in the sheet's top-right corner.
private struct FoldedCorner: Shape {
    var fold: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = fold * 0.25
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addArc(tangent1End: CGPoint(x: rect.maxX - fold, y: rect.minY + fold),
                    tangent2End: CGPoint(x: rect.maxX - fold, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}
