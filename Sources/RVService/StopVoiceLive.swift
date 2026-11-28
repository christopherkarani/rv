#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVHooks
import RVPacks
import RVPolicy
import Synchronization

extension OwnerName {
    /// This account's first name from its passwd full name (gecos), read
    /// once per process with `getpwuid_r`. Never the environment: `USER`,
    /// `NAME` and the rest are the agent's to set.
    public static let current: OwnerName = OwnerName(gecos: passwdGecos())
}

private func passwdGecos() -> String? {
    var entry = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 16 * 1024)
    let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
        guard let base = pointer.baseAddress else { return ERANGE }
        return getpwuid_r(getuid(), &entry, base, pointer.count, &result)
    }
    guard status == 0, result != nil, let gecos = entry.pw_gecos else { return nil }
    return String(validatingCString: gecos)
}

extension StopVoice {
    /// rvd's and the hook-local pass's voice: the owner's first name and
    /// each bundled pack's `safer_command` / `who_acts` (G1).
    public static let live = StopVoice(owner: .current, advice: { BundledStopAdvice.shared.advice(for: $0) })
}

/// Pack advice read from the bundled pack JSON, one pack at a time and only
/// when a stop needs it: a stop loads the pack that stopped it, never the
/// catalog. A rule from a repo policy, a builtin rule or a pack that does
/// not load gives no advice.
final class BundledStopAdvice: Sendable {
    static let shared = BundledStopAdvice()

    private let byPack = Mutex<[PackID: [RuleID: StopAdvice]]>([:])

    func advice(for rule: RuleID) -> StopAdvice? {
        if let cached = byPack.withLock({ $0[rule.pack] }) {
            return cached[rule]
        }
        let loaded = Self.load(rule.pack)
        byPack.withLock { $0[rule.pack] = loaded }
        return loaded[rule]
    }

    private static func load(_ pack: PackID) -> [RuleID: StopAdvice] {
        // Only a valid pack id names a bundled file; anything else (a policy
        // or builtin id) has no pack JSON to read.
        guard PackID(validating: pack.rawValue) != nil, pack.rawValue.contains("/") == false,
              let document = try? PackRegistry.loadDocument(pack)
        else { return [:] }
        var advice: [RuleID: StopAdvice] = [:]
        for guidance in document.guidance where guidance.saferCommand != nil || guidance.whoActs != nil {
            advice[guidance.ruleID] = StopAdvice(saferCommand: guidance.saferCommand, whoActs: guidance.whoActs)
        }
        return advice
    }
}

extension GatedEvaluate {
    /// Whether a stop may offer `command` as its `safer` line: this door
    /// allows it here (this cwd, this home's packs and mode), and under
    /// watch mode enforce would allow it too, so the advice is never a
    /// command rv itself stops. Decided as a peek on the rules alone: no
    /// allow-once grant or allowlist entry counts, and no judge runs (the
    /// door is `withoutJudge()`, whichever judge this one has). Its effects
    /// are dropped, so vetting advice writes no audit, judge or ledger row.
    /// `inputs` are the stop's own, when its caller kept them; otherwise
    /// they are read for this cwd.
    func allowsSaferCommand(
        _ command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory?,
        now: Date,
        inputs: EvaluationInputs? = nil
    ) async -> Bool {
        let door = withoutJudge()
        let decided = await HookTiming.$current.withValue(nil) {
            await door.decideVerdict(
                .peek, Self.makeRequest(command: command, home: home), cwd: cwd, home: home,
                grants: EphemeralAllowOnceTable(), now: now, allowlist: { AllowlistSnapshot(entries: []) },
                host: .tty, tool: .bash, previewsWouldBe: true,
                inputs: inputs ?? Self.liveInputs(home: home, cwd: cwd)
            )
        }
        let wouldBe = decided.wouldBe?.result.decision ?? decided.result.decision
        return decided.result.decision == .allow && wouldBe == .allow
    }
}

/// The judge a safer command is vetted with, in rvd and the hook-local
/// pass: none. Vetting advice must not hold a stop on the judge, take its
/// slots, or leave a judge-log row for a command nobody ran.
struct SaferVetNoJudge: JudgePort {
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        .unavailable("a safer command is vetted without the judge")
    }
}

extension LiveEvaluateWorld {
    /// rvd's vet of a stop's safer command (`GatedEvaluate.allowsSaferCommand`,
    /// with no judge).
    package func allowsSaferCommand(_ command: ShellCommand, cwd: WorkingDirectory?) async -> Bool {
        await vettingDoor.allowsSaferCommand(command, cwd: cwd, home: home, now: Date())
    }
}
