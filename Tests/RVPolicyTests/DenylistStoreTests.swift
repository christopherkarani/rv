import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct DenylistStoreTests {
    @Test func missingFile_isMissingAndEmptySnapshot() throws {
        let root = try makeDirectory("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        #expect(store.load() == .missing)
        #expect(store.loadSnapshot() == .empty)
        #expect(store.loadSnapshot().isUnreadable == false)
        #expect(store.fileURL == RVPolicyPaths.denylistFile(inConfigDir: root))
    }

    @Test func danglingSymlink_isInvalidNotMissing() throws {
        let root = try makeDirectory("dangling")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        try FileManager.default.createSymbolicLink(
            atPath: store.fileURL.path,
            withDestinationPath: root.appendingPathComponent("nowhere.toml").path
        )
        #expect(store.load() == .invalid)
        expectBlocksEverything(store.loadSnapshot())
    }

    @Test func commentOnlyFile_isValidEmpty() throws {
        let root = try makeDirectory("comments")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        try "# my pins\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(store.load() == .ok([]))
        #expect(store.loadSnapshot() == .empty)
    }

    @Test func pin_writesOwnerOnlyAndLoadRoundTrips() throws {
        let root = try makeDirectory("pin")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = DenylistEntry(
            matchingView: MatchingView("git reset --hard"),
            reason: "always block",
            addedAt: now
        )
        try store.pin(entry)
        #expect(try posixMode(store.fileURL) == 0o600)
        #expect(try posixMode(root) == 0o700)
        switch store.load() {
        case .ok(let entries):
            #expect(entries.count == 1)
            #expect(entries[0].matchingView == entry.matchingView)
            #expect(entries[0].reason == entry.reason)
        default:
            Issue.record("expected ok load after pin")
        }
        #expect(store.loadSnapshot().matches(entry.matchingView))
    }

    @Test func pin_sameMatchingView_isIdempotent() throws {
        let root = try makeDirectory("dup")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        let first = DenylistEntry(
            matchingView: MatchingView("rm -rf /"),
            reason: "first",
            addedAt: Date(timeIntervalSince1970: 1)
        )
        let second = DenylistEntry(
            matchingView: MatchingView("rm -rf /"),
            reason: "second",
            addedAt: Date(timeIntervalSince1970: 2)
        )
        try store.pin(first)
        try store.pin(second)
        guard case .ok(let entries) = store.load() else {
            Issue.record("expected ok")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0].reason == "first")
    }

    @Test func invalidUTF8_isInvalidAndUnreadableSnapshot() throws {
        let root = try makeDirectory("bytes")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        try Data([0xFF, 0xFE, 0x00]).write(to: store.fileURL)
        #expect(store.load() == .invalid)
        expectBlocksEverything(store.loadSnapshot())
    }

    @Test(.enabled(if: getuid() != 0, "root reads mode-000 files"))
    func unreadableFile_isInvalidAndUnreadableSnapshot() throws {
        let root = try makeDirectory("perms")
        let store = DenylistStore(baseDirectory: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        try store.pin(
            DenylistEntry(
                matchingView: MatchingView("git reset --hard"),
                reason: "always block",
                addedAt: Date(timeIntervalSince1970: 1)
            )
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.fileURL.path)
        #expect(store.load() == .invalid)
        expectBlocksEverything(store.loadSnapshot())
    }

    @Test func validFile_snapshotMatchesOnlyItsEntries() throws {
        let root = try makeDirectory("valid")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        try """
        [[block]]
        exact_command = "git reset --hard"
        reason = "always block"
        added_at = "2023-11-14T22:13:20Z"
        """.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let snap = store.loadSnapshot()
        #expect(snap.isUnreadable == false)
        #expect(snap.entries.count == 1)
        #expect(snap.matches(MatchingView("git reset --hard")))
        #expect(snap.matches(MatchingView("git status")) == false)
    }

    @Test func invalidTOML_isInvalidAndPinFailsClosed() throws {
        let root = try makeDirectory("bad-toml")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        try "not toml {{{".write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(store.load() == .invalid)
        expectBlocksEverything(store.loadSnapshot())
        #expect(throws: DenylistParseError.invalidTOML) {
            try store.pin(
                DenylistEntry(
                    matchingView: MatchingView("git status"),
                    reason: "should not write",
                    addedAt: Date()
                )
            )
        }
    }

    @Test func directoryAtLockPath_mapsToAllowlistLockFailed() throws {
        let root = try makeDirectory("lock-dir")
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = RVPolicyPaths.denylistLockFile(inConfigDir: root)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let store = DenylistStore(baseDirectory: root)
        #expect(throws: AllowlistStoreError.lockFailed) {
            try store.pin(
                DenylistEntry(
                    matchingView: MatchingView("git reset --hard"),
                    reason: "blocked by lock",
                    addedAt: Date()
                )
            )
        }
    }

    @Test func uninstallArtifacts_includeDenylistAndLock() {
        let root = URL(fileURLWithPath: "/tmp/rv-config", isDirectory: true)
        let artifacts = RVPolicyPaths.uninstallArtifacts(inConfigDir: root)
        #expect(artifacts.contains(RVPolicyPaths.denylistFile(inConfigDir: root)))
        #expect(artifacts.contains(RVPolicyPaths.denylistLockFile(inConfigDir: root)))
    }
}

/// A present-but-unusable denylist may hold any Always-block pin, so it
/// must match every view rather than read as empty.
private func expectBlocksEverything(_ snap: DenylistSnapshot) {
    #expect(snap != .empty)
    #expect(snap.isUnreadable)
    #expect(snap.matches(MatchingView("git reset --hard")))
    #expect(snap.matches(MatchingView("anything at all")))
}

private func makeDirectory(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-denylist-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func posixMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attrs[.posixPermissions] as? NSNumber
    return (raw?.intValue ?? 0) & 0o777
}
