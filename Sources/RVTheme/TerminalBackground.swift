import Foundation

/// Light or dark terminal background. `dark` is what rv assumed before it
/// could ask, and stays the answer whenever detection cannot say.
public enum TerminalBackground: String, Equatable, Sendable {
    case dark
    case light
}

/// `RV_THEME=dark|light|auto`. Unset or anything else is `automatic`.
public enum ThemePreference: Equatable, Sendable {
    case automatic
    case dark
    case light

    public static let environmentKey = "RV_THEME"

    public init(environment: [String: String]) {
        switch environment[Self.environmentKey]?.lowercased() {
        case "dark": self = .dark
        case "light": self = .light
        default: self = .automatic
        }
    }
}

/// An sRGB color with each channel in 0...1.
public struct TerminalColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// WCAG relative luminance (linear-light Y), 0...1.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// CIE L* perceived lightness, 0...100.
    public var perceivedLightness: Double {
        let y = relativeLuminance
        return y <= 216.0 / 24_389.0 ? y * 24_389.0 / 27.0 : pow(y, 1.0 / 3.0) * 116.0 - 16.0
    }

    /// Light above mid-grey lightness (L* 50), dark otherwise.
    public var background: TerminalBackground {
        perceivedLightness > 50 ? .light : .dark
    }
}

/// The OSC 11 background-color query and its reply grammar.
public enum BackgroundColorQuery {
    /// OSC 11 query, then primary device attributes (DA1). Nearly every
    /// terminal answers DA1, so its reply arriving without an OSC 11 reply
    /// before it means the terminal does not answer OSC 11, and the read
    /// can stop without waiting out the timeout.
    public static let request: [UInt8] = Array("\u{1B}]11;?\u{1B}\\\u{1B}[c".utf8)

    /// True once the DA1 reply (`ESC [ ? … c`) has arrived: nothing more
    /// is coming for this request.
    public static func isComplete(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0x1B, bytes[index + 1] == UInt8(ascii: "["), bytes[index + 2] == UInt8(ascii: "?") {
                var cursor = index + 3
                while cursor < bytes.count, bytes[cursor] == UInt8(ascii: ";") || (48...57).contains(bytes[cursor]) {
                    cursor += 1
                }
                if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "c") { return true }
            }
            index += 1
        }
        return false
    }

    /// The background color in an OSC 11 reply (`ESC ] 11 ; <spec>`
    /// ended by BEL, 7-bit ST, or 8-bit C1 ST), or nil when there is none
    /// or it does not parse.
    public static func parseReply(_ bytes: [UInt8]) -> TerminalColor? {
        let introducer = Array("\u{1B}]11;".utf8)
        guard bytes.count >= introducer.count,
            let start = (0...(bytes.count - introducer.count)).first(where: {
                Array(bytes[$0..<$0 + introducer.count]) == introducer
            })
        else { return nil }
        var payload: [UInt8] = []
        var index = start + introducer.count
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 || byte == 0x9C { return parseSpec(payload) }
            if byte == 0x1B {
                return index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\\") ? parseSpec(payload) : nil
            }
            payload.append(byte)
            index += 1
        }
        return nil
    }

    /// `rgb:R/G/B` or `rgba:R/G/B/A`, each channel one to four hex digits
    /// scaled by its own width (`f` and `ffff` are both full).
    public static func parseSpec(_ payload: [UInt8]) -> TerminalColor? {
        guard let text = String(bytes: payload, encoding: .ascii) else { return nil }
        let channels: [Substring]
        if text.hasPrefix("rgb:") {
            channels = text.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
            guard channels.count == 3 else { return nil }
        } else if text.hasPrefix("rgba:") {
            channels = text.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
            guard channels.count == 4 else { return nil }
        } else {
            return nil
        }
        let values = channels.prefix(3).compactMap(channel)
        guard values.count == 3 else { return nil }
        return TerminalColor(red: values[0], green: values[1], blue: values[2])
    }

    private static func channel(_ digits: Substring) -> Double? {
        guard (1...4).contains(digits.count), digits.allSatisfy(\.isHexDigit),
            let value = Int(digits, radix: 16)
        else { return nil }
        let maximum = (1 << (4 * digits.count)) - 1
        return Double(value) / Double(maximum)
    }
}
