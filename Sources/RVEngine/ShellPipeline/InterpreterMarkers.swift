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

func containsAnyWord(_ code: String, _ words: [String]) -> Bool {
    words.contains { containsWord(code, $0) }
}

func matches(_ code: String, pattern: String) -> Bool {
    code.range(of: pattern, options: .regularExpression) != nil
}

// MARK: python

/// Names whose mere mention in a Python program can run or delete things.
private let pythonDangerousWords: [String] = [
    "subprocess", "pty", "importlib", "ctypes", "__import__", "builtins", "__builtins__",
    "__subclasses__", "__globals__", "runpy", "popen", "posix", "unlink", "rmdir", "rmtree",
    "write_text", "write_bytes", "rename", "chmod", "chown", "symlink_to",
]

/// Modules whose attributes spawn processes or delete/move files.
private let pythonGuardedModules = "os|shutil|posix|nt"

private let osDangerousAttributes: Set<String> = [
    "system", "popen", "remove", "unlink", "rmdir", "removedirs", "rename", "renames", "replace",
    "kill", "killpg", "fork", "forkpty", "chmod", "chown", "truncate", "startfile", "symlink", "link",
]

private let shutilSafeAttributes: Set<String> = [
    "which", "disk_usage", "get_terminal_size", "get_archive_formats", "get_unpack_formats",
]

private func isDangerousModuleAttribute(module: String, attribute: String) -> Bool {
    if module == "shutil" { return shutilSafeAttributes.contains(attribute) == false }
    return osDangerousAttributes.contains(attribute) || attribute.hasPrefix("exec")
        || attribute.hasPrefix("spawn") || attribute.hasPrefix("posix_spawn")
}

/// Python programs that can run a process, delete or move files, or reach
/// them indirectly (aliased imports, `getattr`, `exec`). Plain data code,
/// including `os.getcwd()` and `re.compile(...)`, is not flagged.
func pythonCodeCanSpawn(_ code: String) -> Bool {
    // `eval("1+1")` over a pure arithmetic literal cannot run anything.
    let program = code.replacingOccurrences(
        of: #"eval\(\s*(["'])[0-9+\-*/%().\s]*\1\s*\)"#,
        with: "0",
        options: .regularExpression
    )
    if containsAnyWord(program, pythonDangerousWords) { return true }
    if matches(program, pattern: #"(?<![.\w])(exec|eval|compile|getattr)\s*\("#) { return true }
    if matches(program, pattern: #"\bsys\s*\.\s*modules\b"#) { return true }
    // Aliasing hides the module name from the attribute check below.
    if matches(program, pattern: "\\bimport\\s+[^;\\n]*\\b(\(pythonGuardedModules))\\b[\\w.]*\\s+as\\b") {
        return true
    }
    if pythonModuleAttributeIsDangerous(program) { return true }
    // Any remaining bare mention escapes the checks above: `x = os`, and
    // `from os import ...` (whose names are then called without the module).
    let bare = program
        .replacingOccurrences(
            of: "\\b(\(pythonGuardedModules))\\s*\\.\\s*\\w+", with: " ", options: .regularExpression
        )
        .replacingOccurrences(of: #"\bimport\s+[\w.]+(\s*,\s*[\w.]+)*"#, with: " ", options: .regularExpression)
    return containsAnyWord(bare, pythonGuardedModules.split(separator: "|").map(String.init))
}

private func pythonModuleAttributeIsDangerous(_ code: String) -> Bool {
    let pattern = "\\b(\(pythonGuardedModules))\\s*\\.\\s*(\\w+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
    let whole = NSRange(code.startIndex..., in: code)
    for match in regex.matches(in: code, range: whole) {
        guard let moduleRange = Range(match.range(at: 1), in: code),
            let attributeRange = Range(match.range(at: 2), in: code)
        else { continue }
        let module = String(code[moduleRange])
        if isDangerousModuleAttribute(module: module == "posix" || module == "nt" ? "os" : module,
                                      attribute: String(code[attributeRange]))
        {
            return true
        }
    }
    return false
}

// MARK: node

func nodeCodeCanSpawn(_ code: String) -> Bool {
    code.contains("child_process") || code.contains("process.binding")
        || matches(
            code,
            pattern: #"\b(fs|promises)\.(rm|rmSync|unlink|unlinkSync|rmdir|rmdirSync|writeFile|writeFileSync|rename|renameSync)\b"#
        )
        || containsAnyWord(code, ["execSync", "spawnSync", "execFile", "execFileSync", "spawn", "fork"])
        || matches(code, pattern: #"\b(require|import)\s*\(\s*[^'"\s)]"#)
}

// MARK: ruby

private let rubyDangerousWords: [String] = [
    "system", "exec", "spawn", "fork", "eval", "instance_eval", "class_eval", "module_eval",
    "send", "public_send", "__send__", "const_get", "syscall", "Kernel", "FileUtils", "Open3", "PTY",
]

/// Ruby programs that can run a process, delete or rewrite files, or reach
/// those indirectly. `Process.pid` and `IO.readlines("f")` are not flagged.
func rubyCodeCanSpawn(_ code: String) -> Bool {
    if code.contains("`") || code.contains("%x") { return true }
    if containsAnyWord(code, rubyDangerousWords) { return true }
    let patterns = [
        #"\bProcess\.(spawn|exec|fork|kill|daemon|detach|setsid)\b"#,
        #"\bIO\.(popen|write|binwrite|copy_stream|sysopen|new|for_fd|pipe)\b"#,
        #"\bFile\.(delete|unlink|rename|write|binwrite|chmod|chown|truncate|symlink|link)\b"#,
        #"\bDir\.(rmdir|delete|unlink|mkdir)\b"#,
        #"\.(public_)?method\s*\("#,
        // Kernel#open and IO class readers run a command for a leading `|`;
        // only a literal path that does not start with one is safe.
        #"\bIO\.(read|readlines|foreach|binread)\b(?>\s*(?:\(\s*)?)(?!["'][^|"'])"#,
        #"(?<![.\w])open\b(?>\s*(?:\(\s*)?)(?!["'][^|"'])"#,
    ]
    return patterns.contains { matches(code, pattern: $0) }
}

// MARK: perl

func perlCodeCanSpawn(_ code: String) -> Bool {
    // `eval { ... }` is a trapping block, not string evaluation.
    let program = code.replacingOccurrences(of: #"\beval\s*\{"#, with: "{", options: .regularExpression)
    return program.contains("`")
        || containsAnyWord(program, [
            "system", "exec", "qx", "unlink", "rmtree", "remove_tree", "rmdir", "rename", "fork", "eval",
        ])
        || matches(program, pattern: #"\bopen\s*\(?[^;]*\|"#)
}

// MARK: php

private let phpDangerousWords: [String] = [
    "system", "exec", "shell_exec", "passthru", "popen", "proc_open", "unlink", "rmdir", "rename",
    "eval", "assert", "include", "include_once", "require", "require_once", "call_user_func",
    "call_user_func_array", "forward_static_call", "array_map", "array_walk", "array_filter",
    "array_reduce", "usort", "uasort", "uksort", "register_shutdown_function", "ob_start",
    "create_function", "file_put_contents", "fopen", "touch", "chmod", "chown", "symlink", "copy",
    "invoke", "FFI",
]

/// PHP programs that can run code or touch files. Variable and string
/// callables (`$f(...)`, `("sys"."tem")(...)`) defeat any name list, so
/// they limit too.
func phpCodeCanSpawn(_ code: String) -> Bool {
    code.contains("`") || code.contains("pcntl")
        || containsAnyWord(code, phpDangerousWords)
        || matches(code, pattern: #"\$+\{?\w*\}?(\[[^\]]*\])*\s*\("#)
        || matches(code, pattern: #"\)\s*\("#)
        || matches(code, pattern: #"["']\s*\("#)
}

// MARK: lua

private let luaDangerousWords: [String] = [
    "os", "io", "require", "load", "loadstring", "loadfile", "dofile", "package", "debug", "_G", "_ENV",
]

func luaCodeCanSpawn(_ code: String) -> Bool {
    containsAnyWord(code, luaDangerousWords)
}
