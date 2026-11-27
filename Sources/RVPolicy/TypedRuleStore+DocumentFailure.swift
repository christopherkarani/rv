import Foundation
import RVDomain

/// Why a policy layer does not load, with the line, key and fix when it is
/// a parse error. The same read as evaluation (`readDocument`), so what this
/// reports is exactly what made the layer fail.
extension TypedRuleStore {
    /// Nil when the machine layer loads.
    public func machineDocumentFailure() -> PolicyFileFailure? {
        Self.documentResult(toml: machineFileURL, json: machineLegacyJSONURL).failure
    }

    /// Nil when the repo layer loads.
    public func repoDocumentFailure(workspace: URL) -> PolicyFileFailure? {
        Self.documentResult(
            toml: Self.repoFileURL(workspace: workspace), json: Self.repoLegacyJSONURL(workspace: workspace)
        ).failure
    }

    /// `policy.toml` when it exists, else the legacy JSON; read-only.
    static func documentResult(toml: URL, json: URL) -> Result<PolicyDocument, PolicyFileFailure> {
        let text: String?
        do {
            text = try readPolicyFile(toml, as: { String(validating: $0, as: UTF8.self) }, else: .notUTF8)
        } catch {
            return .failure(PolicyFileFailure(file: toml, reason: .load(loadProblem(error))))
        }
        if let text {
            do {
                return .success(try PolicyDocumentTOML.parse(text))
            } catch let error as PolicyDocumentError {
                return .failure(PolicyFileFailure(
                    file: toml, reason: error.problem.map { .parse($0) } ?? .load(.unparseable)))
            } catch {
                return .failure(PolicyFileFailure(file: toml, reason: .load(.unparseable)))
            }
        }
        do {
            return .success(try readLegacyJSON(from: json))
        } catch {
            return .failure(PolicyFileFailure(file: json, reason: .load(loadProblem(error))))
        }
    }

    private static func loadProblem(_ error: any Error) -> PolicyLoadStatus.Problem {
        (error as? PolicyLoadStatus.Problem) ?? .unreadable
    }
}

extension PolicyFileFailure: Error {}

extension PolicyFileFailure.Reason {
    /// The load status evaluation records: a parse error is `unparseable`.
    var loadProblem: PolicyLoadStatus.Problem {
        switch self {
        case .parse: return .unparseable
        case .load(let problem): return problem
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
