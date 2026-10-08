import Foundation
import RVDomain

/// `blocks.enabled` in `config.json`. Missing key is on.
public enum DenialLedgerPreferences {
    public static func isEnabled(inConfigDirectory directory: URL) -> Bool {
        let file = directory.appendingPathComponent("config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let enabled = root["blocks"]?["enabled"]?.bool
        else {
            return true
        }
        return enabled
    }
}
