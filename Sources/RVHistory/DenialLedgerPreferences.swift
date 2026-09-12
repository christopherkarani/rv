import Foundation

/// `blocks.enabled` in `config.json`. Missing key is on.
public enum DenialLedgerPreferences {
    public static func isEnabled(inConfigDirectory directory: URL) -> Bool {
        let file = directory.appendingPathComponent("config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["blocks"] as? [String: Any],
              let enabled = blocks["enabled"] as? Bool
        else {
            return true
        }
        return enabled
    }
}
