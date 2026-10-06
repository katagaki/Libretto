import SwiftUI

/// Adapts document colours to the current appearance.
///
/// Document colours are stored exactly as authored, so a document written in
/// light mode is full of near-white shading and near-black text. Rather than
/// inverting everything — which would turn a brand red into cyan — this keeps
/// hue and saturation and only moves lightness, and only when it needs to:
///
/// - Near-greys (whitish/blackish) flip their lightness, so white paper becomes
///   dark paper and black ink becomes light ink.
/// - Saturated colours keep their identity and are nudged only far enough to
///   stay legible against the current background.
enum AdaptiveColor {
    /// Below this saturation a colour counts as "whitish or blackish".
    private static let achromaticThreshold = 0.14

    static func resolve(hex: String?, for scheme: ColorScheme, isText: Bool) -> Color? {
        guard let components = HSL(argbHex: hex) else { return nil }
        return Color(adjust(components, for: scheme, isText: isText))
    }

    /// Keep an authored text colour where it remains readable. A white label on
    /// a blue fill, for example, should not turn black just because white text
    /// on an unfilled dark sheet normally needs inverting.
    static func resolveText(hex: String?, on fillHex: String?, for scheme: ColorScheme) -> Color? {
        guard let text = HSL(argbHex: hex) else { return nil }
        let adapted = adjust(text, for: scheme, isText: true)
        guard scheme == .dark, let fill = HSL(argbHex: fillHex) else { return Color(adapted) }
        let background = adjust(fill, for: scheme, isText: false)
        if contrast(adapted, background) >= 4.5 { return Color(adapted) }

        var alternative = adapted
        if text.saturation < achromaticThreshold {
            alternative.lightness = text.lightness
        } else {
            alternative.lightness = background.lightness < 0.5 ? 0.85 : 0.15
        }
        return Color(contrast(alternative, background) > contrast(adapted, background)
            ? alternative : adapted)
    }

    private static func contrast(_ first: HSL, _ second: HSL) -> Double {
        let bright = max(first.luminance, second.luminance)
        let dark = min(first.luminance, second.luminance)
        return (bright + 0.05) / (dark + 0.05)
    }

    private static func adjust(_ color: HSL, for scheme: ColorScheme, isText: Bool) -> HSL {
        guard scheme == .dark else { return color }
        var result = color

        if color.saturation < achromaticThreshold {
            // Whitish and blackish: flip lightness, keeping any slight tint.
            result.lightness = 1 - color.lightness
            return result
        }

        // Saturated: preserve the hue, lift or drop only for contrast.
        if isText {
            result.lightness = max(color.lightness, 0.62)
            result.saturation = min(color.saturation, 0.85)
        } else {
            // Fills sit behind text, so they stay deep enough to read against.
            result.lightness = min(color.lightness, 0.34)
        }
        return result
    }
}

/// A minimal HSL representation, used only for appearance adaptation.
private struct HSL {
    var hue: Double
    var saturation: Double
    var lightness: Double
    var alpha: Double

    var luminance: Double {
        let (red, green, blue) = Color.rgb(from: self)
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    init?(argbHex hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 6 { text = "FF" + text }
        guard text.count == 8, let raw = UInt32(text, radix: 16) else { return nil }

        let red = Double((raw >> 16) & 0xFF) / 255
        let green = Double((raw >> 8) & 0xFF) / 255
        let blue = Double(raw & 0xFF) / 255
        alpha = Double((raw >> 24) & 0xFF) / 255

        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let span = highest - lowest
        lightness = (highest + lowest) / 2

        guard span > 0 else {
            hue = 0
            saturation = 0
            return
        }
        saturation = lightness > 0.5 ? span / (2 - highest - lowest) : span / (highest + lowest)

        let sector: Double
        switch highest {
        case red: sector = (green - blue) / span + (green < blue ? 6 : 0)
        case green: sector = (blue - red) / span + 2
        default: sector = (red - green) / span + 4
        }
        hue = sector / 6
    }
}

private extension Color {
    init(_ components: HSL) {
        let (red, green, blue) = Color.rgb(from: components)
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: components.alpha)
    }

    static func rgb(from components: HSL) -> (Double, Double, Double) {
        guard components.saturation > 0 else {
            return (components.lightness, components.lightness, components.lightness)
        }
        let q = components.lightness < 0.5
            ? components.lightness * (1 + components.saturation)
            : components.lightness + components.saturation - components.lightness * components.saturation
        let p = 2 * components.lightness - q

        func channel(_ offset: Double) -> Double {
            var t = components.hue + offset
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(1.0 / 3), channel(0), channel(-1.0 / 3))
    }
}

extension Color {
    /// Builds a colour from an OOXML "AARRGGBB" (or "RRGGBB") hex string.
    init?(argbHex hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 6 { text = "FF" + text }
        guard text.count == 8, let raw = UInt32(text, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((raw >> 16) & 0xFF) / 255,
            green: Double((raw >> 8) & 0xFF) / 255,
            blue: Double(raw & 0xFF) / 255,
            opacity: Double((raw >> 24) & 0xFF) / 255
        )
    }

    /// "AARRGGBB" representation, for round-tripping through OOXML.
    var argbHex: String? {
        #if canImport(UIKit)
        typealias PlatformColor = UIColor
        #else
        typealias PlatformColor = NSColor
        #endif
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if canImport(UIKit)
        guard PlatformColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #else
        guard let converted = PlatformColor(self).usingColorSpace(.sRGB) else { return nil }
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        let components = [alpha, red, green, blue].map { UInt8(max(0, min(1, $0)) * 255) }
        return components.map { String(format: "%02X", $0) }.joined()
    }
}

extension AdaptiveColor {
    /// The UIKit colour, for text drawn through TextKit.
    static func uiColor(hex: String?, for scheme: ColorScheme, isText: Bool) -> UIColor? {
        resolve(hex: hex, for: scheme, isText: isText).map(UIColor.init)
    }

    static func uiTextColor(hex: String?, on fillHex: String?, for scheme: ColorScheme) -> UIColor? {
        resolveText(hex: hex, on: fillHex, for: scheme).map(UIColor.init)
    }
}
