/// stdin/stdout TTY pair used for browse and color.
public struct TTYPair: Equatable, Sendable {
    public var stdinIsTTY: Bool
    public var stdoutIsTTY: Bool

    public init(stdinIsTTY: Bool, stdoutIsTTY: Bool) {
        self.stdinIsTTY = stdinIsTTY
        self.stdoutIsTTY = stdoutIsTTY
    }

    /// Both descriptors are TTYs — one half of browse eligibility.
    public var isBrowseEligible: Bool {
        stdinIsTTY && stdoutIsTTY
    }

    /// stdout can carry color when mode and the forbid set allow it.
    public var canCarryColor: Bool {
        stdoutIsTTY
    }
}

/// Flags that force robot, kill browse, or kill color.
public struct OutputForbid: Equatable, Sendable {
    /// Color-off request: `--no-color`, `NO_COLOR`, or `TERM=dumb`.
    public struct NoColor: Equatable, Sendable {
        public var flag: Bool
        public var env: Bool
        public var termDumb: Bool

        public init(flag: Bool, env: Bool, termDumb: Bool) {
            self.flag = flag
            self.env = env
            self.termDumb = termDumb
        }

        /// `NO_COLOR` forbids browse. `--no-color` and `TERM=dumb` only kill color.
        public var isBrowseEligible: Bool { !env }

        /// Any color-off request disables ANSI.
        public var canCarryColor: Bool { !(flag || env || termDumb) }
    }

    public var json: Bool
    public var robot: Bool
    public var plain: Bool
    public var ci: Bool
    public var noColor: NoColor

    public init(json: Bool, robot: Bool, plain: Bool, ci: Bool, noColor: NoColor) {
        self.json = json
        self.robot = robot
        self.plain = plain
        self.ci = ci
        self.noColor = noColor
    }

    /// None of json / robot / plain / CI / `NO_COLOR` are set.
    public var isBrowseEligible: Bool {
        !json && !robot && !plain && !ci && noColor.isBrowseEligible
    }

    /// Pretty/browse color is off for plain, CI, or any color-off request.
    public var canCarryColor: Bool {
        !plain && !ci && noColor.canCarryColor
    }
}

public struct ThemeProbe: Equatable, Sendable {
    public var terminal: TTYPair
    public var forbid: OutputForbid
    public var columns: Int

    public var stdinIsTTY: Bool { terminal.stdinIsTTY }
    public var stdoutIsTTY: Bool { terminal.stdoutIsTTY }
    public var jsonFlag: Bool { forbid.json }
    public var robotFlag: Bool { forbid.robot }
    public var plainFlag: Bool { forbid.plain }
    public var noColorFlag: Bool { forbid.noColor.flag }
    public var ci: Bool { forbid.ci }
    public var noColorEnv: Bool { forbid.noColor.env }
    public var termDumb: Bool { forbid.noColor.termDumb }

    /// Both TTY and none of the browse forbids.
    public var isBrowseEligible: Bool {
        terminal.isBrowseEligible && forbid.isBrowseEligible
    }

    /// Color for a resolved output mode.
    public func colorCapability(mode: OutputMode) -> ColorCapability {
        ColorCapability(probe: self, mode: mode)
    }

    public init(terminal: TTYPair, forbid: OutputForbid, columns: Int = 80) {
        self.terminal = terminal
        self.forbid = forbid
        self.columns = max(16, columns)
    }

    /// Spec-locked 10-field construction. Prefer `init(terminal:forbid:columns:)`.
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
        self.init(
            terminal: TTYPair(stdinIsTTY: stdinIsTTY, stdoutIsTTY: stdoutIsTTY),
            forbid: OutputForbid(
                json: jsonFlag,
                robot: robotFlag,
                plain: plainFlag,
                ci: ci,
                noColor: OutputForbid.NoColor(flag: noColorFlag, env: noColorEnv, termDumb: termDumb)
            ),
            columns: columns
        )
    }
}
