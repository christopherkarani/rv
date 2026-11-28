import Foundation
import Testing
import RVDomain
import RVPolicy

@Suite("Loosen proposal ledger")
struct LoosenProposalLedgerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let change = PolicyLoosen.allowRule(rule: "core.git:reset-hard", reason: "rebasing")

    @Test func idsCountUpAndTheSameChangeIsNotFiledTwice() throws {
        let first = try LoosenProposalLedger.propose(Self.change, from: "claude", cwd: "~/app", records: [], now: Self.now)
        #expect(first.proposal.id.rawValue == "p-1")
        #expect(first.created)
        let again = try LoosenProposalLedger.propose(
            Self.change, from: "claude", cwd: "~/app", records: first.records, now: Self.now)
        #expect(again.created == false)
        #expect(again.proposal.id.rawValue == "p-1")
        let other = try LoosenProposalLedger.propose(.safetyNormal, from: nil, cwd: nil, records: again.records, now: Self.now)
        #expect(other.proposal.id.rawValue == "p-2")
    }

    @Test func theHashCoversEveryFieldShown() {
        let id = ProposalID(number: 1)
        let base = LoosenProposalLedger.contentHash(id: id, change: Self.change, from: "claude", cwd: "~/app")
        #expect(base.count == 64)
        let variants = [
            LoosenProposalLedger.contentHash(id: ProposalID(number: 2), change: Self.change, from: "claude", cwd: "~/app"),
            LoosenProposalLedger.contentHash(
                id: id, change: .allowRule(rule: "core.git:reset-hard", reason: "rebasin"), from: "claude", cwd: "~/app"),
            LoosenProposalLedger.contentHash(
                id: id, change: .allowRule(rule: "core.git:push-force", reason: "rebasing"), from: "claude", cwd: "~/app"),
            LoosenProposalLedger.contentHash(id: id, change: Self.change, from: "codex", cwd: "~/app"),
            LoosenProposalLedger.contentHash(id: id, change: Self.change, from: nil, cwd: "~/app"),
            LoosenProposalLedger.contentHash(id: id, change: Self.change, from: "claude", cwd: nil),
            // Field boundaries cannot be moved: "a" + "bc" is not "ab" + "c".
            LoosenProposalLedger.contentHash(id: id, change: .allowRule(rule: "core.git:reset-hardr", reason: "ebasing"),
                from: "claude", cwd: "~/app"),
        ]
        #expect(Set(variants + [base]).count == variants.count + 1)
    }

    @Test func pendingProposalsAreCapped() throws {
        var records: [LoosenProposal] = []
        for index in 0..<LoosenProposalLedger.maxPending {
            records = try LoosenProposalLedger.propose(
                .packOff(pack: "core.p\(index)"), from: nil, cwd: nil, records: records, now: Self.now).records
        }
        #expect(throws: LoosenProposalError.full) {
            try LoosenProposalLedger.propose(.safetyNormal, from: nil, cwd: nil, records: records, now: Self.now)
        }
    }

    @Test func oldProposalsExpireAndCannotBeApproved() throws {
        let filed = try LoosenProposalLedger.propose(Self.change, from: nil, cwd: nil, records: [], now: Self.now)
        let later = Self.now.addingTimeInterval(LoosenProposalLedger.lifetime + 1)
        let (swept, expired) = LoosenProposalLedger.sweep(filed.records, now: later)
        #expect(expired.map(\.id) == [filed.proposal.id])
        #expect(swept.first?.status == .expired)
        #expect(throws: LoosenProposalError.notPending(.expired)) {
            try LoosenProposalLedger.decide(
                filed.proposal.id, shownHash: filed.proposal.contentHash, to: .approved, records: filed.records, now: later)
        }
    }

    @Test func decidingIsACompareAndSetOnTheShownHash() throws {
        let filed = try LoosenProposalLedger.propose(Self.change, from: nil, cwd: nil, records: [], now: Self.now)
        let id = filed.proposal.id
        #expect(throws: LoosenProposalError.changed) {
            try LoosenProposalLedger.decide(id, shownHash: "00", to: .approved, records: filed.records, now: Self.now)
        }
        var edited = filed.records
        edited[0].change = .allowRule(rule: "core.rm:rm-rf-root", reason: "rebasing")
        #expect(throws: LoosenProposalError.changed) {
            try LoosenProposalLedger.decide(
                id, shownHash: filed.proposal.contentHash, to: .approved, records: edited, now: Self.now)
        }
        let approved = try LoosenProposalLedger.decide(
            id, shownHash: filed.proposal.contentHash, to: .approved, records: filed.records, now: Self.now)
        #expect(approved.proposal.status == .approved)
        #expect(throws: LoosenProposalError.notPending(.approved)) {
            try LoosenProposalLedger.decide(
                id, shownHash: filed.proposal.contentHash, to: .approved, records: approved.records, now: Self.now)
        }
        #expect(throws: LoosenProposalError.notFound) {
            try LoosenProposalLedger.decide(
                ProposalID(number: 9), shownHash: "", to: .rejected, records: approved.records, now: Self.now)
        }
    }

    @Test func malformedChangesAreRefused() {
        #expect(PolicyLoosen.allowRule(rule: "", reason: "x").problem == "the rule id is empty")
        #expect(PolicyLoosen.allowRule(rule: "core.git:x", reason: " ").problem == "a reason is required")
        #expect(PolicyLoosen.allowRule(rule: "core git", reason: "x").problem
            == "the rule id may hold only letters, digits and . - _ : /")
        #expect(PolicyLoosen.allowCommand(command: "  ", reason: "x").problem == "the command is empty")
        #expect(PolicyLoosen.allowCommand(command: String(repeating: "a", count: 4097), reason: "x").problem
            == "the command is longer than 4096 bytes")
        #expect(PolicyLoosen.packOff(pack: "core.git").problem == nil)
        #expect(PolicyLoosen.safetyNormal.problem == nil)
        #expect(throws: LoosenProposalError.invalid("a reason is required")) {
            try LoosenProposalLedger.propose(
                .allowRule(rule: "core.git:x", reason: ""), from: nil, cwd: nil, records: [], now: Self.now)
        }
    }

    @Test func aChangeDecodesStrictly() throws {
        let decoder = JSONDecoder()
        let good = #"{"kind":"packOff","pack":"core.git"}"#
        #expect(try decoder.decode(PolicyLoosen.self, from: Data(good.utf8)) == .packOff(pack: "core.git"))
        for bad in [
            #"{"kind":"packOff","pack":"core.git","enabled":true}"#,
            #"{"kind":"hostOff","host":"claude"}"#,
            #"{"kind":"safetyNormal","level":"off"}"#,
            #"{"kind":"allowRule","rule":"core.git:x"}"#,
        ] {
            #expect(throws: DecodingError.self) { try decoder.decode(PolicyLoosen.self, from: Data(bad.utf8)) }
        }
        let encoded = try JSONEncoder().encode(Self.change)
        #expect(try decoder.decode(PolicyLoosen.self, from: encoded) == Self.change)
    }

    @Test func proposalIDsAreStrict() {
        #expect(ProposalID(rawValue: "p-21")?.number == 21)
        for bad in ["p-", "p21", "p-2a", "p-1234567890", "P-1", " p-1"] {
            #expect(ProposalID(rawValue: bad) == nil)
        }
    }

    @Test func theStoreRoundTripsAndSweeps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-loosen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LoosenProposalStore(configDirectory: directory)
        let filed = try store.propose(Self.change, from: "claude", cwd: nil, now: Self.now)
        #expect(filed.created)
        let listed = try store.list(now: Self.now)
        #expect(listed.all == [filed.proposal])
        let later = try store.list(now: Self.now.addingTimeInterval(LoosenProposalLedger.lifetime))
        #expect(later.expiredNow.map(\.id) == [filed.proposal.id])
        #expect(try store.list(now: Self.now).all.first?.status == .expired)
    }
}
