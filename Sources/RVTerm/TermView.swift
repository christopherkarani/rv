/// The six views of rv term, in tab order. The number is the key that
/// opens the view; the deep-link name is what `rv term --view` and the
/// menu bar app pass.
public enum TermView: Int, CaseIterable, Equatable, Hashable, Sendable {
    case glance = 1
    case stream
    case needsYou
    case watched
    case week
    case posture

    /// The digit key that opens this view, 1...6.
    public var number: Int { rawValue }

    /// Tab label.
    public var title: String {
        switch self {
        case .glance: "Glance"
        case .stream: "Stream"
        case .needsYou: "Needs you"
        case .watched: "Watched"
        case .week: "Week"
        case .posture: "Posture"
        }
    }

    /// `rv term --view <name>`.
    public var deepLinkName: String {
        switch self {
        case .glance: "glance"
        case .stream: "stream"
        case .needsYou: "needs-you"
        case .watched: "watched"
        case .week: "week"
        case .posture: "posture"
        }
    }

    public init?(number: Int) {
        self.init(rawValue: number)
    }

    /// Case-insensitive; also accepts `needs_you` and `needsyou`.
    public init?(deepLinkName: String) {
        let key = deepLinkName.lowercased().filter { $0 != "-" && $0 != "_" }
        guard let view = Self.allCases.first(where: { $0.deepLinkName.filter { $0 != "-" } == key }) else {
            return nil
        }
        self = view
    }
}
