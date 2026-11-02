import Foundation

/// Marker predicates for inline interpreter programs whose exact inner
/// command rv cannot extract. A hit means the program can spawn processes or
/// delete files, so the unwrap fails closed (`.limited`). Plain data-only
/// programs (`print(1)`, `{print $1}`) stay allowed.

/// True when `word` occurs in `code` delimited by non-identifier characters.
func containsWord(_ code: String, _ word: String) -> Bool {
    var searchStart = code.startIndex
    while let range = code.range(of: word, range: searchStart..<code.endIndex) {
        let before = range.lowerBound == code.startIndex
            ? nil : code[code.index(before: range.lowerBound)]
        let after = range.upperBound == code.endIndex ? nil : code[range.upperBound]
        if isIdentifierBoundary(before), isIdentifierBoundary(after) {
            return true
        }
        searchStart = range.upperBound
    }
    return false
}

private func isIdentifierBoundary(_ character: Character?) -> Bool {
    guard let character else { return true }
    return character.isLetter == false && character.isNumber == false && character != "_"
}

private func containsAnyWord(_ code: String, _ words: [String]) -> Bool {
    words.contains { containsWord(code, $0) }
}

private func matches(_ code: String, pattern: String) -> Bool {
    code.range(of: pattern, options: .regularExpression) != nil
}

func pythonCodeCanSpawn(_ code: String) -> Bool {
    containsAnyWord(code, [
        "os", "subprocess", "shutil", "pty", "importlib", "ctypes", "__import__",
        "exec", "eval", "compile", "popen", "posix", "unlink", "rmdir", "rmtree",
    ])
}

func nodeCodeCanSpawn(_ code: String) -> Bool {
    code.contains("child_process") || code.contains("process.binding")
        || matches(
            code,
            pattern: #"\b(fs|promises)\.(rm|rmSync|unlink|unlinkSync|rmdir|rmdirSync|writeFile|writeFileSync|rename|renameSync)\b"#
        )
        || containsAnyWord(code, ["execSync", "spawnSync", "execFile", "execFileSync", "spawn", "fork"])
        || matches(code, pattern: #"\b(require|import)\s*\(\s*[^'"\s)]"#)
}

func rubyCodeCanSpawn(_ code: String) -> Bool {
    containsAnyWord(code, [
        "system", "exec", "spawn", "eval", "Kernel", "FileUtils", "IO", "Open3",
        "Process", "PTY",
    ]) || matches(code, pattern: #"\bFile\.(delete|unlink|rename)\b"#)
}

func perlCodeCanSpawn(_ code: String) -> Bool {
    code.contains("`")
        || containsAnyWord(code, [
            "system", "exec", "qx", "unlink", "rmtree", "remove_tree", "rmdir", "rename", "fork", "eval",
        ])
        || matches(code, pattern: #"\bopen\s*\(?[^;]*\|"#)
}

func phpCodeCanSpawn(_ code: String) -> Bool {
    code.contains("`")
        || containsAnyWord(code, [
            "system", "exec", "shell_exec", "passthru", "popen", "proc_open", "unlink", "rmdir",
            "rename", "eval", "pcntl_exec",
        ])
}

func luaCodeCanSpawn(_ code: String) -> Bool {
    code.contains("os.execute") || code.contains("io.popen") || code.contains("os.remove")
        || code.contains("os.rename") || containsAnyWord(code, ["loadstring", "dofile", "load"])
}

func awkCodeCanSpawn(_ code: String) -> Bool {
    matches(code, pattern: #"\bsystem\s*\("#)
        || matches(code, pattern: #"(^|[^|])\|\s*""#)
        || code.contains("|&")
        || matches(code, pattern: #"\|\s*getline"#)
        || matches(code, pattern: #"\bprintf?\b[^;}\n]*>>?\s*[^=\s]"#)
}
