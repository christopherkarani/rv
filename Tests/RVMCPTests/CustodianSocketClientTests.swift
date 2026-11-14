#if os(Linux)
import Foundation
import Glibc
import Synchronization
import Testing

@testable import RVMCP

/// The Linux custodian client against a key daemon and a presence helper
/// running in this process, over real Unix sockets, and the custodian's
/// key store on a real directory.
@Suite("MCP custodian socket client")
struct CustodianSocketClientTests {
    /// A key daemon (the real service over a real store) and a presence
    /// helper whose only PAM is "the answer is `right`".
    private final class Host: Sendable {
        let directory: URL
        let path: String
        let presencePath: String
        let service: Mutex<MCPCustodianSocketService>
        /// What the helper answers a correct password with; `.proved` attests.
        let helperResult = Mutex<MCPPresenceResult>(.proved)
        let prompts = Mutex(0)
        private let listeners = Mutex<[Int32]>([])

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-cust-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("state"), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            path = directory.appendingPathComponent("c.sock").path
            presencePath = directory.appendingPathComponent("p.sock").path
            let store = MCPCustodianStore(directory: directory.appendingPathComponent("state"))
            // The helper is "uid 4294967294": no real connection is it, so
            // only this test's own call can attest.
            service = Mutex(MCPCustodianSocketService(presenceUID: UInt32.max - 1, storage: store.storage))
            try listen(path) { [self] fd in keyDaemon(fd) }
            try listen(presencePath) { [self] fd in presenceHelper(fd) }
        }

        func stop() {
            listeners.withLock { $0.forEach { shutdown($0, Int32(SHUT_RDWR)); close($0) } }
            try? FileManager.default.removeItem(at: directory)
        }

        private func listen(_ path: String, _ serve: @escaping @Sendable (Int32) -> Void) throws {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
            let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            try #require(fd >= 0 && bound && Glibc.listen(fd, 16) == 0)
            listeners.withLock { $0.append(fd) }
            Thread.detachNewThread {
                while true {
                    let connection = accept(fd, nil, nil)
                    guard connection >= 0 else { return }
                    Thread.detachNewThread { serve(connection) }
                }
            }
        }

        private func keyDaemon(_ fd: Int32) {
            defer { close(fd) }
            guard let peer = MCPCustodianPeer(socket: fd) else { return }
            let id = UInt64(fd) + 1
            service.withLock { $0.open(id, peer: peer) }
            defer { service.withLock { $0.close(id) } }
            while let request = MCPCustodianFrame.read(MCPCustodianSocketRequest.self, from: fd) {
                guard let response = service.withLock({ $0.handle(id, request, now: .now) }),
                    MCPCustodianFrame.write(response, to: fd)
                else { return }
            }
        }

        private func presenceHelper(_ fd: Int32) {
            defer { close(fd) }
            guard case .prove(let version, let challenge)? = MCPCustodianFrame.read(MCPPresenceRequest.self, from: fd),
                version == MCPCustodianSocket.protocolVersion
            else {
                _ = MCPCustodianFrame.write(MCPPresenceResponse.result(.badRequest), to: fd)
                return
            }
            _ = MCPCustodianFrame.write(MCPPresenceResponse.notice("checking \u{1B}[2Jyou"), to: fd)
            prompts.withLock { $0 += 1 }
            guard MCPCustodianFrame.write(MCPPresenceResponse.prompt(text: "Password: ", secret: true), to: fd),
                case .answer(let typed)? = MCPCustodianFrame.read(MCPPresenceRequest.self, from: fd)
            else { return }
            var result = typed == "right" ? helperResult.withLock { $0 } : .authenticationFailed
            if result == .proved {
                let attested = service.withLock { service -> MCPCustodianSocketResponse? in
                    service.open(0, peer: MCPCustodianPeer(uid: UInt32.max - 1, pid: 1))
                    _ = service.handle(0, .hello(protocolVersion: MCPCustodianSocket.protocolVersion), now: .now)
                    return service.handle(0, .attest(challenge: challenge, uid: getuid()), now: .now)
                }
                result = attested == .attested(true) ? .proved : .rejected
            }
            _ = MCPCustodianFrame.write(MCPPresenceResponse.result(result), to: fd)
        }

        func client(custodianUID: uid_t? = getuid(), presenceUID: uid_t = getuid()) -> MCPCustodianSocketClient {
            MCPCustodianSocketClient(
                path: path, presencePath: presencePath, custodianUID: { custodianUID }, presenceUID: presenceUID)
        }
    }

    /// A terminal that answers every prompt with `answer` and records what it showed.
    private final class Terminal: Sendable {
        let answer: String?
        let shown = Mutex<[String]>([])
        init(_ answer: String?) { self.answer = answer }
        var value: MCPCustodianTerminal {
            MCPCustodianTerminal(
                ask: { text, secret in
                    self.shown.withLock { $0.append("\(secret ? "secret" : "visible"): \(text)") }
                    return self.answer
                },
                show: { text in self.shown.withLock { $0.append(text) } })
        }
    }

    private let scope = "/home/me/.config/rv"

    @Test(.timeLimit(.minutes(1)))
    func whatNeedsNoPresenceWorksWithNoTerminal() throws {
        let host = try Host()
        defer { host.stop() }
        let client = host.client()
        #expect(client.isInstalled)
        let signing = MCPApprovalSigning.custodian(transport: client.transport(scope: scope, terminal: { nil }))
        #expect(signing.status() == .notEnrolled)
        let code = try #require(signing.mac(.code, ["c"], true))
        #expect(MCPCounterMAC(code)?.counter == 1)
        #expect(signing.status() == .enrolled)
        #expect(signing.verify(code, .code, ["c"]) == .valid)
        #expect(signing.verify(code, .code, ["d"]) == .forged)
        // What the owner must decide is not signed for a process with no terminal.
        #expect(signing.mac(.grant, ["call"], true) == nil)
        #expect(signing.mac(.mcpJSON, ["digest"], true) == nil)
        #expect(host.prompts.withLock { $0 } == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func theOwnersAnswerUnlocksThisConnectionOnce() throws {
        let host = try Host()
        defer { host.stop() }
        let client = host.client()
        let terminal = Terminal("right")
        let signing = MCPApprovalSigning.custodian(transport: client.transport(scope: scope, terminal: { terminal.value }))
        let config = try #require(signing.mac(.mcpJSON, ["digest"], true))
        // One prompt covers the signatures of one operation.
        let pins = try #require(signing.mac(.mcpJSON, ["pins", "digest"], true))
        #expect(host.prompts.withLock { $0 } == 1)
        #expect(signing.verify(config, .mcpJSON, ["digest"]) == .valid)
        #expect(signing.verify(pins, .mcpJSON, ["pins", "digest"]) == .valid)
        // What the helper says is shown with hiding characters made visible.
        let shown = terminal.shown.withLock { $0 }
        #expect(shown.contains("secret: Password: "))
        #expect(shown.contains { $0.contains("checking") && $0.contains("\u{1B}") == false })
        // `beginFreshAuth` is answered locally: the window the owner opened stays.
        signing.beginFreshAuth()
        #expect(signing.mac(.grant, ["call"], true) != nil)
        #expect(host.prompts.withLock { $0 } == 1)
        // Another process of the same account (another connection) is not unlocked.
        let other = MCPApprovalSigning.custodian(transport: host.client().transport(scope: scope, terminal: { nil }))
        #expect(other.mac(.grant, ["call"], true) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func provingPresenceFirstIsWhatTheSignatureThenUses() throws {
        let host = try Host()
        defer { host.stop() }
        let client = host.client()
        #expect(client.provePresence(reason: "rv: trust mcp.json", terminal: Terminal("right").value) == .proved)
        let signing = MCPApprovalSigning.custodian(transport: client.transport(scope: scope, terminal: { nil }))
        #expect(signing.mac(.grant, ["call"], true) != nil)
        #expect(host.prompts.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        (MCPPresenceResult.nothingAsked, "not proof you are present"), (.busy, "in progress"),
        (.rejected, "did not accept"), (.unavailable, "could not use PAM"), (.noAccount, "does not sign for this account"),
        (.badRequest, "did not understand"),
    ])
    func everythingButAProofSignsNothing(result: MCPPresenceResult, text: String) throws {
        let host = try Host()
        defer { host.stop() }
        host.helperResult.withLock { $0 = result }
        let client = host.client()
        guard case .refused(let why) = client.provePresence(reason: "rv: x", terminal: Terminal("right").value) else {
            Issue.record("\(result) proved presence")
            return
        }
        #expect(why.contains(text), "\(why)")
        let signing = MCPApprovalSigning.custodian(transport: client.transport(scope: scope, terminal: { nil }))
        #expect(signing.mac(.grant, ["call"], true) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aWrongAnswerNoAnswerAndNoTerminalAreRefusals() throws {
        let host = try Host()
        defer { host.stop() }
        let client = host.client()
        #expect(client.provePresence(reason: "rv: x", terminal: Terminal("wrong").value) == .refused("authentication failed"))
        #expect(client.provePresence(reason: "rv: x", terminal: Terminal(nil).value) == .refused("authentication was cancelled"))
        guard case .refused(let why) = client.provePresence(reason: "rv: x", terminal: nil) else {
            Issue.record("presence was proved with no terminal")
            return
        }
        #expect(why.contains("no terminal"))
        let signing = MCPApprovalSigning.custodian(transport: client.transport(scope: scope, terminal: { Terminal("wrong").value }))
        #expect(signing.mac(.grant, ["call"], true) == nil)
    }

    /// The daemons must be the accounts they should be: a listener some
    /// other account started at those paths is not the custodian.
    @Test(.timeLimit(.minutes(1)))
    func aPeerThatIsNotTheCustodiansAccountIsNotTalkedTo() throws {
        let host = try Host()
        defer { host.stop() }
        let wrongDaemon = host.client(custodianUID: getuid() &+ 1)
        let signing = MCPApprovalSigning.custodian(transport: wrongDaemon.transport(scope: scope, terminal: { nil }))
        #expect(signing.status() == .unavailable)
        #expect(signing.mac(.code, ["c"], true) == nil)
        #expect(signing.verify("v1.1." + String(repeating: "a", count: 64), .code, ["c"]) == .noKey)
        let noAccount = host.client(custodianUID: nil)
        #expect(MCPApprovalSigning.custodian(transport: noAccount.transport(scope: scope, terminal: { nil })).status() == .unavailable)
        let wrongHelper = host.client(presenceUID: getuid() &+ 1)
        guard case .refused(let why) = wrongHelper.provePresence(reason: "rv: x", terminal: Terminal("right").value) else {
            Issue.record("a helper of another account was believed")
            return
        }
        #expect(why.contains("presence helper is not answering"))
        #expect(host.prompts.withLock { $0 } == 0)
    }

    @Test func aCustodianIsInstalledOnlyWhereItsSocketIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-cust-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("c.sock").path
        func client() -> MCPCustodianSocketClient {
            MCPCustodianSocketClient(path: path, presencePath: path, custodianUID: { getuid() }, presenceUID: getuid())
        }
        #expect(client().isInstalled == false)
        try Data().write(to: URL(fileURLWithPath: path))
        // A file that is not a socket is not a custodian.
        #expect(client().isInstalled == false)
        #expect(MCPApprovalSigning.custodian(transport: client().transport(scope: scope, terminal: { nil })).status() == .unavailable)
        #expect(MCPCustodianSocket.path.hasPrefix("/run/") && MCPCustodianSocket.presencePath.hasPrefix("/run/"))
    }

    // MARK: - The key store

    @Test func theStoreKeepsOneKeyAndLedgerPerAccountAndRefusesWhatIsNotItsOwn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPCustodianStore(directory: directory)
        let storage = store.storage
        #expect(try storage.loadKey(1000).get() == nil)
        #expect(try storage.loadLedger(1000).get() == MCPCustodianLedger())
        let key = try storage.createKey(1000).get()
        // Created once: a second create returns the same key.
        #expect(try storage.createKey(1000).get().mac("p", ["f"]) == key.mac("p", ["f"]))
        #expect(try storage.loadKey(1000).get()?.mac("p", ["f"]) == key.mac("p", ["f"]))
        #expect(try storage.createKey(1001).get().mac("p", ["f"]) != key.mac("p", ["f"]))
        var info = stat()
        #expect(stat(store.keyURL(1000).path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(stat(store.account(1000).path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        var ledger = MCPCustodianLedger()
        _ = ledger.issue(purpose: .grant, scope: "/s", fields: ["g"])
        #expect(storage.saveLedger(1000, ledger))
        #expect(try storage.loadLedger(1000).get() == ledger)
        #expect(try storage.loadLedger(1001).get() == MCPCustodianLedger())
        // A key others can read, a truncated one, and a ledger that is not
        // one are failures, never "no key" or "an empty ledger".
        #expect(chmod(store.keyURL(1000).path, 0o644) == 0)
        #expect(storage.loadKey(1000) == .failure(.init()))
        #expect(chmod(store.keyURL(1000).path, 0o600) == 0)
        try Data("short".utf8).write(to: store.keyURL(1001))
        #expect(storage.loadKey(1001) == .failure(.init()))
        try Data("{".utf8).write(to: store.ledgerURL(1000))
        #expect(chmod(store.ledgerURL(1000).path, 0o600) == 0)
        #expect(storage.loadLedger(1000) == .failure(.init()))
    }
}

extension Result where Success == MCPSigner?, Failure == MCPCustodianSocketService.StorageFailure {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.failure, .failure): true
        case (.success(let a), .success(let b)): a?.mac("p", []) == b?.mac("p", [])
        default: false
        }
    }
}
#endif
