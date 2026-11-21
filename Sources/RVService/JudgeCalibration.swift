import Foundation
import RVDomain
import RVLaya

/// A calibrated (v3) fine-tuned bundle's operating point: how a verdict's
/// bundle thresholds combine with provenance, and what doctor shows.
extension JudgeRuntime {
    /// The operating point one verdict is read at. Without bundle
    /// thresholds (v2 bundles, the stock engine) it is the fixed
    /// `thresholds(provenance:)`. With them (a calibrated v3 bundle),
    /// trusted provenance uses the bundle's values; untrusted provenance
    /// takes the stricter (lower) of each bundle value and the fixed
    /// untrusted one, so a calibration never loosens untrusted input.
    public static func thresholds(
        provenance: ActionProvenance,
        bundle: LayaThresholds?
    ) -> (block: Double, review: Double) {
        let fixed = thresholds(provenance: provenance)
        guard let bundle else { return fixed }
        guard provenance.isUntrusted else { return (bundle.block, bundle.review) }
        return (min(bundle.block, fixed.block), min(bundle.review, fixed.review))
    }

    /// The calibration a fine-tuned bundle's `config.json` ships, for
    /// doctor. Nil when there is no readable config or it does not parse
    /// (`bundleProblems` reports that); `.uncalibrated` for a v2 bundle.
    static func bundleCalibration(dir: URL) -> FineTunedCalibration? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return try? FineTunedCalibration.parse(cfg)
    }

    /// Doctor's note on a calibrated (v3) bundle's operating point; nil
    /// for a v2 bundle, which runs at the fixed thresholds.
    static func calibrationNote(bundle: URL) -> String? {
        calibrationNote(bundleCalibration(dir: bundle))
    }

    static func calibrationNote(_ calibration: FineTunedCalibration?) -> String? {
        guard let calibration, let t = calibration.thresholds else { return nil }
        func fmt(_ x: Double) -> String { String(format: "%.3g", x) }
        return "bundle thresholds block \(fmt(t.block)), review \(fmt(t.review)), "
            + "temperature \(fmt(calibration.temperature)) (untrusted input: stricter of these and 0.6/0.3)"
    }
}
