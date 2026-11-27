import Foundation

/// What guarding would have done with a command watch mode let run: the
/// observed would-be verdict, as the denial ledger's observed row has it.
public struct DecisionWouldBe: Sendable, Equatable, Codable {
    /// `denied` for a rule, `refused` when rv could not finish deciding.
    public var verdict: DecisionVerdict
    /// The rule (or `rv.indeterminate:` reason) guarding would have cited.
    public var rule: String
    /// Guarding would have asked a human rather than stopped it.
    public var ask: Bool

    public init(verdict: DecisionVerdict, rule: String, ask: Bool = false) {
        self.verdict = verdict
        self.rule = rule
        self.ask = ask
    }
}

/// One hook call's id: minted once before evaluation, carried by the
/// call's denial-ledger row and its decision-log row, so the two name the
/// same call. A value; the per-call state that notes a watch-mode would-be
/// while the call runs lives with the hook door (`DecisionCall` in
/// RVService).
public struct DecisionStamp: Sendable, Equatable, Hashable {
    /// 12 lowercase hex digits. `rv log` shows the first six as its code.
    public let id: String

    public init(id: String = DecisionStamp.mintID()) {
        self.id = id
    }

    /// `a7c-835`: the code `rv log` prints for this call.
    public var code: String { Self.code(forID: id) }

    /// A fresh random id: 48 bits, so rows in the 7-day window do not
    /// share one.
    public static func mintID() -> String {
        let value = UInt64.random(in: 0..<(1 << 48))
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 12 - hex.count) + hex
    }

    /// `raw` when it is an id as `mintID` makes them (12 lowercase hex
    /// digits), else nil.
    public static func validID(_ raw: String) -> String? {
        raw.utf8.count == 12 && raw.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) } ? raw : nil
    }

    /// `a7c-835`: the code `rv log` prints for an id.
    public static func code(forID id: String) -> String {
        String(id.prefix(3)) + "-" + String(id.dropFirst(3).prefix(3))
    }
}
