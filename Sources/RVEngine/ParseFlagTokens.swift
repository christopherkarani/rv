/// Thin adapter over the C1 shared flag grammar (`FlagToken`).
///
/// Kept so the T3b-owned per-command parsers and their tests keep working
/// unchanged until they move onto `ShellPipeline.scanFlags` directly.
func clusteredShorts(_ token: String) -> [Character]? {
    guard case .shorts(let letters, _) = FlagToken.classify(token) else {
        return nil
    }
    return letters
}

/// Git long-option `=value`. Named apart from unwrap's private `attachedValue`.
func gitAttachedValue(_ token: String, long: String) -> String? {
    guard case .long(let name, let value) = FlagToken.classify(token),
        "--" + name == long,
        let value,
        value.isEmpty == false
    else {
        return nil
    }
    return value
}
