import Foundation
import Testing
import RVDomain
import RVPolicy

@Suite("PolicyRevisionLog")
struct PolicyRevisionLogTests {
    @Test func freshHistoryIsEmptyAndRollbackIsNotFound() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        #expect(try store.machineHistory() == [])
        #expect(throws: TypedRuleStoreError.revisionNotFound) {
            try store.rollbackMachine(toRevision: 1)
        }
    }

    @Test func savesSealContiguousHistory() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let first = PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")])
        let second = PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")])

        try store.saveMachine(first)
        try store.saveMachine(second)
        let history = try store.machineHistory()

        #expect(history.map(\.revision) == [1, 2])
        #expect(history.map(\.document) == [first, second])
        let onDisk = try String(contentsOf: store.machineFileURL, encoding: .utf8)
        #expect(onDisk == history[1].toml)
    }

    @Test func forgedPayloadFailsClosed() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")]))

        // Attacker swaps r1's sealed TOML for attacker TOML but cannot
        // re-key the MAC, so the stored MAC no longer matches the payload.
        let attacker = PolicyDocument(rules: [
            PolicyDocumentRule(
                id: RuleID(pack: .coreGit, pattern: "attacker-allow"),
                verdict: .allow,
                predicate: .gitPush(force: .exactly(.force), branch: "main")
            ),
        ])
        let attackerBase64 = Data(PolicyDocumentTOML.render(attacker).utf8).base64EncodedString()
        var lines = try readLogLines(config: root)
        lines[0] = try reencodeLogLine(lines[0], mutate: { json in
            json["toml_base64"] = attackerBase64
        })
        try writeLogLines(lines, config: root)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.machineHistory()
        }
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.rollbackMachine(toRevision: 1)
        }
        // The attacker's TOML must never go live via rollback.
        let onDisk = try String(contentsOf: store.machineFileURL, encoding: .utf8)
        #expect(onDisk.contains("attacker-allow") == false)
    }

    @Test func forgedMACFailsClosed() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))

        var lines = try readLogLines(config: root)
        lines[0] = try reencodeLogLine(lines[0], mutate: { json in
            let mac = try #require(json["mac"] as? String)
            json["mac"] = flipFirstHexChar(mac)
        })
        try writeLogLines(lines, config: root)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.machineHistory()
        }
    }

    @Test func reorderedLogFailsClosed() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")]))

        var lines = try readLogLines(config: root)
        #expect(lines.count == 2)
        lines.swapAt(0, 1)
        try writeLogLines(lines, config: root)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.machineHistory()
        }
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.rollbackMachine(toRevision: 1)
        }
    }

    @Test func truncatedLogFailsClosed() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")]))

        // A bare prefix still chains, so only the sealed tip catches this.
        var lines = try readLogLines(config: root)
        #expect(lines.count == 2)
        lines.removeLast()
        try writeLogLines(lines, config: root)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.machineHistory()
        }
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.rollbackMachine(toRevision: 1)
        }
    }

    @Test func saveRefusesToBuildOnForgedHistory() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))
        let before = try String(contentsOf: store.machineFileURL, encoding: .utf8)

        var lines = try readLogLines(config: root)
        lines[0] = try reencodeLogLine(lines[0], mutate: { json in
            let mac = try #require(json["mac"] as? String)
            json["mac"] = flipFirstHexChar(mac)
        })
        try writeLogLines(lines, config: root)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")]))
        }
        #expect(try String(contentsOf: store.machineFileURL, encoding: .utf8) == before)
    }

    @Test func deletedLogIsNeverSilentlyReminted() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let document = PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")])
        try store.saveMachine(document)
        let before = try String(contentsOf: store.machineFileURL, encoding: .utf8)

        try FileManager.default.removeItem(at: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root))
        try FileManager.default.removeItem(at: RVPolicyPaths.policyRevisionLogTipFile(inConfigDir: root))
        try FileManager.default.removeItem(at: RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root))

        #expect(throws: TypedRuleStoreError.logMissing) {
            try store.saveMachine(document)
        }
        #expect(throws: TypedRuleStoreError.logMissing) {
            try store.machineHistory()
        }
        #expect(throws: TypedRuleStoreError.logMissing) {
            try store.rollbackMachine(toRevision: 1)
        }
        // No silent clean re-mint: the log stays gone and policy is untouched.
        #expect(
            FileManager.default.fileExists(
                atPath: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root).path
            ) == false
        )
        #expect(try String(contentsOf: store.machineFileURL, encoding: .utf8) == before)

        // Only the explicit operator recovery path re-mints, from disk state.
        try store.reinitializeMachineLog()
        let history = try store.machineHistory()
        #expect(history.map(\.revision) == [1])
        #expect(history.map(\.document) == [document])
        try store.saveMachine(document)
        // Identical re-save seals an internal duplicate but mints no new
        // generation, so public history stays at [1].
        #expect(try store.machineHistory().map(\.revision) == [1])
    }

    @Test func missingKeyFailsClosedWithoutMinting() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))
        try FileManager.default.removeItem(at: RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root))

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.machineHistory()
        }
        #expect(
            FileManager.default.fileExists(
                atPath: RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root).path
            ) == false
        )
    }

    @Test func reinitializeRefusesUnparseablePolicy() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))
        try FileManager.default.removeItem(at: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root))
        try "not-toml".write(to: store.machineFileURL, atomically: true, encoding: .utf8)

        #expect(throws: TypedRuleStoreError.invalidFile) {
            try store.reinitializeMachineLog()
        }
    }

    @Test func rollbackRestoresByteExactAndSealsRestore() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let first = PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")])
        let second = PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")])
        try store.saveMachine(first)
        try store.saveMachine(second)
        let sealed = try store.machineHistory()[0].toml

        let head = try store.rollbackMachine(toRevision: 1)

        #expect(head.revision == 3)
        #expect(head.toml == sealed)
        #expect(head.document == first)
        #expect(try String(contentsOf: store.machineFileURL, encoding: .utf8) == sealed)
        let history = try store.machineHistory()
        #expect(history.map(\.revision) == [1, 2, 3])
        #expect(history[2].document == first)
        #expect(try store.loadMachineDocument() == first)
    }

    @Test func rollbackUnknownRevisionLeavesDiskUntouched() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))
        let before = try String(contentsOf: store.machineFileURL, encoding: .utf8)

        #expect(throws: TypedRuleStoreError.revisionNotFound) {
            try store.rollbackMachine(toRevision: 99)
        }
        #expect(try String(contentsOf: store.machineFileURL, encoding: .utf8) == before)
        #expect(try store.machineHistory().map(\.revision) == [1])
    }

    @Test func interruptedSaveReconcilesOnNextSaveInsteadOfBricking() throws {
        // Regression: saveMachine moves policy.toml + display log, then
        // seals. A crash between the two used to brick every later
        // cross-checked operation with logCorrupted until operator
        // recovery destroyed history. Simulate that exact state (live
        // file + display tail present, seal missing), then save again.
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let first = PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")])
        let second = PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")])
        let third = PolicyDocument(rules: [denyRule(pattern: "v3", branch: "release")])
        try store.saveMachine(first)

        let secondText = PolicyDocumentTOML.render(second)
        try secondText.write(to: store.machineFileURL, atomically: true, encoding: .utf8)
        let tail = PolicyRevision(
            revision: 2,
            hash: PolicyRevisionIdentity.hash(second),
            ruleCount: second.rules.count,
            recordedAt: Date(),
            toml: secondText,
            document: second
        )
        let line = try JSONEncoder().encode(tail)
        let handle = try FileHandle(forWritingTo: store.machineRevisionsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data("\n".utf8))
        try handle.close()

        // Reads stay strict: the unsealed tail is not history yet.
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.listMachineRevisions()
        }
        // The next save completes the interrupted seal, then proceeds.
        try store.saveMachine(third)
        let history = try store.machineHistory()
        #expect(history.map(\.revision) == [1, 2, 3])
        #expect(history[1].document == second)
        #expect(history[2].document == third)
        #expect(try store.loadMachineDocument() == third)
    }

    @Test func logArtifactsAreOwnerOnly() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")]))

        for url in [
            RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root),
            RVPolicyPaths.policyRevisionLogFile(inConfigDir: root),
            RVPolicyPaths.policyRevisionLogTipFile(inConfigDir: root),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        }
        let keyData = try Data(
            contentsOf: RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root)
        )
        #expect(keyData.count == 32)
    }

    @Test func repoLayerKeepsNoLog() throws {
        let config = try isolatedRevisionLogDirectory()
        let workspace = try isolatedRevisionLogDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        try store.saveRepo(
            PolicyDocument(rules: [denyRule(pattern: "repo", branch: "main")]),
            workspace: workspace
        )

        // The repo log would live in `.rv/` inside a workspace a caged
        // writer controls, so there is no repo log to forge or roll back.
        let dotRV = workspace.appendingPathComponent(".rv", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dotRV.path)
        #expect(names.contains(where: { $0.contains("revision") }) == false)
    }

    @Test func uninstallArtifactsIncludeRevisionLog() throws {
        let root = try isolatedRevisionLogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = RVPolicyPaths.uninstallArtifacts(inConfigDir: root).map(\.lastPathComponent)
        #expect(names.contains("policy-revisions.log"))
        #expect(names.contains(".policy-revisions.key"))
        #expect(names.contains(".policy-revisions.tip"))
        #expect(names.contains(".policy-revisions.lock"))
    }
}

// Shared with PolicyRevisionTests (cross-log agreement proofs use the same shapes).
func denyRule(pattern: String, branch: String) -> PolicyDocumentRule {
    PolicyDocumentRule(
        id: RuleID(pack: .coreGit, pattern: pattern),
        verdict: .deny,
        predicate: .gitPush(force: .exactly(.force), branch: branch)
    )
}

private func isolatedRevisionLogDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-revision-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func readLogLines(config: URL) throws -> [String] {
    let text = try String(
        contentsOf: RVPolicyPaths.policyRevisionLogFile(inConfigDir: config),
        encoding: .utf8
    )
    return text.split(separator: "\n").map(String.init)
}

private func writeLogLines(_ lines: [String], config: URL) throws {
    try (lines.joined(separator: "\n") + "\n").write(
        to: RVPolicyPaths.policyRevisionLogFile(inConfigDir: config),
        atomically: true,
        encoding: .utf8
    )
}

private func reencodeLogLine(
    _ line: String,
    mutate: (inout [String: Any]) throws -> Void
) throws -> String {
    let data = try #require(line.data(using: .utf8))
    var decoded = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    try mutate(&decoded)
    let encoded = try JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys])
    return try #require(String(data: encoded, encoding: .utf8))
}

private func flipFirstHexChar(_ mac: String) -> String {
    guard let first = mac.first else { return mac }
    let flipped: Character = first == "a" ? "b" : "a"
    return String(flipped) + mac.dropFirst()
}
