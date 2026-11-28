import RVDomain

/// Why a payload addressed to this host could not be decoded.
public enum HookMalformation: Equatable, Sendable {
    /// Stdin was not UTF-8 JSON of this host's envelope shape.
    case unreadable
    /// Envelope parsed but carried no shell command text.
    case missingCommand
}

/// Closed result of decoding host hook stdin.
///
/// `.foreign` fails open through `encodeAllow`: the event is not ours to grade.
/// `.malformed` fails closed through `encodeDeny`: the payload claimed this host
/// but could not be decoded, matching the C shim's fail-closed `_exit(2)`.
public enum HookDecodeOutcome: Equatable, Sendable {
    /// This adapter owns the invocation; `command` is always present.
    case request(HookRequest)
    /// Not a shell invocation for this host (other tool or event).
    case foreign
    /// The host's session-start event (B4): no tool runs, nothing is
    /// evaluated, and the reply is rv's house rules or nothing. Only hosts
    /// with a session-start context wire decode this; for every other
    /// host the event stays `.foreign`.
    case sessionStart(cwd: WorkingDirectory?)
    /// Addressed to this host but unparseable — fail closed on purpose.
    case malformed(HookMalformation)
}
