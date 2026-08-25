import Foundation
import RVDomain
import RVEngine
import RVPacks

/// Failures loading packs for session-scan classify.
public enum ScanClassifyError: Error, Sendable, Equatable {
    case packsUnavailable
}

/// Warmed pack world: `PackRegistry` snapshots + `ICUPatternEngine` → deny-only findings via `evaluate`.
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
            compiled = CompiledPacks(packs: [])
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
            let result = evaluate(
                request,
                packs: snapshots,
                patterns: engine,
                compiled: compiled
            )
            guard case .deny(let deny, let matched) = result.outcome else {
                continue
            }
            findings.append(
                ScanFinding(
                    host: event.host,
                    sessionID: event.sessionID,
                    sourcePath: event.sourcePath,
                    occurredAt: event.occurredAt,
                    ruleID: deny.ruleID,
                    packID: matched?.packID ?? deny.ruleID.pack,
                    matchingView: result.matchingView,
                    count: 1,
                    lastSeen: event.occurredAt
                )
            )
        }
        return findings
    }
}
