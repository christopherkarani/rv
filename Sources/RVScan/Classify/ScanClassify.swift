import Foundation
import RVDomain
import RVEngine
import RVPacks

/// Failures loading packs for session-scan classify.
public enum ScanClassifyError: Error, Sendable, Equatable {
    case packsUnavailable
}

/// Warmed pack world: `PackRegistry` snapshots + `ICUPatternEngine` → deny-only
/// findings via the evaluation door (`evaluateWithSemantics`). Nil event cwd is
/// **unprobed**: pack deny stays the floor, unwrap-limited still tightens,
/// unresolved-path does not tighten an allow. Non-nil cwd injects a **probed**
/// lexical filesystem context (catalog `.dayOne`, empty facts). Repository
/// root stays nil unless it can be derived without `FileManager` — probed
/// unknown writes stay fail-closed. No Policy gate, grant spend, or history.
public struct ScanClassify: Sendable {
    public let enabledPacks: [PackID]

    private let snapshots: [PackSnapshot]
    private let compiled: CompiledPacks<ICUCompiledPattern>
    private let engine: ICUPatternEngine

    public init(
        enabledPacks: [PackID] = dayOnePackIDs,
        snapshots: [PackSnapshot]? = nil
    ) throws {
        let loaded: [PackSnapshot]
        if let snapshots {
            loaded = snapshots
        } else if let all = try? PackRegistry.loadAll(), all.isEmpty == false {
            loaded = all
        } else if let dayOne = try? PackRegistry.loadDayOne(), dayOne.isEmpty == false {
            loaded = dayOne
        } else {
            throw ScanClassifyError.packsUnavailable
        }

        let enabled = Set(enabledPacks)
        let toCompile = loaded.filter { enabled.contains($0.id) }
        let engine = ICUPatternEngine()
        let compiled: CompiledPacks<ICUCompiledPattern>
        do {
            compiled = try CompiledPacks.compile(packs: toCompile, using: engine)
        } catch {
            throw ScanClassifyError.packsUnavailable
        }
        guard corePacksAreReady(snapshots: loaded, compiled: compiled) else {
            throw ScanClassifyError.packsUnavailable
        }

        self.enabledPacks = enabledPacks
        self.snapshots = loaded
        self.compiled = compiled
        self.engine = engine
    }

    /// One finding per deny outcome. Allows and indeterminates are dropped.
    public func classify(_ events: [ExtractedEvent]) -> [ScanFinding] {
        var findings: [ScanFinding] = []
        findings.reserveCapacity(events.count)
        for event in events {
            let request = EvaluationRequest(
                command: event.command,
                enabledPacks: enabledPacks
            )
            // Unwrap starts from store cwd so relative `-C` / `--chdir` cannot
            // drop `..` against a nil base and then classify against the store path.
            let gitContext = GitAnalysisContext(
                workingDirectory: event.workingDirectory
            )
            let result = evaluateWithSemantics(
                request,
                packs: snapshots,
                patterns: engine,
                compiled: compiled,
                gitContext: gitContext,
                filesystemProbe: { _ in Self.lexicalFilesystemContext(for: event) }
            )
            guard case .deny(let deny, _) = result.outcome else {
                continue
            }
            findings.append(
                ScanFinding(
                    host: event.host,
                    sessionID: event.sessionID,
                    sourcePath: event.sourcePath,
                    occurredAt: event.occurredAt,
                    ruleID: deny.ruleID,
                    packID: deny.ruleID.pack,
                    matchingView: result.matchingView,
                    count: 1,
                    lastSeen: event.occurredAt
                )
            )
        }
        return findings
    }

    /// Probed lexical world when the store already recorded cwd. No live I/O.
    private static func lexicalFilesystemContext(
        for event: ExtractedEvent
    ) -> FilesystemAnalysisContext {
        guard let cwd = event.workingDirectory else {
            return .empty
        }
        return FilesystemAnalysisContext(
            workingDirectory: cwd,
            repositoryRoot: nil,
            catalog: .dayOne,
            facts: [],
            probe: .probed
        )
    }
}
