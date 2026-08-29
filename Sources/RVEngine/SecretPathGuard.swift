import RVDomain

enum SecretPathGuard {
    static let candidateCap = 64

    static func firstHit(
        in matchingView: MatchingView,
        catalog: SecretPathCatalog
    ) -> RuleMatch? {
        guard !catalog.rules.isEmpty else { return nil }
        let view = matchingView.rawValue
        let segments = splitSegments(view)
        if segments.count > 1 {
            for segment in segments {
                if let hit = firstHit(inHaystack: segment, catalog: catalog, searchText: view) {
                    return hit
                }
            }
        }
        return firstHit(inHaystack: view, catalog: catalog, searchText: view)
    }

    private static func firstHit(
        inHaystack haystack: String,
        catalog: SecretPathCatalog,
        searchText: String
    ) -> RuleMatch? {
        for candidate in candidates(in: haystack) {
            if let rule = catalog.firstMatch(of: candidate) {
                let ruleID = RuleID(pack: .coreSecrets, pattern: rule.pattern)
                return RuleMatch(
                    ruleID: ruleID,
                    packID: .coreSecrets,
                    patternName: rule.pattern,
                    severity: .high,
                    reason: rule.reason,
                    regex: nil,
                    matchedText: candidate,
                    searchText: searchText
                )
            }
        }
        return nil
    }

    private static func candidates(in haystack: String) -> [String] {
        let tokens = tokenizeCommand(haystack)
        guard let headToken = tokens.first else { return [] }
        switch headKind(basename(headToken.decoded)) {
        case .nonPath:
            return []
        case .grep:
            return grepCandidates(tokens.dropFirst())
        case .find:
            return findCandidates(tokens.dropFirst())
        case .other:
            return otherCandidates(tokens.dropFirst())
        }
    }
}

private enum HeadKind {
    case nonPath
    case grep
    case find
    case other
}

private func headKind(_ argv0: String) -> HeadKind {
    switch argv0.lowercased() {
    case "echo", "printf":
        return .nonPath
    case "grep", "rg":
        return .grep
    case "find":
        return .find
    default:
        return .other
    }
}

private enum OperandFlag {
    case regexp(attached: String?)
    case file(attached: String?)
    case files
    case equalsValue(String)
    case ignore
}

private func parseFlag(_ decoded: String) -> OperandFlag? {
    guard decoded.hasPrefix("-"), decoded != "--" else { return nil }
    if decoded.hasPrefix("--") {
        let body = decoded.dropFirst(2)
        let name: Substring
        let attached: String?
        if let eq = body.firstIndex(of: "=") {
            name = body[..<eq]
            attached = String(body[body.index(after: eq)...])
        } else {
            name = body
            attached = nil
        }
        switch name {
        case "regexp":
            return .regexp(attached: attached)
        case "file":
            return .file(attached: attached)
        case "files":
            return .files
        default:
            if let attached {
                return .equalsValue(attached)
            }
            return .ignore
        }
    }
    if let eq = decoded.firstIndex(of: "="), eq > decoded.startIndex {
        return .equalsValue(String(decoded[decoded.index(after: eq)...]))
    }
    let letters = decoded.dropFirst()
    guard letters.allSatisfy({ $0.isASCII && $0.isLetter }) else {
        return .ignore
    }
    if letters.contains("f") {
        return .file(attached: nil)
    }
    if letters.contains("e") {
        return .regexp(attached: nil)
    }
    return .ignore
}

private func operandCandidate(_ decoded: String) -> String? {
    if decoded == "--" { return nil }
    if decoded.hasPrefix("-") {
        guard let eq = decoded.firstIndex(of: "="), eq > decoded.startIndex else {
            return nil
        }
        return String(decoded[decoded.index(after: eq)...])
    }
    if let eq = decoded.firstIndex(of: "="), eq > decoded.startIndex {
        return String(decoded[decoded.index(after: eq)...])
    }
    return decoded
}

private func grepCandidates<C: Collection>(_ tokens: C) -> [String] where C.Element == CommandToken {
    var collected: [String] = []
    var skipFirstPositional = true
    var expectRegexp = false
    var expectFile = false
    var afterDoubleDash = false

    func add(_ value: String) {
        guard collected.count < SecretPathGuard.candidateCap else { return }
        guard !value.isEmpty else { return }
        collected.append(value)
    }

    for token in tokens {
        if collected.count >= SecretPathGuard.candidateCap { break }
        let decoded = token.decoded
        if expectRegexp {
            expectRegexp = false
            continue
        }
        if expectFile {
            expectFile = false
            add(decoded)
            continue
        }
        if afterDoubleDash {
            if skipFirstPositional {
                skipFirstPositional = false
                continue
            }
            add(decoded)
            continue
        }
        if decoded == "--" {
            afterDoubleDash = true
            continue
        }
        if let flag = parseFlag(decoded) {
            switch flag {
            case .regexp(let attached):
                skipFirstPositional = false
                if attached == nil {
                    expectRegexp = true
                }
            case .file(let attached):
                skipFirstPositional = false
                if let attached {
                    add(attached)
                } else {
                    expectFile = true
                }
            case .files:
                skipFirstPositional = false
            case .equalsValue(let value):
                add(value)
            case .ignore:
                break
            }
            continue
        }
        if skipFirstPositional {
            skipFirstPositional = false
            continue
        }
        add(decoded)
    }
    return collected
}

private func findCandidates<C: Collection>(_ tokens: C) -> [String] where C.Element == CommandToken {
    var collected: [String] = []
    var beforePredicate = true
    var skipValue = false

    func add(_ value: String) {
        guard collected.count < SecretPathGuard.candidateCap else { return }
        guard !value.isEmpty else { return }
        collected.append(value)
    }

    for token in tokens {
        if collected.count >= SecretPathGuard.candidateCap { break }
        let decoded = token.decoded
        if skipValue {
            skipValue = false
            continue
        }
        if decoded.hasPrefix("-") || decoded == "(" || decoded == "!" || decoded == ";" {
            beforePredicate = false
            if decoded == "-name" || decoded == "-iname" || decoded == "-path" {
                skipValue = true
            }
            continue
        }
        if beforePredicate, let candidate = operandCandidate(decoded) {
            add(candidate)
        }
    }
    return collected
}

private func otherCandidates<C: Collection>(_ tokens: C) -> [String] where C.Element == CommandToken {
    var collected: [String] = []
    for token in tokens {
        if collected.count >= SecretPathGuard.candidateCap { break }
        guard let candidate = operandCandidate(token.decoded), !candidate.isEmpty else {
            continue
        }
        collected.append(candidate)
    }
    return collected
}

