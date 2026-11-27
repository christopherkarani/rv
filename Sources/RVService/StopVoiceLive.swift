#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVHooks
import RVPacks
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
