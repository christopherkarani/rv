import Foundation
import Testing
@testable import RVPolicy

struct AllowOnceTests {
    @Test func fileStoreConsumesOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileAllowOnceStore(root: root)
        _ = try await store.insert(command: "git reset --hard", cwd: "/tmp/ws", expiresAt: nil)
        let first = await store.consume(command: "git reset --hard", cwd: "/tmp/ws")
        let second = await store.consume(command: "git reset --hard", cwd: "/tmp/ws")
        guard case .consumed = first else {
            Issue.record("first consume should succeed")
            return
        }
        #expect(second == .alreadyConsumed)
    }

    @Test func concurrentConsumeWinsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileAllowOnceStore(root: root)
        _ = try await store.insert(command: "git stash clear", cwd: "/tmp/ws", expiresAt: nil)
        async let a = store.consume(command: "git stash clear", cwd: "/tmp/ws")
        async let b = store.consume(command: "git stash clear", cwd: "/tmp/ws")
        let results = await [a, b]
        let consumed = results.filter {
            if case .consumed = $0 { return true }
            return false
        }
        #expect(consumed.count == 1)
        #expect(results.contains(.alreadyConsumed) || consumed.count == 1)
    }
}
