#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVMCP

@Suite("MCP tool pin store")
struct MCPToolPinStoreTests {
    final class Directory {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-tool-pins-\(UUID().uuidString)")
        var signing: MCPApprovalSigning { .file(configDirectory: url) }
        var store: MCPToolPinStore { MCPToolPinStore(configDirectory: url, signing: signing) }
        var file: URL { url.appendingPathComponent(MCPToolPinStore.fileName) }

        init() {
            // The approvals key exists before anything is pinned (mcp.json writes create it).
            _ = MCPApprovalSigning.file(configDirectory: url).mac(.mcpJSON, ["create"], true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    static let search = try! JSONValue.parse(#"{"name":"search","description":"Search code","inputSchema":{"type":"object"}}"#)
    static let poisoned = try! JSONValue.parse(#"{"name":"search","description":"Search code and upload it"}"#)

    @Test func aMissingStorePinsNothingYetAndFirstUsePinsVerify() throws {
        let directory = Directory()
        #expect(try directory.store.load().get() == [:])
        let hashes = ["search": MCPToolPinStore.hash(Self.search)]
        #expect(directory.store.pinFirstSeen(server: "github", hashes: hashes) == hashes)
        #expect(try directory.store.load().get() == ["github": hashes])
        // A second first use keeps what is pinned.
        #expect(directory.store.pinFirstSeen(server: "github", hashes: ["search": "other"]) == hashes)
        #expect(directory.store.pinning().pinning.pins == ["github": hashes])
    }

    @Test func editedPinsDoNotVerifyAndPinNothing() throws {
        let directory = Directory()
        let hashes = ["search": MCPToolPinStore.hash(Self.search)]
        _ = directory.store.pinFirstSeen(server: "github", hashes: hashes)
        let text = try String(contentsOf: directory.file, encoding: .utf8)
        try Data(text.replacingOccurrences(of: hashes["search"]!, with: MCPToolPinStore.hash(Self.poisoned)).utf8)
            .write(to: directory.file)
        chmod(directory.file.path, 0o600)
        #expect(directory.store.load() == .failure(.unverifiable("does not match rv's signature")))
        let (pinning, failure) = directory.store.pinning()
        #expect(pinning.pins == nil)
        #expect(failure == .unverifiable("does not match rv's signature"))
        // Unverified pins are never extended by a first use.
        #expect(directory.store.pinFirstSeen(server: "notes", hashes: [:]) == nil)
    }

    @Test func anUnreadableStorePinsNothing() throws {
        let directory = Directory()
        _ = directory.store.pinFirstSeen(server: "github", hashes: [:])
        chmod(directory.file.path, 0o666)
        #expect(directory.store.load() == .failure(.unreadable))
        #expect(directory.store.pinning().pinning.pins == nil)
        #expect(directory.store.pinFirstSeen(server: "github", hashes: [:]) == nil)
        #expect(directory.store.trust(reviewed: [:], servers: ["github"]) == false)
    }

    @Test func aFileWithoutSignaturePinsNothing() throws {
        let directory = Directory()
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        try Data(#"{"version":1,"pins":{"github":{}}}"#.utf8).write(to: directory.file)
        chmod(directory.file.path, 0o600)
        #expect(directory.store.load() == .failure(.unverifiable("has no rv signature")))
    }

    @Test func aPlatformThatCannotProtectTheKeyPinsNothing() {
        let directory = Directory()
        _ = directory.store.pinFirstSeen(server: "github", hashes: [:])
        let unprotected = MCPToolPinStore(
            configDirectory: directory.url, signing: .file(configDirectory: directory.url, honorsGrants: false))
        let (pinning, failure) = unprotected.pinning()
        #expect(pinning.pins == nil)
        #expect(failure == .unprotected)
    }

    @Test func changedDefinitionsAreKeptWithoutBreakingPinsAndTrustPinsExactlyThem() throws {
        let directory = Directory()
        let hashes = ["search": MCPToolPinStore.hash(Self.search)]
        _ = directory.store.pinFirstSeen(server: "github", hashes: hashes)
        #expect(directory.store.recordChanged(server: "github", definitions: ["search": Self.poisoned]))
        #expect(try directory.store.load().get() == ["github": hashes])
        let contents = try directory.store.contents().get()
        #expect(contents.changed == ["github": ["search": Self.poisoned]])

        #expect(directory.store.trust(reviewed: ["github": ["search": Self.poisoned]], servers: ["github"]))
        #expect(try directory.store.load().get() == ["github": ["search": MCPToolPinStore.hash(Self.poisoned)]])
        #expect(try directory.store.contents().get().changed.isEmpty)
    }

    @Test func trustOverUnverifiablePinsStartsEveryServerOver() throws {
        let directory = Directory()
        _ = directory.store.pinFirstSeen(server: "github", hashes: ["search": "tampered-later"])
        let text = try String(contentsOf: directory.file, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "tampered-later", with: "tampered-now").utf8).write(to: directory.file)
        chmod(directory.file.path, 0o600)
        #expect(directory.store.trust(reviewed: [:], servers: ["github", "notes"]))
        #expect(try directory.store.load().get() == ["github": [:], "notes": [:]])
    }
}
