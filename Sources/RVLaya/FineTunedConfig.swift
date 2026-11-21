import Foundation

extension LayaVerdict.Action {
    /// The fine-tuned bundle's label order from a parsed `config.json`.
    /// `logit_order` wins over `labels`. Absent returns nil (use the shipped
    /// default order). A present value that is not a string array holding
    /// exactly allow/review/block once each throws: guessing the order could
    /// read block as allow. Shared by the loader and `rv doctor`.
    public static func configLabels(_ cfg: [String: Any]) throws -> [LayaVerdict.Action]? {
        for key in ["logit_order", "labels"] {
            guard let value = cfg[key] else { continue }
            guard let strings = value as? [String] else {
                throw LayaError.badBundle("\(key) in config.json is not a string array")
            }
            return try parse(labels: strings)
        }
        return nil
    }
}

/// A fine-tuned bundle's calibrated operating point: `risk` at or above
/// `block` blocks, at or above `review` reviews. Both finite, in (0, 1],
/// `review < block`; anything else is a bad bundle (or, off the judge-pool
/// wire, a verdict that fails to decode).
public struct LayaThresholds: Sendable, Equatable, Codable {
    public let block: Double
    public let review: Double

    public init(block: Double, review: Double) throws {
        guard block.isFinite, review.isFinite,
              review > 0, block <= 1, review < block else {
            throw LayaError.badBundle(
                "thresholds in config.json must satisfy 0 < review < block <= 1 (got block \(block), review \(review))")
        }
        self.block = block
        self.review = review
    }

    private enum CodingKeys: String, CodingKey {
        case block, review
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            block: try c.decode(Double.self, forKey: .block),
            review: try c.decode(Double.self, forKey: .review))
    }
}

/// The calibration a v3 fine-tuned bundle ships in `config.json`
/// (`Scripts/laya/training/convert_ft.py --version v3`): a softmax
/// `temperature` and the `thresholds` the calibration chose. v2 bundles
/// have neither: temperature 1, no thresholds (the runtime keeps its fixed
/// operating point). Shared by the loader and `rv doctor`.
public struct FineTunedCalibration: Sendable, Equatable {
    /// Plausible temperatures; anything outside is a broken calibration.
    public static let temperatureRange: ClosedRange<Double> = 0.05...20

    /// The v2 calibration: raw logits, runtime thresholds.
    public static let uncalibrated = FineTunedCalibration(temperature: 1, thresholds: nil)

    public let temperature: Double
    public let thresholds: LayaThresholds?

    init(temperature: Double, thresholds: LayaThresholds?) {
        self.temperature = temperature
        self.thresholds = thresholds
    }

    /// Reads `temperature` and `thresholds` from a parsed `config.json`.
    /// Absent keys keep the v2 defaults. A present value of the wrong type,
    /// a temperature that is not finite and in `temperatureRange`, or
    /// thresholds `LayaThresholds` refuses throws `badBundle`: a wrong
    /// operating point could read block as allow.
    public static func parse(_ cfg: [String: Any]) throws -> FineTunedCalibration {
        var temperature = 1.0
        if let value = cfg["temperature"] {
            guard let number = value as? NSNumber else {
                throw LayaError.badBundle("temperature in config.json is not a number")
            }
            temperature = number.doubleValue
            guard temperature.isFinite, temperatureRange.contains(temperature) else {
                throw LayaError.badBundle("temperature in config.json is outside \(temperatureRange)")
            }
        }
        var thresholds: LayaThresholds?
        if let value = cfg["thresholds"] {
            guard let object = value as? [String: Any],
                  let block = object["block"] as? NSNumber,
                  let review = object["review"] as? NSNumber else {
                throw LayaError.badBundle("thresholds in config.json is not {\"block\": number, \"review\": number}")
            }
            thresholds = try LayaThresholds(block: block.doubleValue, review: review.doubleValue)
        }
        return FineTunedCalibration(temperature: temperature, thresholds: thresholds)
    }

    /// Softmax of `logits / temperature` (max-subtracted). Temperature 1
    /// is the plain softmax, bit for bit: `z / 1.0 == z`.
    public func probabilities(logits: [Double]) -> [Double] {
        let z = logits.map { $0 / temperature }
        let peak = z.max() ?? 0
        let exps = z.map { exp($0 - peak) }
        let total = exps.reduce(0, +)
        return exps.map { $0 / max(total, .leastNonzeroMagnitude) }
    }
}
