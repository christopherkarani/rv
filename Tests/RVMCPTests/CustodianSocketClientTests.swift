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
        /// The key daemon hangs up after this many answers on a connection
        /// (as it does when one has been idle); nil: never.
        let answersPerConnection = Mutex<Int?>(nil)
        /// Run on a connection the key daemon hangs up, after its last
        /// answer is written and before its descriptor is closed: where a
        /// starved runner can leave the thread. Nil: straight on.
        let whileHangingUp = Mutex<(@Sendable () -> Void)?>(nil)
        /// Run once the helper has told the key daemon the owner answered.
        let afterAttesting = Mutex<(@Sendable () -> Void)?>(nil)
        let connections = Mutex(0)
        private let listeners = Mutex<[Int32]>([])
        private let stopped = Mutex(false)

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

        /// Shut down, not closed: each accepting thread closes its own
        /// descriptor when its `accept` fails. Closed here, the number could
        /// be another test's listener by the time that thread accepts
        /// again, and this host would answer the other test's client.
        func stop() {
            stopped.withLock { $0 = true }
            listeners.withLock { $0.forEach { shutdown($0, Int32(SHUT_RDWR)) } }
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
            Thread.detachNewThread { [self] in
                while true {
                    let connection = accept(fd, nil, nil)
                    guard connection >= 0, stopped.withLock({ $0 }) == false else {
                        if connection >= 0 { close(connection) }
                        close(fd)
                        return
                    }
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
            connections.withLock { $0 += 1 }
            var answered = 0
            while let request = MCPCustodianFrame.read(MCPCustodianSocketRequest.self, from: fd) {
                // The hello counts as one. The last answer comes from a
                // daemon that has already forgotten the connection: once
                // the client has read it the connection is gone, as it is
                // for a daemon that hung up, however long this thread then
                // takes to close the descriptor.
                let last = answersPerConnection.withLock { $0 }.map { answered + 1 > $0 } ?? false
                let response = service.withLock { service -> MCPCustodianSocketResponse? in
                    let response = service.handle(id, request, now: .now)
                    if last { service.close(id) }
                    return response
                }
                guard let response, MCPCustodianFrame.write(response, to: fd) else { return }
                answered += 1
                if last {
                    whileHangingUp.withLock { $0 }?()
                    return
                }
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
                    service.open(0, peer: MCPCustodianPeer(uid: UInt32.max - 1))
                    _ = service.handle(0, .hello(protocolVersion: MCPCustodianSocket.protocolVersion), now: .now)
                    return service.handle(0, .attest(challenge: challenge, uid: getuid()), now: .now)
                }
                result = attested == .attested(true) ? .proved : .rejected
                afterAttesting.withLock { $0 }?()
            }
            _ = MCPCustodianFrame.write(MCPPresenceResponse.result(result), to: fd)
        }

        func client(custodianUID: uid_t? = getuid(), presenceUID: uid_t = getuid()) -> MCPCustodianSocketClient {
            MCPCustodianSocketClient(
                path: path, presencePath: presencePath, installedBinary: directory.path + "/not-installed",
                custodianUID: { custodianUID }, presenceUID: presenceUID)
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

    /// The daemon closes an idle connection, and a restarted daemon has
    /// none: the next request goes out again on a new one instead of
    /// failing, and what the old one had unlocked is gone with it.
    @Test(.timeLimit(.minutes(1)))
    func aConnectionTheDaemonClosedIsReplacedOnTheNextRequest() throws {
        let host = try Host()
        defer { host.stop() }
        host.answersPerConnection.withLock { $0 = 1 }
        let client = host.client()
        let terminal = Terminal("right")
        let signing = MCPApprovalSigning.custodian(transport: client.transport(scope: scope, terminal: { nil }))
        // Each request finds its connection closed by the one before.
        let code = try #require(signing.mac(.code, ["c"], true))
        #expect(signing.status() == .enrolled)
        #expect(signing.verify(code, .code, ["c"]) == .valid)
        #expect(signing.mac(.code, ["d"], true) != nil)
        #expect(host.connections.withLock { $0 } >= 4)
        // A proof is for the connection that asked. That one is gone by
        // the time the owner has answered, so nothing is unlocked: the
        // new connection signs nothing without a proof of its own.
        guard case .refused(let why) = client.provePresence(reason: "rv: x", terminal: terminal.value) else {
            Issue.record("a proof for a closed connection was accepted")
            return
        }
        #expect(why.contains("did not accept"), "\(why)")
        #expect(signing.mac(.grant, ["call"], true) == nil)
        #expect(host.prompts.withLock { $0 } == 1)
    }

    /// The key daemon's thread can be left, by a starved scheduler,
    /// between writing a connection's last answer and closing it. The
    /// client has read that answer by then, so for it the connection is
    /// already gone: the proof it then asks for (on that connection's
    /// challenge) unlocks nothing. Here every hang-up waits until the
    /// helper has attested, which orders the close after the proof.
    @Test(.timeLimit(.minutes(1)))
    func aConnectionIsGoneOnceItsLastAnswerIsRead() throws {
        let host = try Host()
        defer { host.stop() }
        host.answersPerConnection.withLock { $0 = 1 }
        let attested = DispatchSemaphore(value: 0)
        let held = Mutex(0)
        let unordered = Mutex(false)
        host.afterAttesting.withLock { $0 = { attested.signal() } }
        host.whileHangingUp.withLock {
            $0 = {
                held.withLock { $0 += 1 }
                if attested.wait(timeout: .now() + 20) == .timedOut { unordered.withLock { $0 = true } }
                // Whoever waits next goes on too.
                attested.signal()
            }
        }
        let client = host.client()
        let terminal = Terminal("right")
        guard case .refused(let why) = client.provePresence(reason: "rv: x", terminal: terminal.value) else {
            Issue.record("a proof for a closed connection was accepted")
            return
        }
        #expect(why.contains("did not accept"), "\(why)")
        let signing = MCPApprovalSigning.custodian(transport: client.transport(scope: scope, terminal: { nil }))
        #expect(signing.mac(.grant, ["call"], true) == nil)
        #expect(host.prompts.withLock { $0 } == 1)
        // The ordering this test is for did happen.
        #expect(held.withLock { $0 } >= 1)
        #expect(unordered.withLock { $0 } == false)
    }

    /// The password prompt appears only once echo is off: nothing typed
    /// at a visible prompt is ever shown, and Ctrl-C cancels the prompt.
    @Test(.timeLimit(.minutes(1)))
    func aSecretIsAskedForWithEchoAlreadyOff() throws {
        var controller: Int32 = -1
        var terminalEnd: Int32 = -1
        try #require(openpty(&controller, &terminalEnd, nil, nil, nil) == 0)
        defer {
            close(controller)
            close(terminalEnd)
        }
        let path = String(cString: try #require(ttyname(terminalEnd)))
        let terminal = try #require(MCPCustodianTerminal.terminal(at: path))
        func ask(typing: [UInt8]) -> (answer: String?, echoWhenPrompted: Bool) {
            let answer = Mutex<String??>(nil)
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                let typed = terminal.ask("Password: ", true)
                answer.withLock { $0 = typed }
                done.signal()
            }
            // Read the prompt, then look at the terminal's modes as they are at that moment.
            var seen: [UInt8] = []
            var byte: UInt8 = 0
            while String(decoding: seen, as: UTF8.self).contains("Password: ") == false, read(controller, &byte, 1) == 1 {
                seen.append(byte)
            }
            var modes = termios()
            _ = tcgetattr(terminalEnd, &modes)
            let echo = modes.c_lflag & tcflag_t(ECHO) != 0
            _ = typing.withUnsafeBytes { write(controller, $0.baseAddress, $0.count) }
            _ = done.wait(timeout: .now() + 20)
            return (answer.withLock { $0 } ?? nil, echo)
        }
        let typed = ask(typing: Array("hunter2\n".utf8))
        #expect(typed.answer == "hunter2")
        #expect(typed.echoWhenPrompted == false)
        // Echo is back afterwards.
        var modes = termios()
        #expect(tcgetattr(terminalEnd, &modes) == 0 && modes.c_lflag & tcflag_t(ECHO) != 0)
        #expect(modes.c_lflag & tcflag_t(ISIG) != 0)
        // Ctrl-C then Enter: no answer, and the modes are restored again.
        #expect(ask(typing: [0x03, 0x0A]).answer == nil)
        #expect(tcgetattr(terminalEnd, &modes) == 0 && modes.c_lflag & tcflag_t(ECHO) != 0)
        #expect(MCPCustodianTerminal.terminal(at: "/no/such/terminal") == nil)
    }

    @Test func aCustodianIsInstalledOnlyWhereItsSocketIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-cust-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("c.sock").path
        let binary = directory.appendingPathComponent("rv-mcp-custodian").path
        func client() -> MCPCustodianSocketClient {
            MCPCustodianSocketClient(
                path: path, presencePath: path, installedBinary: binary, custodianUID: { getuid() }, presenceUID: getuid())
        }
        #expect(client().isInstalled == false)
        try Data().write(to: URL(fileURLWithPath: path))
        // A file that is not a socket is not a custodian.
        #expect(client().isInstalled == false)
        #expect(MCPApprovalSigning.custodian(transport: client().transport(scope: scope, terminal: { nil })).status() == .unavailable)
        // Root's copy is there and the socket is not: installed and not
        // running, which is `unavailable`, not "no custodian here".
        try Data().write(to: URL(fileURLWithPath: binary))
        #expect(client().isInstalled)
        #expect(MCPCustodianSocket.installedBinary == "/usr/local/libexec/rv/rv-mcp-custodian")
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
        // A key whose ledger is gone has lost its counter: not a new
        // account, whose counter would start again at an old grant's.
        _ = try storage.createKey(1002).get()
        #expect(try storage.loadLedger(1002).get() == MCPCustodianLedger())
        #expect(unlink(store.ledgerURL(1002).path) == 0)
        #expect(storage.loadLedger(1002) == .failure(.init()))
        #expect(try storage.createKey(1002).get().mac("p", []).isEmpty == false)
        #expect(storage.loadLedger(1002) == .failure(.init()))
        // The ledger is written first, so a creation cut short (a full
        // disk) leaves a ledger and no key: still a new account.
        #expect(storage.saveLedger(1003, MCPCustodianLedger()))
        #expect(try storage.loadKey(1003).get() == nil)
        #expect(try storage.createKey(1003).get().mac("p", []).isEmpty == false)
        #expect(try storage.loadLedger(1003).get() == MCPCustodianLedger())
        // A ledger that is there is kept, not started again.
        #expect(storage.saveLedger(1004, ledger))
        #expect(try storage.createKey(1004).get().mac("p", []).isEmpty == false)
        #expect(try storage.loadLedger(1004).get() == ledger)
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
