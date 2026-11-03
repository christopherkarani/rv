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
    "write_text", "write_bytes", "rename", "chmod", "chown", "symlink_to", "touch",
    "O_WRONLY", "O_RDWR", "O_CREAT", "O_APPEND", "O_TRUNC",
    // A changed cwd breaks the repo-relative resolution of literal write paths.
    "chdir", "fchdir", "chroot",
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
    let program = removingBenignEval(code, arithmeticLiterals: true, blockEval: false)
    if pythonFileWrites(program).opaque { return true }
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
            pattern: #"\b(fs|promises)\.(rm|rmSync|unlink|unlinkSync|rmdir|rmdirSync|rename|renameSync)\b"#
        )
        || containsAnyWord(code, ["execSync", "spawnSync", "execFile", "execFileSync", "spawn", "fork", "chdir", "chroot"])
        || nodeFileWrites(code).opaque
        || nodeReachesFileSystem(code)
        || matches(code, pattern: #"\b(require|import)\s*\(\s*[^'"\s)]"#)
}

/// A bare call of a deleting or moving `fs` function, however `fs` was
/// obtained (`const f = require("fs"); f.rmSync(...)`, `const {rmSync} =
/// require("fs"); rmSync(...)`). Writes are scanned separately
/// (`nodeFileWrites`) so a literal in-repo path can still pass.
private func nodeReachesFileSystem(_ code: String) -> Bool {
    containsAnyWord(code, [
        "rm", "rmSync", "unlink", "unlinkSync", "rmdir", "rmdirSync", "rename", "renameSync",
    ])
}

// MARK: ruby

private let rubyDangerousWords: [String] = [
    "system", "exec", "spawn", "fork", "eval", "instance_eval", "class_eval", "module_eval",
    "send", "public_send", "__send__", "const_get", "syscall", "Kernel", "FileUtils", "Open3", "PTY",
    "chdir", "chroot", "fchdir",
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
    ]
    return patterns.contains { matches(code, pattern: $0) } || rubyOpenIsUnsafe(code)
        || rubyFileWrites(code).opaque
}

/// A bare `open` (Kernel#open runs a command for a leading `|`) unless a
/// literal path that does not start with `|` follows. Candidates are found
/// with string contents and comments blanked, so prose such as "Could not
/// open file" does not count; the literal check reads the original text.
private func rubyOpenIsUnsafe(_ code: String) -> Bool {
    let masked = maskingLiteralsAndComments(code, language: .ruby)
    guard let regex = try? NSRegularExpression(pattern: #"(?<![.\w])open\b(?>\s*(?:\(\s*)?)"#) else { return true }
    let units = Array(code.utf16)
    for match in regex.matches(in: masked, range: NSRange(masked.startIndex..., in: masked)) {
        let end = match.range.location + match.range.length
        guard end + 1 < units.count else { return true }
        let quote = units[end]
        let next = units[end + 1]
        let isQuote = quote == 0x22 || quote == 0x27
        if isQuote == false || next == 0x7C || next == quote { return true }
    }
    return false
}

// MARK: perl

func perlCodeCanSpawn(_ code: String) -> Bool {
    // `eval { ... }` is a trapping block, not string evaluation.
    let program = removingBenignEval(code, arithmeticLiterals: false, blockEval: true)
    return program.contains("`")
        || containsAnyWord(program, [
            "system", "exec", "qx", "unlink", "rmtree", "remove_tree", "rmdir", "rename", "fork", "eval",
            "sysopen", "chdir", "chroot",
        ])
        || matches(program, pattern: #"\b(IO::File|File::Copy|File::Path|File::Find)\b"#)
        // A variable open mode or 2-arg path may carry `>`.
        || matches(program, pattern: #"\bopen\s*\(?\s*[\w$*]+\s*,\s*\$"#)
        || matches(program, pattern: #"\bopen\s*\(?[^;]*\|"#)
        // Write/append/update opens (`open(F, ">", p)`, `open F, ">p"`) and
        // the in-place variable `$^I`.
        || matches(program, pattern: #"\bopen\b[^;]*["']\s*(\+<|\+>|>)"#)
        || matches(program, pattern: #"\$\^I"#)
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
