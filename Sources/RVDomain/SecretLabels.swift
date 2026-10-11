/// Secret-label validators: item and field names are opaque operator
/// text, bounded, without control bytes. Shared by the bindings store
/// (ref allowlist) and the file values store (document keys) so both
/// agree on what a label can be. Unknown labels simply fail closed at
/// resolve time.
public enum SecretLabels {
    /// Longest item label in UTF-8 bytes.
    public static let maximumItemBytes = 256
    /// Longest field label in UTF-8 bytes.
    public static let maximumFieldBytes = 128

    /// Item labels: non-empty, bounded, no NUL/CR/LF.
    public static func isValidItem(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumItemBytes
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }

    /// Field labels: non-empty, bounded, no NUL/CR/LF.
    public static func isValidField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumFieldBytes
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }
}
