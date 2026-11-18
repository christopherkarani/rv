#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A `config.json` write refused because rv cannot rewrite the file without
/// changing what it means (`MachineConfigJSONError.unreadableConfig`,
/// `HostModeStoreError.unreadableConfig`). Nothing was written; only the
/// owner can say which reading was meant, so they fix the file by hand.
enum ConfigUnreadableRefusal {
    /// sysexits(3) EX_DATAERR: the input file is bad, not the write.
    static let exitCode: Int32 = EX_DATAERR

    static let phrase = "config.json cannot be rewritten safely, so nothing was written"

    static let detail = [
        "it (or a value rv must edit in it) is not a JSON object, or it repeats a key, "
            + "has a key containing U+FEFF, nests deeper than 64, or is not UTF-8",
        "fix config.json by hand, then retry",
    ]

    /// `"<prefix>: <phrase>"` and the detail lines, newline-terminated.
    static func message(prefix: String) -> String {
        (["\(prefix): \(phrase)"] + detail).joined(separator: "\n") + "\n"
    }
}
