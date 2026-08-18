public struct ThemeProbe: Equatable, Sendable {
    public var stdinIsTTY: Bool
    public var stdoutIsTTY: Bool
    public var jsonFlag: Bool
    public var robotFlag: Bool
    public var plainFlag: Bool
    public var noColorFlag: Bool
    public var ci: Bool
    public var noColorEnv: Bool
    public var termDumb: Bool
    public var columns: Int

    public init(
        stdinIsTTY: Bool,
        stdoutIsTTY: Bool,
        jsonFlag: Bool,
        robotFlag: Bool,
        plainFlag: Bool,
        noColorFlag: Bool,
        ci: Bool,
        noColorEnv: Bool,
        termDumb: Bool,
        columns: Int = 80
    ) {
        self.stdinIsTTY = stdinIsTTY
        self.stdoutIsTTY = stdoutIsTTY
        self.jsonFlag = jsonFlag
        self.robotFlag = robotFlag
        self.plainFlag = plainFlag
        self.noColorFlag = noColorFlag
        self.ci = ci
        self.noColorEnv = noColorEnv
        self.termDumb = termDumb
        self.columns = max(16, columns)
    }
}
