import Foundation
import RVDomain
import RVHistory
import RVLaya
import RVPolicy

/// One side-effect write a gated evaluation asks for. The decision part of
/// each door returns these in the order they would have been written; the
/// door's shell (`GatedEvaluate.perform`) applies them after the decision.
///
/// Not effects: grant spend / preview (`PolicyGate`, SEC-003) and the
/// in-memory judge model cache. Both stay inline in the decision.
///
/// Payloads carry no home: with no home every write is a no-op, so the
/// shell drops effects then, exactly as the inline writes did.
enum GatedEffect: Sendable, Equatable {
    /// Row for `exemption-drops.jsonl`: repo literals dropped for lack of
    /// machine blessing. Emitted only for a non-empty dropped set.
    case exemptionAudit(ExemptionAudit)
    /// Row for `judge-log.jsonl`.
    case judgeLog(JudgeLogRow)
    /// Row for the denial ledger. Apply and the file door only; the shell
    /// still honours `DenialLedgerPreferences` for the ledger, and always
    /// appends a `command.denied` event (`command.observed` for an
    /// observe-mode would-be deny) to the hash-chained `audit.jsonl`. An
    /// indeterminate refusal is chained only (`DenialRow.indeterminate`).
    case denialRow(DenialRow)
    /// A deny the Policy gate turned into an allow (allow-once, allowlist,
    /// rebase recovery, contained delete). Appended to `audit.jsonl` as
    /// `command.override`. Apply only; never written for a peek.
    case overrideAudit(OverrideRow)

    struct ExemptionAudit: Sendable, Equatable {
        let dropped: [String]
        let workspace: URL?
        let at: Date
    }

    /// Hash-only judge-log row (never command text).
    struct JudgeLogRow: Sendable, Equatable {
        enum Verdict: String, Sendable {
            case allow, deny, indeterminate
        }

        /// `live` is an enforced verdict; `wouldBe` is an observe-mode
        /// would-be verdict (the live verdict is then always allow).
        enum Subject: Sendable, Equatable {
            case live(Verdict)
            case wouldBe(Verdict, rule: String?)
        }

        /// Judge scores, already rounded as logged.
        struct Score: Sendable, Equatable {
            let choice: String
            let action: String
            let risk: Double
            let malicious: Double
            let checkpoint: String
            let milliseconds: Double
            let truncated: Bool
            /// The bundle operating point `action` was read at; nil for
            /// the fixed runtime thresholds.
            var thresholds: LayaThresholds? = nil
        }

        let at: Date
        let guardMode: GuardMode
        let engine: JudgeEngine
        let hash: String
        let subject: Subject
        let note: String?
        let isPeek: Bool
        let score: Score?
        /// A second row for a request already logged: the late answer of a
        /// prediction its caller gave up on (`"lateOf": true`). Counts of
        /// requests or deny rates skip these rows.
        var isLateResult = false
    }

    /// Denial-ledger row before home-relative path redaction.
    struct DenialRow: Sendable, Equatable {
        let at: Date
        let host: LedgerHost
        let tool: LedgerTool
        let ruleID: RuleID
        let category: LedgerCategory
        /// Unredacted; the shell redacts against home when writing.
        let path: String
        /// Observe mode: enforcement would have denied, the door allowed.
        var observed = false
        /// Observed rows: whether that enforced deny would have surfaced
        /// as an ask (`HookAuthorization.project`).
        var wouldBe: LedgerWouldBe = .deny
        /// Set when the refusal is an indeterminate verdict, not a rule
        /// deny: chained as a marked `command.denied` (`command.observed`
        /// when observe let it run), never written to the rule-oriented
        /// denial ledger.
        var indeterminate: IndeterminateReason?
        /// The hook request's host session id, when it is an opaque token
        /// (`DenialLedgerRecord.attributableSession`); nil otherwise.
        var session: String?
    }

    struct OverrideRow: Sendable, Equatable {
        let at: Date
        let host: LedgerHost
        let ruleID: RuleID
        /// `allowOnce`, `allowlist`, `rebaseRecovery` or `containedReversible`.
        let override: String
        let workspace: URL?
        /// The rows for the deny this stays when the override row does not
        /// land (`command.denied` and the denial ledger). nil when the hook
        /// deadline passed and no allow-once grant was spent: `HookDoor`
        /// then answers with the timeout deny instead, and no deny row is
        /// written for it. A grant spent in time keeps the rows, since its
        /// reply (allow, or this deny) is delivered.
        let denial: DenialRow?
    }
}
