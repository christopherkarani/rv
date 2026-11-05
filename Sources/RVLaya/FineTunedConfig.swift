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
