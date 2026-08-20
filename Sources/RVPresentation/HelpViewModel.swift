/// One labeled row under a help section (`setup`, `--json`, …).
public struct HelpRow: Equatable, Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }
}

/// A headed block of help rows (`Get started`, `Flags`, …).
public struct HelpSection: Equatable, Sendable {
    public var heading: String
    public var rows: [HelpRow]
    /// When true, row names use the single “start here” accent (green).
    public var accentNames: Bool

    public init(heading: String, rows: [HelpRow], accentNames: Bool = false) {
        self.heading = heading
        self.rows = rows
        self.accentNames = accentNames
    }
}

/// A Next-line suggestion (`rv help test`, …).
public struct HelpNextItem: Equatable, Sendable {
    public var command: String
    public var description: String

    public init(command: String, description: String) {
        self.command = command
        self.description = description
    }
}

/// Pure help page for TTY / plain CLI rendering.
public struct HelpViewModel: Equatable, Sendable {
    public var title: String
    public var blurb: String
    public var sections: [HelpSection]
    public var examples: [String]
    /// Heading above workflow / deeper-help suggestions. Default `Next`.
    public var nextHeading: String
    public var next: [HelpNextItem]

    public init(
        title: String,
        blurb: String,
        sections: [HelpSection] = [],
        examples: [String] = [],
        nextHeading: String = "Next",
        next: [HelpNextItem] = []
    ) {
        self.title = title
        self.blurb = blurb
        self.sections = sections
        self.examples = examples
        self.nextHeading = nextHeading
        self.next = next
    }
}
