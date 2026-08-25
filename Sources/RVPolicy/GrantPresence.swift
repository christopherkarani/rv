/// What the gate sees. Consume is an apply-shell effect, not a presence.
public enum GrantPresence: Sendable, Equatable {
    case none
    case pending
}
