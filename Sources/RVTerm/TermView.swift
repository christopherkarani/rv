/// The three views of rv term, in tab order. The number is the key that
/// opens the view; the deep-link name is what `rv term --view` and the
/// menu bar app pass.
///
/// v5c cut v5b's six views to three: Watched is Stream's would-stop
/// filter, Week is `rv week`, Posture is the console (and `rv report`).
public enum TermView: Int, CaseIterable, Equatable, Hashable, Sendable {
    case glance = 1
    case stream
    case needsYou

    /// The digit key that opens this view, 1...3.
    public var number: Int { rawValue }

    /// Tab label.
    public var title: String {
        switch self {
        case .glance: "Glance"
        case .stream: "Stream"
        case .needsYou: "Needs you"
        }
    }

    /// `rv term --view <name>`.
    public var deepLinkName: String {
        switch self {
        case .glance: "glance"
        case .stream: "stream"
        case .needsYou: "needs-you"
        }
    }

    public init?(number: Int) {
        self.init(rawValue: number)
    }

    /// Case-insensitive; also accepts `needs_you` and `needsyou`. `watched`
    /// (a v5b view) opens Stream, where the would-stops now live. `week`
    /// and `posture` are not views: the command prints `rv week` or
    /// `rv report` for them.
    public init?(deepLinkName: String) {
        let key = deepLinkName.lowercased().filter { $0 != "-" && $0 != "_" }
        if key == "watched" {
            self = .stream
            return
        }
        guard let view = Self.allCases.first(where: { $0.deepLinkName.filter { $0 != "-" } == key }) else {
            return nil
        }
        self = view
    }
}
