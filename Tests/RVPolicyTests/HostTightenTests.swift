import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy

/// Q4 (Chris, 2026-11-27, "Proposal or 1-hour expiry"): an unconfirmed
/// block that would stop agents never locks an agent out.
struct HostTightenTests {
    private static let now = Date(timeIntervalSince1970: 1_764_250_000)

    @Test func agentBlockOfAnotherHost_endsOnItsOwnAfterAnHour() {
        let outcome = HostTighten.unconfirmedBlock(
            of: .cursor, storedMode: .observe, openBlock: nil, callingHosts: [.claude], now: Self.now)
        #expect(outcome == .temporary(GuardWindow(from: Self.now, until: Self.now.addingTimeInterval(3600))))
    }

    @Test func agentBlockOfItsOwnHost_isAProposal() {
        let outcome = HostTighten.unconfirmedBlock(
            of: .claude, storedMode: .observe, openBlock: nil, callingHosts: [.claude], now: Self.now)
        #expect(outcome == .proposal(.ownHost))
        // An inherited marker makes it more careful, never less.
        let nested = HostTighten.unconfirmedBlock(
            of: .codex, storedMode: .observe, openBlock: nil, callingHosts: [.claude, .codex], now: Self.now)
        #expect(nested == .proposal(.ownHost))
    }

    @Test func blockWithNoAgentMarker_isAProposal() {
        let outcome = HostTighten.unconfirmedBlock(
            of: .cursor, storedMode: .observe, openBlock: nil, callingHosts: [], now: Self.now)
        #expect(outcome == .proposal(.unknownCaller))
    }

    @Test func blockOfAnOffHost_isAProposal() {
        let outcome = HostTighten.unconfirmedBlock(
            of: .cursor, storedMode: .off, openBlock: nil, callingHosts: [.claude], now: Self.now)
        #expect(outcome == .proposal(.hostOff))
    }

    @Test func blockOfAHostAlreadyEnforcing_isStoredAsAsked() {
        for callers: Set<HookHost> in [[], [.claude]] {
            let outcome = HostTighten.unconfirmedBlock(
                of: .claude, storedMode: .block, openBlock: nil, callingHosts: callers, now: Self.now)
            #expect(outcome == .permanent)
        }
    }

    /// Asking again never extends an agent's block.
    @Test func openAgentBlock_isNotExtended() {
        let open = GuardWindow(from: Self.now.addingTimeInterval(-1800), until: Self.now.addingTimeInterval(1800))
        let outcome = HostTighten.unconfirmedBlock(
            of: .cursor, storedMode: .observe, openBlock: open, callingHosts: [.claude], now: Self.now)
        #expect(outcome == .alreadyTemporary(open))
    }

    @Test func markers_nameTheHostsInTheEnvironment() {
        #expect(AgentHostMarkers.callingHosts(in: ["CLAUDECODE": "1", "PATH": "/bin"]) == [.claude])
        #expect(AgentHostMarkers.callingHosts(in: ["CLAUDE_CODE_ENTRYPOINT": "cli"]) == [.claude])
        #expect(AgentHostMarkers.callingHosts(in: ["CODEX_SANDBOX": "seatbelt", "OPENCODE": "1"]) == [.codex, .opencode])
        #expect(AgentHostMarkers.callingHosts(in: ["CURSOR_AGENT": "1"]) == [.cursor])
        // A person's own setting is no marker.
        #expect(AgentHostMarkers.callingHosts(in: ["CODEX_HOME": "/Users/me/.codex", "HOME": "/Users/me"]).isEmpty)
    }
}

struct HostModeStoreWindowTests {
    private static let now = Date(timeIntervalSince1970: 1_764_250_000)

    private func store() throws -> (HostModeStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-host-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (HostModeStore(configDirectory: root), root)
    }

    /// The stored mode under an agent's block is never overwritten, so the
    /// exact previous mode is what comes back, with nothing to restore.
    @Test func temporaryBlock_leavesTheStoredModeAndClears() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(.observe, for: .cursor)
        let window = GuardWindow(startingAt: Self.now, lasting: GuardWindow.temporaryBlockLimit)
        try store.saveTemporaryBlock(for: .cursor, window: window)
        #expect(store.read() == .entries([.cursor: .observe]))
        let config = try #require(store.readGuardConfig())
        #expect(config.temporaryBlocks == [.cursor: window])
        #expect(GuardModeResolution.resolve(config, host: .cursor, environment: [:], now: Self.now) == .enforce)
        #expect(GuardModeResolution.resolve(
            config, host: .cursor, environment: [:], now: Self.now.addingTimeInterval(3600)) == .observe)

        try store.clearTemporaryBlock(for: .cursor, direction: .loosening)
        #expect(try #require(store.readGuardConfig()).temporaryBlocks.isEmpty)
        #expect(store.read() == .entries([.cursor: .observe]))
        // Clearing what is not there changes nothing.
        try store.clearTemporaryBlock(for: .claude, direction: .loosening)
        #expect(store.read() == .entries([.cursor: .observe]))
    }

    @Test func unreadableConfig_refusesWindowsAndReadsAsNil() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = Data(#"{"guard":{"mode":"observe"},"guard":{"mode":"enforce"}}"#.utf8)
        try text.write(to: store.configFile)
        #expect(store.readGuardConfig() == nil)
        #expect(throws: OwnerConfigWriteError.unreadable) {
            try store.saveTemporaryBlock(for: .claude, window: GuardWindow(startingAt: Self.now, lasting: 3600))
        }
        #expect(try Data(contentsOf: store.configFile) == text)
    }
}
