/// Guard posture for the whole evaluate door — packs and judge alike.
public enum GuardMode: String, Sendable {
    /// Normal operation: packs deny, judge (when on) may raise an allow.
    case enforce
    /// Everything is evaluated and logged, nothing blocks. The would-be
    /// verdict (packs, script check, judge) lands in judge-log.jsonl.
    case observe
}

/// Which judge scores a pack-allowed command.
///
/// `ft` is the Ticket 5a single-pass fine-tune (bundle
/// `models/laya-ft-v2-coreml`); `laya` is the stock three-question CoreML
/// judge (bundle `models/laya-multilingual-coreml`).
public enum JudgeEngine: String, Sendable {
    case ft
    case laya
}

/// How rv guards one hook host. `block` enforces, `observe` allows and logs
/// what enforcement would have blocked, `off` leaves the host unwired. A
/// host with no stored entry follows the global `guard.mode` (enforce by
/// default); a stored entry, `block` included, outranks it.
public enum HostMode: String, Sendable, Equatable, CaseIterable {
    case block
    case observe
    case off

    /// True when moving from `current` to `self` sheds oversight.
    public func isLooser(than current: HostMode) -> Bool {
        rank < current.rank
    }

    private var rank: Int {
        switch self {
        case .off: 0
        case .observe: 1
        case .block: 2
        }
    }
}
