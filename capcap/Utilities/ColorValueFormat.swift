import AppKit

enum ColorValueFormat: String, CaseIterable {
    case hex, rgb, hsl

    var title: String { rawValue.uppercased() }

    func string(from hex: String) -> String {
        guard let hex = ClipboardColorParser.normalizedHex(from: hex),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return hex }
        let r = Int((value >> 16) & 255)
        let g = Int((value >> 8) & 255)
        let b = Int(value & 255)
        switch self {
        case .hex: return hex
        case .rgb: return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let channels = [Double(r), Double(g), Double(b)].map { $0 / 255 }
            let high = channels.max()!, low = channels.min()!
            let delta = high - low
            let lightness = (high + low) / 2
            var hue = 0.0
            var saturation = 0.0
            if delta > 0 {
                saturation = delta / (1 - abs(2 * lightness - 1))
                if high == channels[0] {
                    hue = ((channels[1] - channels[2]) / delta).truncatingRemainder(dividingBy: 6)
                } else if high == channels[1] {
                    hue = (channels[2] - channels[0]) / delta + 2
                } else {
                    hue = (channels[0] - channels[1]) / delta + 4
                }
                hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
            }
            return "hsl(\(Int(hue.rounded()) % 360), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
        }
    }

    static func color(from hex: String) -> NSColor? {
        guard let normalized = ClipboardColorParser.normalizedHex(from: hex),
              let value = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

enum ToolbarSizeOption: String, CaseIterable {
    case small, medium, large
    var title: String {
        switch self {
        case .small: return L10n.sizeSmall
        case .medium: return L10n.sizeMedium
        case .large: return L10n.sizeLarge
        }
    }
    var iconPoints: CGFloat {
        switch self { case .small: return 13; case .medium: return 15; case .large: return 18 }
    }
    var buttonPoints: CGFloat {
        switch self { case .small: return 32; case .medium: return 40; case .large: return 46 }
    }
    var gap: CGFloat {
        switch self { case .small: return 3; case .medium: return 6; case .large: return 8 }
    }
    var endPadding: CGFloat {
        switch self { case .small: return 10; case .medium: return 15; case .large: return 18 }
    }
    var crossPadding: CGFloat {
        switch self { case .small: return 4; case .medium: return 6; case .large: return 8 }
    }
}
