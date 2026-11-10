import RVDomain

/// Git configuration and programs the gate cannot see from the command
/// text: config handed through the environment, config keys that include
/// other files or name a program git runs, and invocations whose git
/// subcommand or program is not statically known.

/// Environment names that hand git a program to run or a different
/// repository, beyond the `GIT_CONFIG*` family in `GitConfigEnvironment`.
private let gitProgramEnvironmentNames: Set<String> = [
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_EXEC_PATH",
    "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR",
    "GIT_PAGER", "GIT_EXTERNAL_DIFF", "GIT_PROXY_COMMAND", "GIT_TEMPLATE_DIR",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_OBJECT_DIRECTORY",
]

/// True when `name` (an assignment or `env` word's name) changes which
/// config, repository, or helper program git uses.
func isGitEnvironmentOverride(_ name: String) -> Bool {
    GitConfigEnvironment.suppliesConfig(name) || gitProgramEnvironmentNames.contains(name.uppercased())
}

/// True when `command` both assigns a git environment override (prefix,
/// `env NAME=…`, `export NAME=…`, or the same inside a `bash -c '…'`
/// payload) and runs git. The assignment is stripped from every view the
/// gate judges, so the config or program it names is invisible: fail
/// closed.
func gitEnvironmentInjection(_ command: String) -> Bool {
    var assignsOverride = false
    var runsGit = false
    for token in ShellPipeline.tokenize(command) {
        // A token is an assignment word itself, or a payload whose
        // statements may lead with assignments; a quoted message that
        // merely mentions `GIT_DIR=` mid-text is neither.
        // A whole word `GIT_PAGER=cat` is inert; the same text inside a
        // payload or next to more shell text is not.
        let inertWord = isShellAssignmentWord(token.lexeme)
            && isInertProgramSetting(assignmentName(token.lexeme), value: assignmentValue(token.lexeme))
        for statement in token.lexeme.split(whereSeparator: { ";&|(){}`\n".contains($0) }) {
            let words = statement.split(whereSeparator: \.isWhitespace).map(String.init)
            for word in words {
                if unescapeBackslashPairs(basename(word)).lowercased() == "git" { runsGit = true }
            }
            for word in leadingAssignmentWords(words) where isGitEnvironmentOverride(assignmentName(word)) {
                if inertWord == false { assignsOverride = true }
            }
        }
        if assignsOverride && runsGit { return true }
    }
    return false
}

/// The assignment words a statement starts with, also after the
/// assignment builtins (`env`, `export`, `declare -x`, ...).
private func leadingAssignmentWords(_ words: [String]) -> [String] {
    var rest = words[...]
    if let head = rest.first, ["env", "export", "declare", "typeset", "local", "readonly"].contains(head) {
        rest = rest.dropFirst().drop { $0.hasPrefix("-") }
    }
    return Array(rest.prefix { isShellAssignmentWord($0) })
}

func isShellAssignmentWord(_ word: String) -> Bool {
    guard let eq = word.firstIndex(of: "="), eq > word.startIndex else { return false }
    let name = assignmentName(word)
    guard let first = name.first, first.isLetter || first == "_" else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

private func assignmentName(_ word: String) -> String {
    var name = String(word.prefix { $0 != "=" })
    if name.hasSuffix("+") { name.removeLast() }
    return name
}

private func assignmentValue(_ word: String) -> String {
    guard let eq = word.firstIndex(of: "=") else { return "" }
    return String(word[word.index(after: eq)...])
}

/// Pager and editor settings (config key or environment name) whose whole
/// value is one of `inertProgramValues`: the program git runs is then a
/// known no-op or plain viewer, so the setting hides nothing.
func isInertProgramSetting(_ name: String, value: String) -> Bool {
    let name = name.lowercased()
    let pagerOrEditor = ["core.pager", "core.editor", "sequence.editor", "git_pager", "git_editor", "git_sequence_editor"]
        .contains(name) || name.hasPrefix("pager.")
    return pagerOrEditor && inertProgramValues.contains(value)
}

private let inertProgramValues: Set<String> = ["", "cat", "less", "less -R", "less -FRX", "more", "true", ":"]

/// True for a config key whose value includes another config file or is
/// a program (or program path) git runs. Such a value is not visible
/// command text, so the gate cannot judge what runs.
func isProgramOrIncludeConfigKey(_ key: String) -> Bool {
    let key = key.lowercased()
    if programConfigKeys.contains(key) { return true }
    if programConfigPrefixes.contains(where: { key.hasPrefix($0) }) { return true }
    guard let last = key.split(separator: ".").last, key.contains(".") else { return false }
    return programConfigLastComponents.contains(String(last))
}

private let programConfigKeys: Set<String> = [
    "include.path", "core.fsmonitor", "core.pager", "core.sshcommand", "core.hookspath",
    "core.editor", "core.askpass", "core.gitproxy", "core.alternaterefscommand",
    "core.worktree", "sequence.editor", "diff.external", "credential.helper",
    "gpg.program", "uploadpack.packobjectshook", "interactive.difffilter",
    "protocol.allow", "init.templatedir", "receive.procreceiverefs", "ssh.variant",
    "sendemail.sendmailcmd", "sendemail.smtpserver", "web.browser", "instaweb.httpd",
]

/// `includeIf.<cond>.path`, `pager.<cmd>`, `protocol.<name>.allow`, ...
private let programConfigPrefixes = ["includeif.", "pager.", "protocol."]

/// `diff.<driver>.command`, `filter.<x>.smudge`, `credential.<url>.helper`,
/// `mergetool.<x>.cmd`, `gpg.<fmt>.program`, `remote.<x>.uploadpack`, ...
private let programConfigLastComponents: Set<String> = [
    "command", "cmd", "program", "helper", "driver", "textconv", "clean", "smudge",
    "process", "uploadpack", "receivepack", "path",
]

/// Git subcommands rv treats as known: git's own commands (porcelain,
/// plumbing, helpers) plus `lfs`. Anything else is an alias or extension
/// defined outside the command line, whose body rv cannot see.
let knownGitSubcommands: Set<String> = [
    // Main porcelain.
    "add", "am", "archive", "backfill", "bisect", "branch", "bundle", "checkout",
    "cherry-pick", "citool", "clean", "clone", "commit", "describe", "diff", "fetch",
    "format-patch", "gc", "gitk", "grep", "gui", "init", "log", "maintenance", "merge",
    "mv", "notes", "pull", "push", "range-diff", "rebase", "reset", "restore", "revert",
    "rm", "scalar", "shortlog", "show", "sparse-checkout", "stage", "stash", "status",
    "submodule", "switch", "tag", "worktree",
    // Ancillary.
    "config", "fast-export", "fast-import", "filter-branch", "mergetool", "pack-refs",
    "prune", "reflog", "refs", "remote", "repack", "replace", "annotate", "blame",
    "bugreport", "count-objects", "diagnose", "difftool", "fsck", "gitweb", "help",
    "instaweb", "merge-tree", "rerere", "show-branch", "verify-commit", "verify-tag",
    "version", "whatchanged",
    // Interacting with others.
    "archimport", "cvsexportcommit", "cvsimport", "cvsserver", "imap-send", "p4",
    "quiltimport", "request-pull", "send-email", "svn",
    // Plumbing.
    "apply", "checkout-index", "commit-graph", "commit-tree", "hash-object", "index-pack",
    "merge-file", "merge-index", "mktag", "mktree", "multi-pack-index", "pack-objects",
    "prune-packed", "read-tree", "replay", "symbolic-ref", "unpack-objects",
    "update-index", "update-ref", "write-tree", "cat-file", "cherry", "diff-files",
    "diff-index", "diff-tree", "for-each-ref", "for-each-repo", "get-tar-commit-id",
    "ls-files", "ls-remote", "ls-tree", "merge-base", "name-rev", "pack-redundant",
    "rev-list", "rev-parse", "show-index", "show-ref", "unpack-file", "var",
    "verify-pack", "daemon", "fetch-pack", "http-backend", "send-pack",
    "update-server-info", "upload-pack", "receive-pack", "upload-archive", "shell",
    "http-fetch", "http-push",
    // Helpers.
    "check-attr", "check-ignore", "check-mailmap", "check-ref-format", "column",
    "credential", "credential-cache", "credential-store", "fmt-merge-msg", "hook",
    "interpret-trailers", "mailinfo", "mailsplit", "merge-one-file", "patch-id",
    "sh-i18n", "sh-setup", "stripspace",
    // Widely installed extension.
    "lfs",
]

/// Names `command` defines as shell functions (`f() { …; }`,
/// `function f { …; }`). Invoking one runs a body the per-segment judges
/// never saw as that call.
func shellFunctionNames(in command: String) -> Set<String> {
    var names = Set<String>()
    let words = ShellPipeline.tokenize(command).filter { $0.isNewline == false }
    for (index, token) in words.enumerated() where token.wasQuoted == false {
        let lexeme = token.lexeme
        if lexeme == "function", index + 1 < words.count {
            names.insert(functionName(words[index + 1].lexeme))
            continue
        }
        // `f()`, `f(){`, or `f` followed by `()`.
        if let paren = lexeme.range(of: "()") {
            let name = String(lexeme[..<paren.lowerBound])
            if name.isEmpty == false {
                names.insert(name.split(whereSeparator: { ";&|{".contains($0) }).last.map(String.init) ?? name)
            }
        } else if index + 1 < words.count, words[index + 1].lexeme.hasPrefix("()") {
            names.insert(lexeme)
        }
    }
    names.remove("")
    return names
}

/// True when `command` may read a function's call arguments anywhere:
/// `$@`, `$*`, `$1`…, `${…}` forms of those, indirection (`${!`), or
/// `BASH_ARGV`. Over-approximate on purpose (quoting is ignored).
func readsPositionalParameters(_ command: String) -> Bool {
    if command.contains("BASH_ARGV") || command.contains("${!") { return true }
    let chars = Array(command)
    for (index, char) in chars.enumerated() where char == "$" && index + 1 < chars.count {
        var next = chars[index + 1]
        if next == "{", index + 2 < chars.count { next = chars[index + 2] }
        if next == "@" || next == "*" || next.isNumber { return true }
    }
    return false
}

private func functionName(_ word: String) -> String {
    String(word.prefix { $0 != "(" && $0 != "{" })
}
