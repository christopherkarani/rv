import RVDomain

/// The host session id of the hook request being evaluated. `hookWire`
/// binds it around the evaluation, so the denial rows that evaluation
/// writes (blocks ledger, audit chain) can name the agent session that
/// tripped the rule. Never carries command text; unbound (nil) outside a
/// hook request.
package enum HookSessionAttribution {
    @TaskLocal package static var current: SessionID?
}
