import Foundation

/// Linux judge seam (Phase 3). The ONNX bundle is produced by
/// `Scripts/laya/export-onnx.sh` from the pinned upstream checkpoint.
/// Until the ONNX Runtime C-API wrapper lands, this conformer reports
/// unavailable - which the gate treats as abstain (shadow: ignored;
/// enforce: fail-closed Ask). It never invents an allow.
public struct LayaONNXJudge: Sendable {
    public var bundleDir: URL

    public init(bundleDir: URL) {
        self.bundleDir = bundleDir
    }

    public var bundlePresent: Bool {
        FileManager.default.fileExists(atPath: bundleDir.appendingPathComponent("laya.onnx").path)
    }

    public func judge(_ command: String) throws -> LayaVerdict {
        throw LayaError.modelUnavailable(
            bundlePresent
                ? "ONNX Runtime wrapper not built in this target yet"
                : "no ONNX bundle at \(bundleDir.path)"
        )
    }
}
