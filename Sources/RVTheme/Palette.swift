public struct RegexInk: Equatable, Sendable {
    public var meta: String
    public var escape: String
    public var name: String

    public init(meta: String, escape: String, name: String) {
        self.meta = meta
        self.escape = escape
        self.name = name
    }

    public static let off = RegexInk(meta: "", escape: "", name: "")
}

public struct Palette: Equatable, Sendable {
    public var colorsEnabled: Bool
    public var reset: String
    public var fact: String
    public var muted: String
    public var deny: String
    public var allow: String
    public var heading: String
    public var mark: String
    public var trace: String
    public var silver: String
    public var regex: RegexInk

    public init(
        colorsEnabled: Bool,
        reset: String,
        fact: String,
        muted: String,
        deny: String,
        allow: String,
        heading: String,
        mark: String,
        trace: String,
        silver: String,
        regex: RegexInk
    ) {
        self.colorsEnabled = colorsEnabled
        self.reset = reset
        self.fact = fact
        self.muted = muted
        self.deny = deny
        self.allow = allow
        self.heading = heading
        self.mark = mark
        self.trace = trace
        self.silver = silver
        self.regex = regex
    }
}

extension Palette {
    /// Color-off palette is identity strings so renderers never emit CSI.
    public init(for capability: ColorCapability) {
        if !capability.colorsEnabled {
            self.init(
                colorsEnabled: false,
                reset: "",
                fact: "",
                muted: "",
                deny: "",
                allow: "",
                heading: "",
                mark: "",
                trace: "",
                silver: "",
                regex: .off
            )
            return
        }
        self.init(
            colorsEnabled: true,
            reset: "\u{001B}[0m",
            fact: "\u{001B}[1m",
            muted: "\u{001B}[2m",
            deny: "\u{001B}[1;31m",
            allow: "\u{001B}[1;32m",
            heading: "\u{001B}[1;36m",
            mark: "\u{001B}[1;33m",
            trace: "\u{001B}[1;34m",
            silver: "\u{001B}[38;5;244m",
            regex: RegexInk(
                meta: "\u{001B}[1;33m",
                escape: "\u{001B}[96m",
                name: "\u{001B}[35m"
            )
        )
    }
}

/// Spec name. Prefer `Palette(for:)`.
public func palette(for capability: ColorCapability) -> Palette {
    Palette(for: capability)
}

public let colorOffPalette = palette(for: ColorCapability(colorsEnabled: false))
