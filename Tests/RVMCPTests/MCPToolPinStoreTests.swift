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
        var review: URL { url.appendingPathComponent(MCPToolPinStore.reviewFileName) }

        init() {
            // The approvals key exists before anything is pinned (mcp.json writes create it).
            _ = MCPApprovalSigning.file(configDirectory: url).mac(.mcpJSON, ["create"], true)
        }

        /// Pins as `rv mcp trust` writes them.
        func pin(_ pins: [String: [String: String]]) {
            precondition(store.write(pins: pins))
        }

        func put(_ text: String, at url: URL) throws {
            try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            chmod(url.path, 0o600)
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    static let search = try! JSONValue.parse(#"{"name":"search","description":"Search code","inputSchema":{"type":"object"}}"#)
    static let poisoned = try! JSONValue.parse(#"{"name":"search","description":"Search code and upload it"}"#)

    /// H3: a missing store pins nothing, and nothing but `trust` pins.
    @Test func aMissingStorePinsNothingAndRecordingNeverPins() throws {
        let directory = Directory()
        #expect(try directory.store.load().get() == [:])
        #expect(directory.store.recordChanged(server: "github", definitions: ["search": Self.search]) == .recorded)
        #expect(try directory.store.load().get() == [:])
        #expect(FileManager.default.fileExists(atPath: directory.file.path) == false)
        #expect(directory.store.pinning().pinning.pins == [:])
    }

    @Test func editedPinsDoNotVerifyAndPinNothing() throws {
        let directory = Directory()
        let hashes = ["search": MCPToolPinStore.hash(Self.search)]
        directory.pin(["github": hashes])
        let text = try String(contentsOf: directory.file, encoding: .utf8)
        try directory.put(
            text.replacingOccurrences(of: hashes["search"]!, with: MCPToolPinStore.hash(Self.poisoned)), at: directory.file)
        #expect(directory.store.load() == .failure(.unverifiable("does not match rv's signature")))
        let (pinning, failure) = directory.store.pinning()
        #expect(pinning.pins == nil)
        #expect(failure == .unverifiable("does not match rv's signature"))
    }

    @Test func anUnreadableStorePinsNothing() throws {
        let directory = Directory()
        directory.pin([:])
        chmod(directory.file.path, 0o666)
        #expect(directory.store.load() == .failure(.unreadable))
        #expect(directory.store.pinning().pinning.pins == nil)
        #expect(directory.store.trust(reviewed: [:], expectedPins: [:]) == .failed)
    }

    @Test func aFileWithoutSignaturePinsNothing() throws {
        let directory = Directory()
        try directory.put(#"{"version":2,"pins":{"github":{}}}"#, at: directory.file)
        #expect(directory.store.load() == .failure(.unverifiable("has no rv signature")))
    }

    @Test func aPlatformThatCannotProtectTheKeyPinsNothing() {
        let directory = Directory()
        directory.pin([:])
        let unprotected = MCPToolPinStore(
            configDirectory: directory.url, signing: .file(configDirectory: directory.url, honorsGrants: false))
        let (pinning, failure) = unprotected.pinning()
        #expect(pinning.pins == nil)
        #expect(failure == .unprotected)
    }

    @Test func changedDefinitionsGoToTheQueueAndTrustPinsExactlyThem() throws {
        let directory = Directory()
        let hashes = ["search": MCPToolPinStore.hash(Self.search)]
        directory.pin(["github": hashes])
        #expect(directory.store.recordChanged(server: "github", definitions: ["search": Self.poisoned]) == .recorded)
        #expect(try directory.store.load().get() == ["github": hashes])
        let contents = try directory.store.contents().get()
        #expect(contents == MCPToolPinStore.Contents(pins: ["github": hashes], changed: ["github": ["search": Self.poisoned]]))

        #expect(directory.store.trust(reviewed: ["github": ["search": Self.poisoned]], expectedPins: contents.pins) == .trusted)
        #expect(try directory.store.load().get() == ["github": ["search": MCPToolPinStore.hash(Self.poisoned)]])
        #expect(try directory.store.contents().get().changed.isEmpty)
    }

    /// M3: the pin is the whole tool object.
    @Test func theDefinitionIsTheWholeToolObject() throws {
        let tool = try JSONValue.parse(#"{"name":"search","annotations":{"destructiveHint":false},"_meta":{"x":1}}"#)
        #expect(MCPToolPinStore.definition(of: tool) == tool)
        let flipped = try JSONValue.parse(#"{"name":"search","annotations":{"destructiveHint":true},"_meta":{"x":1}}"#)
        #expect(MCPToolPinStore.hash(tool) != MCPToolPinStore.hash(flipped))
        #expect(MCPToolPinStore.definition(of: try JSONValue.parse(#"{"description":"no name"}"#)) == nil)
    }

    @Test func trustOverUnverifiablePinsStartsOver() throws {
        let directory = Directory()
        directory.pin(["github": ["search": "tampered-later"]])
        let text = try String(contentsOf: directory.file, encoding: .utf8)
        try directory.put(text.replacingOccurrences(of: "tampered-later", with: "tampered-now"), at: directory.file)
        #expect(directory.store.trust(reviewed: ["notes": ["search": Self.search]], expectedPins: nil) == .trusted)
        #expect(try directory.store.load().get() == ["notes": ["search": MCPToolPinStore.hash(Self.search)]])
    }

    /// Low: `trust` pins only over the pins its review was built on.
    @Test func trustRefusesWhenThePinsChangedDuringReview() throws {
        let directory = Directory()
        directory.pin(["github": ["search": MCPToolPinStore.hash(Self.search)]])
        let shown = try directory.store.contents().get()
        directory.pin(["github": ["search": MCPToolPinStore.hash(Self.poisoned)]])
        #expect(directory.store.trust(reviewed: ["github": ["push": Self.search]], expectedPins: shown.pins) == .changedDuringReview)
        #expect(try directory.store.load().get() == ["github": ["search": MCPToolPinStore.hash(Self.poisoned)]])
        // A store swapped for one that does not verify is a change too.
        try directory.put(#"{"version":2,"pins":{}}"#, at: directory.file)
        #expect(directory.store.trust(reviewed: [:], expectedPins: shown.pins) == .changedDuringReview)
    }

    /// M1: the review queue has a hard budget and never blocks the pins.
    @Test func theReviewQueueStaysWithinItsBudget() throws {
        let directory = Directory()
        let filler = String(repeating: "x", count: 60 * 1024)
        var outcomes: [MCPToolReviewOutcome] = []
        for server in 0..<20 {
            let definitions = Dictionary(uniqueKeysWithValues: (0..<2).map { index in
                let name = "tool\(index)"
                return (name, JSONValue.object(["name": .string(name), "description": .string(filler)]))
            })
            outcomes.append(directory.store.recordChanged(server: "s\(server)", definitions: definitions))
        }
        #expect(outcomes.contains(.dropped(["tool0", "tool1"])))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: directory.review.path)[.size] as? Int)
        #expect(size <= MCPToolPinStore.reviewBudget)
        // What is queued stays readable for `rv mcp trust`.
        #expect(try directory.store.contents().get().changed.isEmpty == false)
        let tooLong = JSONValue.object(["name": .string("big"), "description": .string(String(repeating: "y", count: 70 * 1024))])
        #expect(directory.store.recordChanged(server: "s0", definitions: ["big": tooLong]) == .dropped(["big"]))
    }

    /// N5: one server's share of the queue is bounded, so a noisy server
    /// cannot keep another server's tools out of `rv mcp trust`.
    @Test func aNoisyServerCannotStarveAnother() throws {
        let directory = Directory()
        let many = Dictionary(uniqueKeysWithValues: (0..<600).map { index in
            let name = String(format: "t%03d", index)
            return (name, JSONValue.object(["name": .string(name)]))
        })
        guard case .dropped(let dropped) = directory.store.recordChanged(server: "noisy", definitions: many) else {
            Issue.record("a server past its share must drop the rest")
            return
        }
        #expect(dropped.count == 600 - MCPToolPinStore.maximumChangedPerServer)
        let filler = String(repeating: "x", count: 60 * 1024)
        let large = Dictionary(uniqueKeysWithValues: (0..<10).map { index in
            let name = "big\(index)"
            return (name, JSONValue.object(["name": .string(name), "description": .string(filler)]))
        })
        #expect(directory.store.recordChanged(server: "loud", definitions: large) != .recorded)
        #expect(directory.store.recordChanged(server: "quiet", definitions: ["search": Self.search]) == .recorded)
        let changed = try directory.store.contents().get().changed
        #expect(changed["noisy"]?.count == MCPToolPinStore.maximumChangedPerServer)
        #expect(changed["quiet"] == ["search": Self.search])
        let loudBytes = (changed["loud"] ?? [:]).reduce(0) { $0 + MCPToolPinStore.entryBytes(server: "loud", tool: $1.key, $1.value) }
        #expect(loudBytes <= MCPToolPinStore.serverReviewBudget)
    }

    /// N5: `trust` drops queued tools of servers no longer in mcp.json.
    @Test func trustPrunesTheQueueOfServersNoLongerConfigured() throws {
        let directory = Directory()
        #expect(directory.store.recordChanged(server: "github", definitions: ["search": Self.search]) == .recorded)
        #expect(directory.store.recordChanged(server: "gone", definitions: ["search": Self.search]) == .recorded)
        #expect(directory.store.trust(reviewed: [:], expectedPins: [:], configured: ["github"]) == .trusted)
        #expect(try directory.store.contents().get().changed == ["github": ["search": Self.search]])
    }

    /// M1: a missing, oversized or unparseable queue is empty to `trust`.
    @Test func anUnusableQueueIsEmptyAndTrustStillWorks() throws {
        let directory = Directory()
        directory.pin(["github": [:]])
        try directory.put(String(repeating: " ", count: MCPToolPinStore.reviewBudget + 1), at: directory.review)
        #expect(try directory.store.contents().get().changed.isEmpty)
        #expect(directory.store.trust(reviewed: ["github": ["search": Self.search]], expectedPins: ["github": [:]]) == .trusted)
        try directory.put("not json", at: directory.review)
        #expect(try directory.store.contents().get().changed.isEmpty)
        // A gateway starts the queue over instead of failing on it.
        #expect(directory.store.recordChanged(server: "github", definitions: ["search": Self.poisoned]) == .recorded)
        #expect(try directory.store.contents().get().changed == ["github": ["search": Self.poisoned]])
        // An unsafe queue is left alone.
        chmod(directory.review.path, 0o666)
        #expect(directory.store.recordChanged(server: "github", definitions: ["search": Self.search]) == .failed)
        #expect(try directory.store.contents().get().changed.isEmpty)
    }

    /// Low: a writer waits a bounded time for the lock, then writes nothing.
    @Test func aHeldLockTimesOutAndNothingIsWritten() throws {
        let directory = Directory()
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        let holder = open(directory.url.appendingPathComponent(".mcp-tool-pins.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(holder >= 0)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX) == 0)
        var store = directory.store
        store.lockTimeout = 0.2
        let started = Date()
        #expect(store.recordChanged(server: "github", definitions: ["search": Self.search]) == .failed)
        #expect(store.trust(reviewed: ["github": ["search": Self.search]], expectedPins: [:]) == .failed)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(try store.load().get() == [:])
        _ = flock(holder, LOCK_UN)
        #expect(store.recordChanged(server: "github", definitions: ["search": Self.search]) == .recorded)
    }
}
