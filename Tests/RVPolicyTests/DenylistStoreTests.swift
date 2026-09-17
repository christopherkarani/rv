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
        #expect(store.fileURL == RVPolicyPaths.denylistFile(inConfigDir: root))
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

    @Test func invalidUTF8_isInvalidAndEmptySnapshot() throws {
        let root = try makeDirectory("bytes")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        try Data([0xFF, 0xFE, 0x00]).write(to: store.fileURL)
        #expect(store.load() == .invalid)
        #expect(store.loadSnapshot() == .empty)
    }

    @Test func invalidTOML_isInvalidAndPinFailsClosed() throws {
        let root = try makeDirectory("bad-toml")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DenylistStore(baseDirectory: root)
        try "not toml {{{".write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(store.load() == .invalid)
        #expect(store.loadSnapshot() == .empty)
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
