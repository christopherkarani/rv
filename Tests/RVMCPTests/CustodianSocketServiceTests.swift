import Foundation
import Synchronization
import Testing

@testable import RVMCP

/// The approvals custodian's socket protocol and its decisions, with keys
/// and ledgers in memory: who may ask what, when the owner must be
/// present, and what a rolled-back or replayed MAC gets.
@Suite("MCP custodian socket service")
struct CustodianSocketServiceTests {
    /// In-memory storage: one key and one ledger per uid.
    private final class Memory: Sendable {
        let keys = Mutex<[UInt32: [UInt8]]>([:])
        let ledgers = Mutex<[UInt32: MCPCustodianLedger]>([:])
        let failing = Mutex<Set<String>>([])

        func fails(_ operation: String) -> Bool { failing.withLock { $0.contains(operation) } }

        var storage: MCPCustodianSocketService.Storage {
            .init(
                loadKey: { uid in
                    if self.fails("loadKey") { return .failure(.init()) }
                    return .success(self.keys.withLock { $0[uid] }.flatMap(MCPSigner.init(key:)))
                },
                createKey: { uid in
                    if self.fails("createKey") { return .failure(.init()) }
                    let key = self.keys.withLock { keys -> [UInt8] in
                        if let key = keys[uid] { return key }
                        let key = MCPApprovalSigning.newKey()
                        keys[uid] = key
                        return key
                    }
                    return MCPSigner(key: key).map { .success($0) } ?? .failure(.init())
                },
                loadLedger: { uid in
                    if self.fails("loadLedger") { return .failure(.init()) }
                    return .success(self.ledgers.withLock { $0[uid] } ?? MCPCustodianLedger())
                },
                saveLedger: { uid, ledger in
                    if self.fails("saveLedger") { return false }
                    self.ledgers.withLock { $0[uid] = ledger }
                    return true
                })
        }
    }

    /// The service by reference: an expectation cannot call a mutating
    /// method on a value it captured.
    private final class Daemon {
        var value: MCPCustodianSocketService
        init(_ value: MCPCustodianSocketService) { self.value = value }
        func open(_ id: UInt64, peer: MCPCustodianPeer) { value.open(id, peer: peer) }
        func close(_ id: UInt64) { value.close(id) }
        func handle(
            _ id: UInt64, _ request: MCPCustodianSocketRequest, now: ContinuousClock.Instant
        ) -> MCPCustodianSocketResponse? {
            value.handle(id, request, now: now)
        }
    }

    /// The ledger by reference, for the same reason.
    private final class Ledger {
        var value = MCPCustodianLedger()
        func issue(purpose: MCPMACPurpose, scope: String, fields: [String]) -> UInt64? {
            value.issue(purpose: purpose, scope: scope, fields: fields)
        }
        func accept(counter: UInt64, purpose: MCPMACPurpose, scope: String, fields: [String]) -> Bool {
            value.accept(counter: counter, purpose: purpose, scope: scope, fields: fields)
        }
    }

    private let owner: UInt32 = 1000
    private let other: UInt32 = 1001
    private let scope = "/home/me/.config/rv"
    private let start = ContinuousClock.now

    private func service(_ memory: Memory) -> MCPCustodianSocketService {
        let counter = Mutex(0)
        return MCPCustodianSocketService(storage: memory.storage) {
            let next = counter.withLock { value -> Int in
                value += 1
                return value
            }
            return String(repeating: "0", count: 62) + String(format: "%02x", next)
        }
    }

    /// Opens a connection for `uid` and greets on it.
    private func connect(_ service: Daemon, _ id: UInt64, uid: UInt32) {
        service.open(id, peer: MCPCustodianPeer(uid: uid))
        #expect(service.handle(id, .hello(protocolVersion: MCPCustodianSocket.protocolVersion), now: start)
            == .hello(ok: true, protocolVersion: MCPCustodianSocket.protocolVersion))
    }

    private func mac(
        _ service: Daemon, _ id: UInt64, _ purpose: MCPMACPurpose, _ fields: [String],
        create: Bool = true, scope: String? = nil, at now: ContinuousClock.Instant? = nil
    ) -> MCPCustodianSocketResponse? {
        service.handle(
            id, .key(scope: scope ?? self.scope, request: .mac(purpose: purpose, fields: fields, createIfMissing: create)),
            now: now ?? start)
    }

    private func verify(
        _ service: Daemon, _ id: UInt64, _ candidate: String?, _ purpose: MCPMACPurpose,
        _ fields: [String], scope: String? = nil
    ) -> MCPCustodianSocketResponse? {
        service.handle(
            id, .key(scope: scope ?? self.scope, request: .verify(candidate: candidate, purpose: purpose, fields: fields)),
            now: start)
    }

    /// The owner authenticates for connection `id`: a challenge, then the
    /// helper's attestation on its own connection (99).
    private func prove(
        _ service: Daemon, _ id: UInt64, uid: UInt32, at now: ContinuousClock.Instant? = nil
    ) -> Bool {
        guard case .challenge(let challenge)? = service.handle(id, .challenge, now: now ?? start) else { return false }
        if service.handle(99, .hello(protocolVersion: MCPCustodianSocket.protocolVersion), now: start) == nil {
            connect(service, 99, uid: 0)
        }
        return service.handle(99, .attest(challenge: challenge, uid: uid), now: now ?? start) == .attested(true)
    }

    private func text(_ response: MCPCustodianSocketResponse?) -> String? {
        guard case .key(.mac(let value?))? = response else { return nil }
        return value
    }

    // MARK: - Wire

    @Test func aFrameIsALengthAndABodyWithinTheBound() throws {
        let frame = try #require(MCPCustodianFrame.encode(MCPCustodianSocketRequest.challenge))
        #expect(MCPCustodianFrame.bodyLength(header: Array(frame[0..<4])) == frame.count - 4)
        #expect(MCPCustodianFrame.decode(MCPCustodianSocketRequest.self, body: Array(frame[4...])) == .challenge)
        #expect(MCPCustodianFrame.bodyLength(header: [0, 8, 0, 0]) == MCPCustodianSocket.maximumFrameBytes)
        #expect(MCPCustodianFrame.bodyLength(header: [0, 8, 0, 1]) == nil)
        #expect(MCPCustodianFrame.bodyLength(header: [0xff, 0xff, 0xff, 0xff]) == nil)
        #expect(MCPCustodianFrame.bodyLength(header: [0, 0, 0]) == nil)
        let oversized = MCPPresenceRequest.answer(String(repeating: "x", count: MCPCustodianSocket.maximumFrameBytes))
        #expect(MCPCustodianFrame.encode(oversized) == nil)
        #expect(MCPCustodianFrame.decode(MCPCustodianSocketRequest.self, body: Array("{\"attest\":{}}".utf8)) == nil)
        #expect(MCPCustodianFrame.decode(MCPCustodianSocketRequest.self, body: []) == nil)
    }

    @Test func everyMessageSurvivesTheWire() throws {
        let requests: [MCPCustodianSocketRequest] = [
            .hello(protocolVersion: "x"), .challenge, .attest(challenge: "c", uid: 7),
            .key(scope: scope, request: .mac(purpose: .grant, fields: ["a", "b"], createIfMissing: true)),
            .key(scope: scope, request: .verify(candidate: nil, purpose: .mcpJSON, fields: [])),
        ]
        for request in requests {
            let frame = try #require(MCPCustodianFrame.encode(request))
            #expect(MCPCustodianFrame.decode(MCPCustodianSocketRequest.self, body: Array(frame[4...])) == request)
        }
        let responses: [MCPCustodianSocketResponse] = [
            .hello(ok: true, protocolVersion: "x"), .presenceRequired, .challenge("c"), .attested(false),
            .error(.unauthorized), .key(.mac("m")), .key(.verify(nil)), .key(.status(.enrolled)),
        ]
        for response in responses {
            let frame = try #require(MCPCustodianFrame.encode(response))
            #expect(MCPCustodianFrame.decode(MCPCustodianSocketResponse.self, body: Array(frame[4...])) == response)
        }
        for message in [MCPPresenceResponse.prompt(text: "Password: ", secret: true), .notice("x"), .result(.proved)] {
            let frame = try #require(MCPCustodianFrame.encode(message))
            #expect(MCPCustodianFrame.decode(MCPPresenceResponse.self, body: Array(frame[4...])) == message)
        }
    }

    @Test func aCounterMACIsItsVersionCounterAndHex() {
        let hex = String(repeating: "ab", count: 32)
        #expect(MCPCounterMAC("v1.7.\(hex)") == MCPCounterMAC(counter: 7, hex: hex))
        #expect(MCPCounterMAC(counter: 18_446_744_073_709_551_615, hex: hex).text.utf8.count <= MCPCustodianWire.maximumCandidateBytes)
        #expect(MCPCounterMAC("v1.18446744073709551615.\(hex)")?.counter == UInt64.max)
        for malformed in [
            hex, "v2.7.\(hex)", "v1..\(hex)", "v1.07.\(hex)", "v1.-1.\(hex)", "v1.7.\(hex)0", "v1.7", "v1.7.\(hex).x",
            "v1.18446744073709551616.\(hex)", "v1. 7.\(hex)", "",
        ] {
            #expect(MCPCounterMAC(malformed) == nil, "\(malformed)")
        }
        #expect(MCPCounterMAC.fields(scope: "/s", counter: 3, ["a"]) == ["rv.mcp-custodian.mac.v1", "/s", "3", "a"])
    }

    @Test func scopesAndChallengesAreBounded() {
        #expect(MCPCustodianSocket.isValid(scope: "/home/me/.config/rv"))
        #expect(MCPCustodianSocket.isValid(scope: "relative") == false)
        #expect(MCPCustodianSocket.isValid(scope: "") == false)
        #expect(MCPCustodianSocket.isValid(scope: "/" + String(repeating: "a", count: MCPCustodianSocket.maximumScopeBytes)) == false)
        #expect(MCPCustodianSocket.isValid(scope: "/a\u{0}b") == false)
        #expect(MCPCustodianSocket.isValid(challenge: MCPCustodianSocketService.randomChallenge()))
        #expect(MCPCustodianSocketService.randomChallenge() != MCPCustodianSocketService.randomChallenge())
        #expect(MCPCustodianSocket.isValid(challenge: String(repeating: "A", count: 64)) == false)
        #expect(MCPCustodianSocket.isValid(challenge: String(repeating: "a", count: 63)) == false)
    }

    // MARK: - Ledger

    @Test func theCounterOnlyRisesAndTheNewestSignatureOfAFileWins() throws {
        let ledger = Ledger()
        let first = try #require(ledger.issue(purpose: .mcpJSON, scope: scope, fields: ["digest-1"]))
        let pins = try #require(ledger.issue(purpose: .mcpJSON, scope: scope, fields: ["pins", "digest-p"]))
        let second = try #require(ledger.issue(purpose: .mcpJSON, scope: scope, fields: ["digest-2"]))
        #expect([first, pins, second] == [1, 2, 3])
        // The older signature of the same file no longer verifies; the
        // other file's, and another scope's, are their own slots.
        #expect(ledger.accept(counter: first, purpose: .mcpJSON, scope: scope, fields: ["digest-1"]) == false)
        #expect(ledger.accept(counter: second, purpose: .mcpJSON, scope: scope, fields: ["digest-2"]))
        #expect(ledger.accept(counter: second, purpose: .mcpJSON, scope: scope, fields: ["digest-2"]))
        #expect(ledger.accept(counter: pins, purpose: .mcpJSON, scope: scope, fields: ["pins", "digest-p"]))
        let elsewhere = try #require(ledger.issue(purpose: .mcpJSON, scope: "/other", fields: ["digest-9"]))
        #expect(ledger.accept(counter: second, purpose: .mcpJSON, scope: scope, fields: ["digest-2"]))
        #expect(ledger.accept(counter: elsewhere, purpose: .mcpJSON, scope: "/other", fields: ["digest-9"]))
        // A counter the ledger never issued.
        #expect(ledger.accept(counter: 0, purpose: .code, scope: scope, fields: []) == false)
        #expect(ledger.accept(counter: 99, purpose: .code, scope: scope, fields: []) == false)
        #expect(ledger.accept(counter: 1, purpose: .code, scope: scope, fields: []))
    }

    @Test func aGrantVerifiesOnceAndTheOldestGivesWayWhenTooManyAreOutstanding() throws {
        let ledger = Ledger()
        let grant = try #require(ledger.issue(purpose: .grant, scope: scope, fields: ["call"]))
        #expect(ledger.accept(counter: grant, purpose: .grant, scope: scope, fields: ["call"]))
        #expect(ledger.accept(counter: grant, purpose: .grant, scope: scope, fields: ["call"]) == false)
        var issued: [UInt64] = []
        for _ in 0...MCPCustodianLedger.maximumGrants {
            issued.append(try #require(ledger.issue(purpose: .grant, scope: scope, fields: ["call"])))
        }
        #expect(ledger.value.grants.count == MCPCustodianLedger.maximumGrants)
        #expect(ledger.accept(counter: issued[0], purpose: .grant, scope: scope, fields: ["call"]) == false)
        #expect(ledger.accept(counter: issued[1], purpose: .grant, scope: scope, fields: ["call"]))
    }

    @Test func tooManyFilesAreNotSigned() throws {
        let ledger = Ledger()
        for index in 0..<MCPCustodianLedger.maximumSlots {
            _ = try #require(ledger.issue(purpose: .mcpJSON, scope: "/scope-\(index)", fields: ["d"]))
        }
        #expect(ledger.issue(purpose: .mcpJSON, scope: "/one-more", fields: ["d"]) == nil)
        #expect(ledger.value.counter == UInt64(MCPCustodianLedger.maximumSlots))
        // A slot it already has can still be signed again.
        #expect(ledger.issue(purpose: .mcpJSON, scope: "/scope-0", fields: ["e"]) != nil)
    }

    @Test func theLedgerSurvivesItsOwnEncoding() throws {
        let ledger = Ledger()
        _ = ledger.issue(purpose: .mcpJSON, scope: scope, fields: ["d"])
        _ = ledger.issue(purpose: .grant, scope: scope, fields: ["g"])
        let decoded = try JSONDecoder().decode(MCPCustodianLedger.self, from: JSONEncoder().encode(ledger.value))
        #expect(decoded == ledger.value)
    }

    // MARK: - Who may ask what

    @Test func nothingIsAnsweredBeforeAHelloOfThisProtocol() {
        let memory = Memory()
        let service = Daemon(service(memory))
        service.open(1, peer: MCPCustodianPeer(uid: owner))
        #expect(service.handle(1, .challenge, now: start) == nil)
        #expect(service.handle(1, .key(scope: scope, request: .status), now: start) == nil)
        #expect(service.handle(1, .hello(protocolVersion: "rv.mcp-custodian.v2"), now: start)
            == .hello(ok: false, protocolVersion: MCPCustodianSocket.protocolVersion))
        #expect(service.handle(1, .key(scope: scope, request: .status), now: start) == nil)
        // A connection the service was never told about.
        #expect(service.handle(2, .hello(protocolVersion: MCPCustodianSocket.protocolVersion), now: start) == nil)
        service.close(1)
        #expect(service.handle(1, .hello(protocolVersion: MCPCustodianSocket.protocolVersion), now: start) == nil)
    }

    @Test func onlyTheHelperAttestsAndTheHelperDoesNothingElse() {
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        connect(service, 2, uid: other)
        connect(service, 9, uid: 0)
        guard case .challenge(let challenge)? = service.handle(1, .challenge, now: start) else {
            Issue.record("no challenge")
            return
        }
        // The owner, or another account, attesting for itself.
        #expect(service.handle(1, .attest(challenge: challenge, uid: owner), now: start) == .error(.unauthorized))
        #expect(service.handle(2, .attest(challenge: challenge, uid: owner), now: start) == .error(.unauthorized))
        #expect(mac(service, 1, .grant, ["call"]) == .presenceRequired)
        // The helper holds no key of its own and asks for no challenge.
        #expect(service.handle(9, .key(scope: scope, request: .status), now: start) == .error(.unauthorized))
        #expect(service.handle(9, .challenge, now: start) == .error(.unauthorized))
        #expect(memory.keys.withLock { $0.isEmpty })
    }

    @Test func aRequestOutsideTheBoundsIsABadRequest() {
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        let tooMany = [String](repeating: "f", count: MCPCustodianWire.maximumFields + 1)
        #expect(mac(service, 1, .code, tooMany) == .error(.badRequest))
        #expect(mac(service, 1, .code, ["f"], scope: "relative") == .error(.badRequest))
        let long = String(repeating: "x", count: MCPCustodianWire.maximumCandidateBytes + 1)
        #expect(verify(service, 1, long, .code, ["f"]) == .error(.badRequest))
        #expect(memory.keys.withLock { $0.isEmpty })
    }

    // MARK: - Admission

    /// The admission counts by reference, as `Daemon` and `Ledger` above.
    private final class Admission {
        var value = MCPCustodianAdmission()
        func admit(uid: UInt32, hasAccount: Bool) -> Bool { value.admit(uid: uid, hasAccount: hasAccount) }
        func release(uid: UInt32) { value.release(uid: uid) }
    }

    @Test func oneAccountCannotUseTheDaemonUpAndTheHelperAlwaysGetsThrough() {
        let admission = Admission()
        // A uid with no account on the host is not one of its users.
        #expect(admission.admit(uid: 100_003, hasAccount: false) == false)
        for _ in 0..<MCPCustodianAdmission.perAccount { #expect(admission.admit(uid: owner, hasAccount: true)) }
        #expect(admission.admit(uid: owner, hasAccount: true) == false)
        admission.release(uid: owner)
        #expect(admission.admit(uid: owner, hasAccount: true))
        // Many accounts fill what is not kept for the helper, and no more.
        var uid: UInt32 = 2000
        var admitted = MCPCustodianAdmission.perAccount
        while admission.admit(uid: uid, hasAccount: true) {
            admitted += 1
            if admitted.isMultiple(of: MCPCustodianAdmission.perAccount) { uid += 1 }
        }
        #expect(admitted == MCPCustodianAdmission.maximum - MCPCustodianAdmission.reservedForHelper)
        for _ in 0..<MCPCustodianAdmission.reservedForHelper { #expect(admission.admit(uid: 0, hasAccount: true)) }
        #expect(admission.admit(uid: 0, hasAccount: true) == false)
        admission.release(uid: 0)
        #expect(admission.admit(uid: 0, hasAccount: true))
        // Releasing what was never held changes nothing.
        admission.release(uid: 31_337)
        #expect(admission.admit(uid: 31_337, hasAccount: true) == false)
    }

    // MARK: - Presence

    @Test func whatTheGatewaySignsUnattendedNeedsNoPresenceAndWhatTheOwnerDecidesDoes() {
        for purpose in MCPMACPurpose.allCases {
            switch purpose {
            case .grant, .mcpJSON: #expect(purpose.needsOwnerPresence)
            case .code, .argumentKeys: #expect(purpose.needsOwnerPresence == false)
            }
        }
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        #expect(text(mac(service, 1, .code, ["c"])) != nil)
        #expect(text(mac(service, 1, .argumentKeys, ["k"])) != nil)
        #expect(mac(service, 1, .grant, ["call"]) == .presenceRequired)
        #expect(mac(service, 1, .mcpJSON, ["digest"]) == .presenceRequired)
        // Refused before any key or counter is touched.
        #expect(memory.ledgers.withLock { $0[owner]?.counter } == 2)
    }

    @Test func aProofUnlocksOnlyTheConnectionThatAskedForAWhileAndAFewUses() throws {
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        connect(service, 2, uid: owner)
        #expect(prove(service, 1, uid: owner))
        // Another connection of the same account is not unlocked.
        #expect(mac(service, 2, .grant, ["call"]) == .presenceRequired)
        #expect(text(mac(service, 1, .grant, ["call"])) != nil)
        #expect(text(mac(service, 1, .mcpJSON, ["digest"])) != nil)
        // The window ends.
        let later = start + MCPCustodianSocket.presenceWindow
        #expect(mac(service, 1, .grant, ["call"], at: later) == .presenceRequired)
        // So do its uses.
        #expect(prove(service, 1, uid: owner))
        for _ in 0..<MCPCustodianSocket.presenceUses {
            #expect(text(mac(service, 1, .grant, ["call"])) != nil)
        }
        #expect(mac(service, 1, .grant, ["call"]) == .presenceRequired)
        // `beginFreshAuth` ends it at once.
        #expect(prove(service, 1, uid: owner))
        #expect(service.handle(1, .key(scope: scope, request: .beginFreshAuth), now: start) == .key(.status(.enrolled)))
        #expect(mac(service, 1, .grant, ["call"]) == .presenceRequired)
    }

    @Test func aChallengeIsUsedOnceByItsOwnAccountBeforeItExpires() throws {
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        connect(service, 9, uid: 0)
        func challenge(at now: ContinuousClock.Instant? = nil) throws -> String {
            guard case .challenge(let value)? = service.handle(1, .challenge, now: now ?? start) else {
                throw MCPCustodianSocketService.StorageFailure()
            }
            return value
        }
        // Attested for another account: refused, and the challenge is spent.
        let first = try challenge()
        #expect(service.handle(9, .attest(challenge: first, uid: other), now: start) == .attested(false))
        #expect(service.handle(9, .attest(challenge: first, uid: owner), now: start) == .attested(false))
        // Expired.
        let second = try challenge()
        let late = start + MCPCustodianSocket.challengeLifetime
        #expect(service.handle(9, .attest(challenge: second, uid: owner), now: late) == .attested(false))
        // A new challenge replaces the one before it.
        let third = try challenge()
        let fourth = try challenge()
        #expect(third != fourth)
        #expect(service.handle(9, .attest(challenge: third, uid: owner), now: start) == .attested(false))
        #expect(service.handle(9, .attest(challenge: fourth, uid: owner), now: start) == .attested(true))
        // Replayed.
        #expect(service.handle(9, .attest(challenge: fourth, uid: owner), now: start) == .attested(false))
        // Not a challenge at all, and one no connection holds.
        #expect(service.handle(9, .attest(challenge: "", uid: owner), now: start) == .attested(false))
        #expect(service.handle(9, .attest(challenge: String(repeating: "f", count: 64), uid: owner), now: start) == .attested(false))
        // A closed connection's challenge is gone with it.
        let fifth = try challenge()
        service.close(1)
        #expect(service.handle(9, .attest(challenge: fifth, uid: owner), now: start) == .attested(false))
    }

    // MARK: - Keys, MACs and rollback

    @Test func aMACVerifiesOnlyForItsAccountScopePurposeAndFields() throws {
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        connect(service, 2, uid: other)
        #expect(service.handle(1, .key(scope: scope, request: .status), now: start) == .key(.status(.notEnrolled)))
        #expect(verify(service, 1, "v1.1." + String(repeating: "a", count: 64), .code, ["c"]) == .key(.verify(nil)))
        // No key is made unless asked.
        #expect(mac(service, 1, .code, ["c"], create: false) == .key(.mac(nil)))
        let issued = try #require(text(mac(service, 1, .code, ["c"])))
        #expect(MCPCounterMAC(issued)?.counter == 1)
        #expect(service.handle(1, .key(scope: scope, request: .status), now: start) == .key(.status(.enrolled)))
        #expect(verify(service, 1, issued, .code, ["c"]) == .key(.verify(true)))
        #expect(verify(service, 1, issued, .code, ["d"]) == .key(.verify(false)))
        #expect(verify(service, 1, issued, .argumentKeys, ["c"]) == .key(.verify(false)))
        #expect(verify(service, 1, issued, .code, ["c"], scope: "/elsewhere") == .key(.verify(false)))
        #expect(verify(service, 1, nil, .code, ["c"]) == .key(.verify(false)))
        #expect(verify(service, 1, String(issued.dropFirst(3)), .code, ["c"]) == .key(.verify(false)))
        // The same MAC under a counter it was not issued with.
        let forged = MCPCounterMAC(counter: 2, hex: try #require(MCPCounterMAC(issued)).hex).text
        #expect(verify(service, 1, forged, .code, ["c"]) == .key(.verify(false)))
        // Another account has its own key: no key yet, then a different one.
        #expect(verify(service, 2, issued, .code, ["c"]) == .key(.verify(nil)))
        _ = mac(service, 2, .code, ["c"])
        #expect(verify(service, 2, issued, .code, ["c"]) == .key(.verify(false)))
        #expect(memory.keys.withLock { $0[owner] != $0[other] })
    }

    @Test func anOlderSignedFilePutBackDoesNotVerify() throws {
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        connect(service, 2, uid: owner)
        #expect(prove(service, 1, uid: owner))
        let old = try #require(text(mac(service, 1, .mcpJSON, ["digest-old"])))
        let pins = try #require(text(mac(service, 1, .mcpJSON, ["pins", "digest-pins"])))
        #expect(verify(service, 2, old, .mcpJSON, ["digest-old"]) == .key(.verify(true)))
        let new = try #require(text(mac(service, 1, .mcpJSON, ["digest-new"])))
        // The old file and its old signature, restored together.
        #expect(verify(service, 2, old, .mcpJSON, ["digest-old"]) == .key(.verify(false)))
        #expect(verify(service, 2, new, .mcpJSON, ["digest-new"]) == .key(.verify(true)))
        #expect(verify(service, 2, pins, .mcpJSON, ["pins", "digest-pins"]) == .key(.verify(true)))
    }

    @Test func aGrantIsConsumedByItsFirstVerificationOnly() throws {
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        connect(service, 2, uid: owner)
        #expect(prove(service, 1, uid: owner))
        let grant = try #require(text(mac(service, 1, .grant, ["call"])))
        // A check that fails does not use it up.
        #expect(verify(service, 2, grant, .grant, ["another call"]) == .key(.verify(false)))
        #expect(verify(service, 2, grant, .grant, ["call"]) == .key(.verify(true)))
        // The granted row copied aside and put back after it was used.
        #expect(verify(service, 2, grant, .grant, ["call"]) == .key(.verify(false)))
    }

    @Test func storageThatFailsSignsNothingAndVerifiesNothing() throws {
        let memory = Memory()
        let service = Daemon(service(memory))
        connect(service, 1, uid: owner)
        #expect(prove(service, 1, uid: owner))
        let grant = try #require(text(mac(service, 1, .grant, ["call"])))
        let code = try #require(text(mac(service, 1, .code, ["c"])))
        for operation in ["loadKey", "loadLedger", "saveLedger"] {
            memory.failing.withLock { $0 = [operation] }
            #expect(mac(service, 1, .code, ["c"]) == .key(.error(.unavailable)), "\(operation)")
            // A grant's use cannot be recorded: it is not reported valid.
            #expect(verify(service, 1, grant, .grant, ["call"]) == .key(.error(.unavailable)), "\(operation)")
        }
        memory.failing.withLock { $0 = ["loadKey"] }
        #expect(service.handle(1, .key(scope: scope, request: .status), now: start) == .key(.status(.unavailable)))
        #expect(verify(service, 1, code, .code, ["c"]) == .key(.error(.unavailable)))
        memory.failing.withLock { $0 = ["saveLedger"] }
        // Nothing to record for a code: it still verifies.
        #expect(verify(service, 1, code, .code, ["c"]) == .key(.verify(true)))
        memory.failing.withLock { $0 = [] }
        // The failed attempts used nothing up.
        #expect(verify(service, 1, grant, .grant, ["call"]) == .key(.verify(true)))
        // A key that cannot be created.
        connect(service, 2, uid: other)
        memory.failing.withLock { $0 = ["createKey"] }
        #expect(mac(service, 2, .code, ["c"]) == .key(.error(.unavailable)))
    }

    /// The client seam reads a socket custodian's answers as it reads the
    /// macOS one's: anything but the matching answer fails closed.
    @Test func theSigningSeamOverTheServiceFailsClosed() throws {
        let memory = Memory()
        let box = Mutex(service(memory))
        let owner = self.owner
        let start = self.start
        box.withLock {
            $0.open(1, peer: MCPCustodianPeer(uid: owner))
            _ = $0.handle(1, .hello(protocolVersion: MCPCustodianSocket.protocolVersion), now: start)
        }
        let scope = self.scope
        let signing = MCPApprovalSigning.custodian { request in
            guard case .key(let response)? = box.withLock({ $0.handle(1, .key(scope: scope, request: request), now: start) })
            else { return nil }
            return response
        }
        #expect(signing.status() == .notEnrolled)
        // No proof of presence: nothing is signed, and nothing verifies as valid.
        #expect(signing.mac(.grant, ["call"], true) == nil)
        let code = try #require(signing.mac(.code, ["c"], true))
        #expect(signing.verify(code, .code, ["c"]) == .valid)
        #expect(signing.verify(code, .code, ["d"]) == .forged)
        #expect(signing.honorsGrants && signing.custodyIsSameUser == false)
    }
}
