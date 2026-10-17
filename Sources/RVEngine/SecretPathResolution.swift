import RVDomain

/// One alias expansion per guard candidate operand.
///
/// The engine stays I/O-free by contract, so resolution is injected: the
/// caller supplies a closure that maps a typed candidate operand (e.g. a
/// symlinked spelling) to the path it actually targets on the filesystem,
/// normalizing home paths back to `~`-form so suffix rules still match.
/// Nil means "no distinct target"; the typed candidate stays the only
/// spelling. Every resolved path flows back through the same rule matching
/// and exemption checks as typed candidates.
public struct SecretPathResolution: Sendable {
    public var resolve: @Sendable (String) -> String?

    public init(resolve: @escaping @Sendable (String) -> String?) {
        self.resolve = resolve
    }
}

/// Exemption predicate over one candidate spelling and the rule it matched.
///
/// Returning true skips that spelling; the guard keeps scanning the next
/// candidate (including its resolved alias) before conceding an allow, so an
/// exempted spelling never masks a later non-exempt one.
public typealias SecretPathExemption = @Sendable (String, SecretPathRule) -> Bool
