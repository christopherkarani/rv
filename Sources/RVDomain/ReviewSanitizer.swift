/// Drops raw credentials from review input. Raw shell strings stay supporting
/// evidence and are redacted when they carry secret-shaped text.
public enum ReviewSanitizer: Sendable {
    public static let redactedPlaceholder = "[redacted]"

    public static func sanitize(_ action: ProposedAction) -> ProposedAction {
        switch action {
        case .shell(let shell):
            return .shell(sanitize(shell))
        case .file(let file):
            return .file(sanitize(file))
        case .http(let http):
            return .http(http.redactingQuery())
        }
    }

    public static func sanitize(_ shell: ShellAction) -> ShellAction {
        let fingerprint = ActionFingerprint(
            rawValue: redactCredentials(in: shell.fingerprint.rawValue)
        )
        let scope = ActionScope(
            workingDirectory: shell.scope.workingDirectory.flatMap { directory in
                WorkingDirectory(rawValue: redactCredentials(in: directory.rawValue))
            }
        )
        let supportingCommand = shell.supportingCommand.map { command in
            ShellCommand(rawValue: redactCredentials(in: command.rawValue))
        }
        switch shell {
        case .analyzed(let analyzed):
            return ShellAction.analyzed(
                AnalyzedShell(
                    fingerprint: fingerprint,
                    scope: scope,
                    supportingCommand: supportingCommand,
                    analysis: sanitize(analyzed.analysis)
                )
            )
        case .effectOnly(let effect):
            return ShellAction.effectOnly(
                EffectShell(
                    fingerprint: fingerprint,
                    effects: effect.effects,
                    resources: ActionResources(
                        remoteName: sanitizeField(effect.resources.remoteName),
                        branchName: sanitizeField(effect.resources.branchName),
                        path: sanitizeField(effect.resources.path),
                        filesystemScope: effect.resources.filesystemScope,
                        resourceKind: effect.resources.resourceKind
                    ),
                    scope: scope,
                    supportingCommand: supportingCommand
                )
            )
        }
    }

    public static func sanitize(_ file: FileAction) -> FileAction {
        FileAction(
            fingerprint: ActionFingerprint(
                rawValue: redactCredentials(in: file.fingerprint.rawValue)
            ),
            file: FileToolAction(
                kind: file.file.kind,
                path: FileToolPath(rawValue: sanitizeField(file.file.path.rawValue) ?? file.file.path.rawValue)
            ),
            effects: file.effects,
            resources: ActionResources(
                remoteName: sanitizeField(file.resources.remoteName),
                branchName: sanitizeField(file.resources.branchName),
                path: sanitizeField(file.resources.path),
                filesystemScope: file.resources.filesystemScope,
                resourceKind: file.resources.resourceKind
            ),
            scope: ActionScope(
                workingDirectory: file.scope.workingDirectory.flatMap { directory in
                    WorkingDirectory(rawValue: redactCredentials(in: directory.rawValue))
                }
            )
        )
    }

    public static func sanitize(_ context: ReviewContext) -> ReviewContext {
        ReviewContext(
            repository: RepositoryReviewContext(
                name: sanitizeField(context.repository.name),
                currentBranch: sanitizeField(context.repository.currentBranch)
            ),
            environment: EnvironmentReviewContext(
                labels: context.environment.labels.compactMap { label in
                    guard looksLikeSecretKey(label) == false else { return nil }
                    let cleaned = redactCredentials(in: label)
                    return looksLikeSecretValue(cleaned) ? nil : cleaned
                },
                isCI: context.environment.isCI
            ),
            metadata: sanitize(metadata: context.metadata)
        )
    }

    /// Scrubs credential-shaped text token by token, keeping labels and structure.
    ///
    /// Besides inline `KEY=value` pairs and bare secret prefixes, this catches values
    /// split from their key (`KEY = value`, `--flag value`), single-token `KEY:value`
    /// pairs, bare `user:password@host` userinfo, auth-scheme followers (`Bearer`, and
    /// `Basic`/`Digest`/`Token` after `Authorization`), and obfuscated spellings
    /// (percent-encoding, fullwidth, zero-width scaffolding).
    public static func redactCredentials(in text: String) -> String {
        if looksLikePEM(text) {
            return redactedPlaceholder
        }
        var previous = ""
        var previousPrevious = ""
        var beforePrevious = ""
        return mapWhitespaceTokens(in: text) { token in
            let redacted: String
            if redactFollowOn(
                current: token, previous: previous, previousPrevious: previousPrevious,
                beforePrevious: beforePrevious
            ) {
                redacted = redactedPlaceholder
            } else {
                redacted = redactAssignmentOrPrefix(token)
            }
            beforePrevious = previousPrevious
            previousPrevious = previous
            previous = token
            return redacted
        }
    }

    private static func sanitize(metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata {
            if looksLikeSecretKey(key) { continue }
            if looksLikeSecretValue(value) { continue }
            // Keys scrub too: a pasted token in a label (`ref ghp_…`) must not
            // survive. Two keys scrubbing to one spelling keep the last value.
            result[redactCredentials(in: key)] = redactCredentials(in: value)
        }
        return result
    }

    private static func sanitize(_ analysis: SemanticAction) -> SemanticAction {
        switch analysis {
        case .git(let git):
            return .git(sanitize(git))
        case .filesystem(let filesystem):
            return .filesystem(sanitize(filesystem))
        }
    }

    private static func sanitize(_ action: GitAction) -> GitAction {
        switch action {
        case .createBranch(let name, let startPoint, let force):
            return .createBranch(
                name: sanitizeText(name),
                startPoint: startPoint.map(sanitizeText),
                force: force
            )
        case .switchBranch(let name, let force):
            return .switchBranch(name: sanitizeText(name), force: force)
        case .discardWorktree(let pathspecs, let source):
            return .discardWorktree(
                pathspecs: pathspecs.map(sanitizeText),
                source: source.map(sanitizeText)
            )
        case .restore(let pathspecs, let destination, let source):
            return .restore(
                pathspecs: pathspecs.map(sanitizeText),
                destination: destination,
                source: source.map(sanitizeText)
            )
        case .reset(let mode, let target):
            return .reset(mode: mode, target: target.map(sanitizeText))
        case .clean:
            return action
        case .push(let remote, let refspec, let force):
            return .push(
                remote: remote.map(sanitizeText),
                refspec: refspec.map(sanitizeText),
                force: force
            )
        case .pushUnparsed(let args):
            return .pushUnparsed(args: args.map(sanitizeText))
        case .deleteRemoteRef(let remote, let refspec):
            return .deleteRemoteRef(
                remote: remote.map(sanitizeText),
                refspec: refspec.map(sanitizeText)
            )
        case .deleteBranch(let name, let force):
            return .deleteBranch(name: sanitizeText(name), force: force)
        case .deleteTag(let name, let remote):
            return .deleteTag(name: sanitizeText(name), remote: remote.map(sanitizeText))
        case .stash:
            return action
        case .rebase(let verb, let onto):
            return .rebase(verb: verb, onto: onto.map(sanitizeText))
        }
    }

    private static func sanitize(_ action: FilesystemAction) -> FilesystemAction {
        switch action {
        case .delete(let targets, let recursive, let force):
            return .delete(targets: targets.map(sanitize), recursive: recursive, force: force)
        case .move(let sources, let destination):
            return .move(sources: sources.map(sanitize), destination: sanitize(destination))
        case .overwrite(let targets):
            return .overwrite(targets: targets.map(sanitize))
        case .chmod(let targets, let mode, let recursive):
            return .chmod(
                targets: targets.map(sanitize),
                mode: mode.map(sanitizeText),
                recursive: recursive
            )
        case .create(let targets):
            return .create(targets: targets.map(sanitize))
        case .read(let targets):
            return .read(targets: targets.map(sanitize))
        }
    }

    private static func sanitize(_ target: FilesystemTarget) -> FilesystemTarget {
        FilesystemTarget(
            apparent: sanitizeText(target.apparent),
            canonical: sanitizeText(target.canonical),
            scope: target.scope,
            kind: target.kind,
            followedSymlink: target.followedSymlink,
            resolution: target.resolution
        )
    }

    private static func sanitizeField(_ value: String?) -> String? {
        value.map(sanitizeText)
    }

    private static func sanitizeText(_ value: String) -> String {
        if looksLikeSecretValue(value) {
            return redactedPlaceholder
        }
        return redactCredentials(in: value)
    }

    /// Decides whether `current` is a secret value owned by a neighboring token.
    ///
    /// `previous`/`previousPrevious`/`beforePrevious` are the original preceding
    /// tokens. Bearer owns whatever follows it; other auth schemes only with
    /// `Authorization` context;
    /// spaced separators and exact `--flag` names own a following non-flag token.
    /// Scheme labels are never eaten: the scheme rules own the token after them.
    private static func redactFollowOn(
        current: String, previous: String, previousPrevious: String, beforePrevious: String
    ) -> Bool {
        if previous.isEmpty { return false }
        let foldedPrevious = detectionFold(previous)
        let previousLastWord = lastWord(foldedPrevious)
        if previousLastWord == "bearer" { return true }
        if authSchemeWords.contains(previousLastWord) {
            if detectionFold(previousPrevious).lowercased().contains("authorization") {
                return true
            }
            // Spaced header spelling: `Authorization : Basic <credential>`.
            if isAssignmentSeparator(detectionFold(previousPrevious)),
                detectionFold(beforePrevious).lowercased().contains("authorization")
            {
                return true
            }
        }
        if schemeWords.contains(firstWord(detectionFold(current))) { return false }
        if current.hasPrefix("-") { return false }
        if isAssignmentSeparator(foldedPrevious) {
            return looksLikeSecretKey(previousPrevious)
        }
        if hasGluedSeparatorValue(current) {
            return looksLikeSecretKey(previous)
        }
        if let key = strippingTrailingAssignment(foldedPrevious) {
            return looksLikeSecretValue(previous) == false && looksLikeSecretKey(key)
        }
        return isSecretFlag(foldedPrevious)
    }

    private static func redactAssignmentOrPrefix(_ token: String) -> String {
        if let direct = redactTokenStructure(token) {
            return direct
        }
        let folded = detectionFold(token)
        if folded != token, redactTokenStructure(folded) != nil {
            return redactedPlaceholder
        }
        if token.contains("%"), percentDecodedTriggers(token) {
            return redactedPlaceholder
        }
        return token
    }

    /// Single-token structural rules over one spelling. Returns nil on passthrough.
    private static func redactTokenStructure(_ token: String) -> String? {
        if let equals = token.firstIndex(of: "=") {
            let key = String(token[..<equals])
            let value = String(token[token.index(after: equals)...])
            // Keep a non-secret key when only the value is credential-shaped.
            // If the key itself carries a prefix/PAT, drop the whole token.
            if looksLikeSecretValue(key) == false,
                looksLikeSecretKey(key) || looksLikeSecretValue(value)
            {
                return "\(key)=\(redactedPlaceholder)"
            }
        }
        if let colon = token.firstIndex(of: ":") {
            let key = String(token[..<colon])
            let value = String(token[token.index(after: colon)...])
            // Mirror the `=` rule for header/YAML-style pairs, but never eat a bare
            // scheme label: `Authorization: Bearer` keeps both words. Unlike `=`, a
            // secret-shaped tail with a non-secret head (URLs) drops the whole token.
            if value.isEmpty == false,
                looksLikeSecretValue(key) == false,
                schemeWords.contains(firstWord(detectionFold(value))) == false
            {
                if looksLikeSecretKey(key) {
                    return "\(key):\(redactedPlaceholder)"
                }
                if looksLikeSecretValue(value) {
                    return redactedPlaceholder
                }
            }
        }
        if containsSecretPrefix(token) || looksLikeUserinfo(token) {
            return redactedPlaceholder
        }
        return nil
    }

    /// Bare `user:password@host` userinfo without a scheme. Real URLs keep their
    /// structure through `redactURL`; only the credential-shaped remainder lands here.
    private static func looksLikeUserinfo(_ token: String) -> Bool {
        guard let at = token.lastIndex(of: "@") else { return false }
        var before = token[..<at]
        if let scheme = before.range(of: "://") {
            before = before[scheme.upperBound...]
        }
        guard let colon = before.firstIndex(of: ":") else { return false }
        let user = before[..<colon]
        let password = before[before.index(after: colon)...]
        return user.isEmpty == false
            && password.isEmpty == false
            && user.contains("/") == false
            && password.contains("/") == false
    }

    /// Reports whether percent-decoding (up to three rounds for nested encoding)
    /// reveals a spelling the token rules would redact.
    private static func percentDecodedTriggers(_ token: String) -> Bool {
        var current = token
        for _ in 0..<3 {
            let decoded = percentDecoding(current)
            if decoded == current { return false }
            current = decoded
            if redactTokenStructure(current) != nil { return true }
            for piece in current.split(whereSeparator: \.isWhitespace) {
                if redactTokenStructure(String(piece)) != nil { return true }
            }
        }
        return false
    }

    /// Decodes `%XX` triplets to ASCII, leaving malformed or non-ASCII triplets
    /// literal. ASCII suffices: every secret marker this detects is ASCII.
    private static func percentDecoding(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var decoded = ""
        decoded.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "%",
                let byte = percentTriplet(text, at: index),
                byte < 0x80
            {
                decoded.unicodeScalars.append(Unicode.Scalar(byte))
                text.formIndex(&index, offsetBy: 3)
            } else {
                decoded.append(text[index])
                text.formIndex(after: &index)
            }
        }
        return decoded
    }

    /// Reads the `%XX` triplet at `index`, or nil when the triplet is incomplete
    /// or either trailing character is not ASCII hexadecimal.
    private static func percentTriplet(_ text: String, at index: String.Index) -> UInt8? {
        guard let second = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
            second < text.endIndex,
            let third = text.index(second, offsetBy: 1, limitedBy: text.endIndex),
            third < text.endIndex,
            let high = hexNibble(text[second]),
            let low = hexNibble(text[third])
        else { return nil }
        return high << 4 | low
    }

    /// Parses one ASCII hexadecimal digit.
    private static func hexNibble(_ character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return ascii - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return ascii - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return ascii - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }

    /// Canonical spelling for detection: drops format scaffolding (zero-width
    /// characters, controls) and separator spaces that survive inside whole-field
    /// values, and folds fullwidth ASCII and Unicode dashes to their ASCII
    /// counterparts. Case is preserved; callers fold case where the rule needs it.
    private static func detectionFold(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 < 0x21 || $0 > 0x7E }) else { return text }
        var folded = ""
        folded.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .format || category == .control { continue }
            let value = scalar.value
            if value == 0x3000 || value == 0x205F {
                continue
            } else if (0xFF01...0xFF5E).contains(value), let ascii = Unicode.Scalar(value - 0xFEE0) {
                folded.unicodeScalars.append(ascii)
            } else if (0x2010...0x2015).contains(value) || value == 0x2212 {
                folded.append("-")
            } else {
                folded.unicodeScalars.append(scalar)
            }
        }
        return folded
    }

    /// Standalone separators between a secret key and its value.
    private static func isAssignmentSeparator(_ token: String) -> Bool {
        token == "=" || token == "==" || token == ":" || token == ":=" || token == "=>"
    }

    /// Reports whether the token starts with `=`/`:` separators followed by a value
    /// (`=hunter2`), as opposed to a bare separator (`=`, `:=`) which survives.
    private static func hasGluedSeparatorValue(_ token: String) -> Bool {
        let stripped = token.drop(while: { $0 == "=" || $0 == ":" })
        return stripped.startIndex != token.startIndex && stripped.isEmpty == false
    }

    /// Strips trailing `=`/`:` runs (`KEY=`, `KEY:=`), returning the key, or nil
    /// when nothing was stripped or nothing remains.
    private static func strippingTrailingAssignment(_ token: String) -> String? {
        var end = token.endIndex
        while end > token.startIndex {
            let before = token.index(before: end)
            if token[before] == "=" || token[before] == ":" {
                end = before
            } else {
                break
            }
        }
        guard end != token.endIndex, end != token.startIndex else { return nil }
        return String(token[..<end])
    }

    /// Reports whether the token is a `--flag` whose name exactly matches a known
    /// secret key (allowing a trailing plural `s`), so `--token` owns its value
    /// while `--tokenize` does not.
    private static func isSecretFlag(_ token: String) -> Bool {
        let stripped = token.drop(while: { $0 == "-" })
        guard stripped.count < token.count, stripped.isEmpty == false else { return false }
        guard stripped.contains("=") == false else { return false }
        let name = String(stripped.map { ($0 == "." || $0 == "-") ? "_" : $0 }).lowercased()
        if isSecretFlagName(name) { return true }
        guard name.hasSuffix("s") else { return false }
        return isSecretFlagName(String(name.dropLast()))
    }

    /// Exact or `_`-suffixed secret-flag name match.
    private static func isSecretFlagName(_ name: String) -> Bool {
        if secretFlagNames.contains(name) { return true }
        return secretFlagSuffixes.contains { name.hasSuffix($0) }
    }

    /// First alphanumeric word, lowercased, for scheme-label checks.
    private static func firstWord(_ token: String) -> String {
        alphanumericWords(token).first ?? ""
    }

    /// Last alphanumeric word, lowercased, so `Bearer:` and `Authorization:Bearer`
    /// still read as the bearer scheme.
    private static func lastWord(_ token: String) -> String {
        alphanumericWords(token).last ?? ""
    }

    /// Lowercased alphanumeric words of one token.
    private static func alphanumericWords(_ token: String) -> [String] {
        token.lowercased().split { $0.isLetter == false && $0.isNumber == false }.map(String.init)
    }

    private static func mapWhitespaceTokens(in text: String, transform: (String) -> String) -> String {
        // ASCII fast path: for ASCII-only text, `isWhitespace` agrees with
        // the six ASCII whitespace bytes on every character, so byte runs
        // segment identically to the Unicode walk below without per-scalar
        // property queries. Any non-ASCII byte falls back to the slow path.
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return mapASCIITokens(in: text, transform: transform)
        }
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var token = ""
        for character in text {
            if character.isWhitespace {
                if token.isEmpty == false {
                    output.append(transform(token))
                    token = ""
                }
                output.append(character)
            } else {
                token.append(character)
            }
        }
        if token.isEmpty == false {
            output.append(transform(token))
        }
        return output
    }

    /// Byte-run tokenizer for ASCII-only text. Precondition: every byte of
    /// `text` is below 0x80, so each byte is one character and ASCII
    /// whitespace (9, 10, 11, 12, 13, 32) is exactly `isWhitespace`.
    private static func mapASCIITokens(in text: String, transform: (String) -> String) -> String {
        let bytes = Array(text.utf8)
        var output = ""
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if isASCIIWhitespace(bytes[index]) {
                let runStart = index
                repeat { index += 1 } while index < bytes.count && isASCIIWhitespace(bytes[index])
                output.append(contentsOf: String(decoding: bytes[runStart..<index], as: UTF8.self))
            } else {
                let tokenStart = index
                repeat { index += 1 } while index < bytes.count && isASCIIWhitespace(bytes[index]) == false
                output.append(transform(String(decoding: bytes[tokenStart..<index], as: UTF8.self)))
            }
        }
        return output
    }

    /// The six ASCII whitespace bytes: exactly `Character.isWhitespace`
    /// for ASCII characters (tab, LF, VT, FF, CR, space).
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 11 || byte == 12 || byte == 13 || byte == 32
    }

    private static func looksLikeSecretKey(_ raw: String) -> Bool {
        let folded = String(detectionFold(raw).lowercased().map { character -> Character in
            if character == "-" || character == "." {
                return "_"
            }
            return character
        })
        if folded.hasSuffix("_key") { return true }
        // Bare `key` only: a `key` fragment would also match `monkey`.
        if folded == "key" { return true }
        for fragment in secretKeyFragments where folded.contains(fragment) {
            return true
        }
        return false
    }

    private static func looksLikeSecretValue(_ value: String) -> Bool {
        looksLikePEM(value) || containsSecretPrefix(value)
    }

    private static func looksLikePEM(_ text: String) -> Bool {
        if text.contains("PRIVATE KEY") || text.contains("BEGIN OPENSSH") {
            return true
        }
        // Lowercase armor still carries key material, but bare prose mentioning a
        // "private key" must survive, so the folded match requires armor framing.
        let folded = text.lowercased()
        return folded.contains("-----begin")
            && (folded.contains("private key") || folded.contains("openssh"))
    }

    /// Secret prefixes may sit after any punctuation boundary rather than at the
    /// whitespace-token start (URL-embedded PATs, `FOO=ghp_…`, quoted tokens).
    /// Matches anchor at a boundary: the segment start plus restarts after `-`/`_`,
    /// so `my-ghp_…` matches while `task-list` never matches `sk-`.
    private static func containsSecretPrefix(_ token: String) -> Bool {
        let folded = detectionFold(token)
        return folded.split(whereSeparator: isSecretBoundary).contains { segment in
            secretStarts(in: segment).contains { candidate in
                hasSecretPrefix(candidate)
            }
        }
    }

    /// Prefix match at one candidate start without copying the suffix:
    /// the case-sensitive check runs on bytes, and the folded check
    /// lowercases only the prefix window. Lowercasing the whole suffix per
    /// restart would rescan dash-dense tokens quadratically.
    private static func hasSecretPrefix(_ candidate: Substring) -> Bool {
        for prefix in caseSensitiveSecretPrefixes where candidate.utf8.starts(with: prefix.utf8) {
            return true
        }
        for prefix in caseFoldedSecretPrefixes {
            if candidate.prefix(prefix.count).lowercased() == prefix {
                return true
            }
        }
        return false
    }

    /// Boundary between a secret prefix and its surroundings: anything that cannot
    /// appear inside the known prefix shapes. `-` and `_` are kept so the prefixes
    /// themselves survive the split.
    private static func isSecretBoundary(_ character: Character) -> Bool {
        character.isLetter == false && character.isNumber == false && character != "-"
            && character != "_"
    }

    /// Candidate prefix-match starts within one segment: the segment start plus
    /// every restart after `-`/`_`.
    private static func secretStarts(in segment: Substring) -> [Substring] {
        var starts = [segment]
        var index = segment.startIndex
        while index < segment.endIndex {
            if segment[index] == "-" || segment[index] == "_" {
                let next = segment.index(after: index)
                if next < segment.endIndex {
                    starts.append(segment[next...])
                }
            }
            segment.formIndex(after: &index)
        }
        return starts
    }

    private static let secretKeyFragments = [
        "password",
        "passwd",
        "pass",
        "pwd",
        "secret",
        "token",
        "authorization",
        "auth",
        "credential",
        "api_key",
        "apikey",
        "private_key",
        "privatekey",
        "access_key",
        "accesskey",
    ]

    /// Short prefix shapes that stay case-sensitive: `SK-` also matches product
    /// codes, while the known secret spelling is lowercase.
    private static let caseSensitiveSecretPrefixes = [
        "sk-",
    ]

    /// Distinctive prefixes matched case-insensitively: the GitHub
    /// OAuth/user/server/refresh siblings of `ghp_`, plus GitLab (`glpat-`),
    /// Slack (`xoxb/p/a/s-`), and GCP (`aiza`, the `AIza` head).
    private static let caseFoldedSecretPrefixes = [
        "ghp_",
        "github_pat_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "glpat-",
        "xoxb-",
        "xoxp-",
        "xoxa-",
        "xoxs-",
        "akia",
        "aiza",
    ]

    /// Exact secret `--flag` names: every key fragment plus bare `key`, which is
    /// only secret-selective in flag position.
    private static let secretFlagNames: Set<String> = Set(secretKeyFragments).union(["key"])

    /// `_`-suffixed secret-flag name endings (`--client-secret`, `--openai-key`).
    private static let secretFlagSuffixes: [String] = secretKeyFragments.map { "_\($0)" } + ["_key"]

    /// Auth-scheme labels that own the token after them instead of being eaten.
    private static let schemeWords: Set<String> = ["bearer", "basic", "digest", "token"]

    /// Non-bearer schemes, which only own a follower with `Authorization` context.
    private static let authSchemeWords: Set<String> = ["basic", "digest", "token"]
}
