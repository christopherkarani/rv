/// How many colours a terminal can draw. A full-screen view picks one tier
/// up front and maps every ink to it; meaning must never depend on colour
/// alone, so `none` still reads (glyphs, bold, dim, reverse).
public enum ColorDepth: Int, Comparable, Equatable, Sendable, CaseIterable {
    /// `NO_COLOR`, `TERM=dumb`, or not a terminal.
    case none = 0
    /// The 16 ANSI slots the user's theme defines.
    case ansi16
    /// xterm's 256-colour palette (`*-256color`).
    case ansi256
    /// 24-bit colour (`COLORTERM=truecolor`).
    case truecolor

    /// `RV_COLOR_DEPTH=none|16|256|truecolor` overrides detection, except
    /// that it can never turn colour back on over `NO_COLOR` or a pipe.
    public static let environmentKey = "RV_COLOR_DEPTH"

    public static func < (lhs: ColorDepth, rhs: ColorDepth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The tier for this environment. Detection only reads variables; it
    /// never asks the terminal, so it is safe over SSH and inside tmux.
    public init(environment: [String: String], stdoutIsTTY: Bool) {
        let term = environment["TERM"]?.lowercased() ?? ""
        guard stdoutIsTTY, environment["NO_COLOR"] == nil, term != "dumb" else {
            self = .none
            return
        }
        if let forced = Self.override(environment[Self.environmentKey]) {
            self = forced
            return
        }
        let colorTerm = environment["COLORTERM"]?.lowercased() ?? ""
        if colorTerm == "truecolor" || colorTerm == "24bit" || term.hasSuffix("-direct") {
            self = .truecolor
            return
        }
        // These terminals draw 24-bit colour but do not always export
        // COLORTERM (for example after `sudo` or across SSH).
        switch environment["TERM_PROGRAM"] {
        case "iTerm.app", "WezTerm", "ghostty", "vscode":
            self = .truecolor
            return
        default:
            break
        }
        if term.contains("kitty") || term.contains("ghostty") {
            self = .truecolor
        } else if term.contains("256color") {
            self = .ansi256
        } else {
            self = .ansi16
        }
    }

    static func override(_ raw: String?) -> ColorDepth? {
        switch raw?.lowercased() {
        case "none", "0", "off": return ColorDepth.none
        case "16", "ansi16": return .ansi16
        case "256", "ansi256": return .ansi256
        case "truecolor", "24bit", "rgb": return .truecolor
        default: return nil
        }
    }
}

/// An 8-bit-per-channel sRGB colour, as a design token is written.
public struct RGB24: Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xB8A9FF` → (184, 169, 255).
    public init(hex: UInt32) {
        self.init(
            red: UInt8((hex >> 16) & 0xFF),
            green: UInt8((hex >> 8) & 0xFF),
            blue: UInt8(hex & 0xFF)
        )
    }
}

/// xterm's 256-colour palette: 16 theme slots, a 6×6×6 cube (16...231) and
/// a 24-step grey ramp (232...255). Only the cube and the ramp have fixed
/// values, so quantizing never lands on 0...15.
public enum Xterm256 {
    static let cubeLevels: [Int] = [0, 95, 135, 175, 215, 255]

    /// The fixed colour of palette index 16...255.
    public static func color(at index: UInt8) -> RGB24? {
        let i = Int(index)
        if i >= 232 {
            let v = UInt8(8 + (i - 232) * 10)
            return RGB24(red: v, green: v, blue: v)
        }
        guard i >= 16 else { return nil }
        let cube = i - 16
        return RGB24(
            red: UInt8(cubeLevels[cube / 36]),
            green: UInt8(cubeLevels[(cube / 6) % 6]),
            blue: UInt8(cubeLevels[cube % 6])
        )
    }

    /// The palette index (16...255) closest to `color`, by a luma-weighted
    /// distance, so greys stay grey and saturated inks keep their hue.
    public static func nearest(_ color: RGB24) -> UInt8 {
        func level(_ channel: UInt8) -> Int {
            var best = 0
            for (index, value) in cubeLevels.enumerated()
            where abs(value - Int(channel)) < abs(cubeLevels[best] - Int(channel)) {
                best = index
            }
            return best
        }
        let cubeIndex = UInt8(16 + 36 * level(color.red) + 6 * level(color.green) + level(color.blue))
        let mean = (Int(color.red) + Int(color.green) + Int(color.blue)) / 3
        let greyStep = min(23, max(0, (mean - 8 + 5) / 10))
        let greyIndex = UInt8(232 + greyStep)
        let cubeDistance = distance(color, Self.color(at: cubeIndex))
        let greyDistance = distance(color, Self.color(at: greyIndex))
        return greyDistance < cubeDistance ? greyIndex : cubeIndex
    }

    static func distance(_ a: RGB24, _ b: RGB24?) -> Int {
        guard let b else { return Int.max }
        let dr = Int(a.red) - Int(b.red)
        let dg = Int(a.green) - Int(b.green)
        let db = Int(a.blue) - Int(b.blue)
        return 3 * dr * dr + 6 * dg * dg + db * db
    }
}

/// One ink as the terminal will draw it at each depth: the exact colour
/// for truecolor (and 256, by quantizing), and a semantic ANSI slot for 16.
public struct TerminalInk: Equatable, Sendable {
    public var rgb: RGB24
    /// 0...15. The slot the user's theme already tunes for this meaning.
    public var ansi16: UInt8

    public init(rgb: RGB24, ansi16: UInt8) {
        self.rgb = rgb
        self.ansi16 = min(ansi16, 15)
    }

    /// The SGR parameters that select this ink as foreground at `depth`
    /// (`38;2;r;g;b`, `38;5;n`, `31`/`91`), or nil at `none`.
    public func foreground(_ depth: ColorDepth) -> String? {
        switch depth {
        case .none: return nil
        case .ansi16: return ansi16 < 8 ? "\(30 + Int(ansi16))" : "\(90 + Int(ansi16) - 8)"
        case .ansi256: return "38;5;\(Xterm256.nearest(rgb))"
        case .truecolor: return "38;2;\(rgb.red);\(rgb.green);\(rgb.blue)"
        }
    }

    /// The SGR parameters that select this ink as background at `depth`.
    public func background(_ depth: ColorDepth) -> String? {
        switch depth {
        case .none: return nil
        case .ansi16: return ansi16 < 8 ? "\(40 + Int(ansi16))" : "\(100 + Int(ansi16) - 8)"
        case .ansi256: return "48;5;\(Xterm256.nearest(rgb))"
        case .truecolor: return "48;2;\(rgb.red);\(rgb.green);\(rgb.blue)"
        }
    }
}
