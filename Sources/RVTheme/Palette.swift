public struct Palette: Equatable, Sendable {
    public var colorsEnabled: Bool
    public var reset: String
    public var fact: String
    public var muted: String
    public var deny: String
    public var allow: String

    public init(
        colorsEnabled: Bool,
        reset: String,
        fact: String,
        muted: String,
        deny: String,
        allow: String
    ) {
        self.colorsEnabled = colorsEnabled
        self.reset = reset
        self.fact = fact
        self.muted = muted
        self.deny = deny
        self.allow = allow
    }
}

public func palette(for capability: ColorCapability) -> Palette {
    if !capability.colorsEnabled {
        return Palette(
            colorsEnabled: false,
            reset: "",
            fact: "",
            muted: "",
            deny: "",
            allow: ""
        )
    }
    return Palette(
        colorsEnabled: true,
        reset: "\u{001B}[0m",
        fact: "\u{001B}[1m",
        muted: "\u{001B}[2m",
        deny: "\u{001B}[31m",
        allow: "\u{001B}[32m"
    )
}

public let colorOffPalette = palette(for: ColorCapability(colorsEnabled: false))
