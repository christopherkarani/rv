import Foundation
import Synchronization
import Testing
import RVDomain
import RVPolicy

/// AC-002: concurrent read-modify-write saves on one layer must not drop a rule.
/// Every writer upserts a rule with a distinct predicate, so `mergeLayer` keeps
/// all of them; any missing rule is a lost update from an unlocked load.
@Suite("PolicyWorkspace concurrent merge")
struct PolicyWorkspaceConcurrentMergeTests {
    private static let writers = 16

    @Test func concurrentMachineUpsertsKeepEveryRule() throws {
        let config = try temporaryDirectory(prefix: "rv-pws-race-config")
        defer { try? FileManager.default.removeItem(at: config) }
        let session = PolicyWorkspace(configDirectory: config)
        let rules = distinctRules(count: Self.writers)

        try runConcurrently(rules) { rule in
            try session.upsert(rule, layer: .machine)
        }

        let saved = try session.loadMachineDocument().rules
        #expect(Set(saved.map(\.id)) == Set(rules.map(\.id)))
        #expect(saved.count == rules.count)
        #expect(try session.listRevisions(layer: .machine).count == rules.count)
    }

    @Test func concurrentRepoMergesKeepEveryRule() throws {
        let config = try temporaryDirectory(prefix: "rv-pws-race-config")
        let workspace = try temporaryDirectory(prefix: "rv-pws-race-ws")
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let session = PolicyWorkspace(configDirectory: config, workspace: workspace)
        let rules = distinctRules(count: Self.writers)

        try runConcurrently(rules) { rule in
            _ = try session.mergeIncoming(
                PolicyDocument(rules: [rule]),
                layer: .repo,
                save: true
            )
        }

        let saved = try session.loadRepoDocument().rules
        #expect(Set(saved.map(\.id)) == Set(rules.map(\.id)))
        #expect(saved.count == rules.count)
    }
}

private func distinctRules(count: Int) -> [PolicyDocumentRule] {
    (0..<count).map { index in
        PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "race-\(index)"),
            verdict: .deny,
            predicate: .gitPush(force: .exactly(.force), branch: "race-\(index)")
        )
    }
}

private func runConcurrently(
    _ rules: [PolicyDocumentRule],
    _ body: @Sendable (PolicyDocumentRule) throws -> Void
) throws {
    let failures = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: rules.count) { index in
        do {
            try body(rules[index])
        } catch {
            failures.withLock { $0.append("\(rules[index].id): \(error)") }
        }
    }
    let errors = failures.withLock { $0 }
    #expect(errors.isEmpty, "writers failed: \(errors)")
}

private func temporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
