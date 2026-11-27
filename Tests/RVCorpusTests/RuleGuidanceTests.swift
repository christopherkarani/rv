import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

/// Every rule's guidance is proven by the engine it describes.
///
/// - A safer command is advice rv must not block, pasted exactly as shown:
///   placeholders are UPPER_CASE words (`aws s3 ls s3://BUCKET`), never
///   `<name>`, which the shell reads as a redirect. It must allow under the
///   pack evaluate with every catalog pack on except `strict_git` (which
///   denies even `--force-with-lease` by design) and under the hook door
///   (`evaluateWithSemantics`) with its own pack on. It only inspects or
///   dry-runs: no write verb, and it never reads or prints a secret value.
///   A rule with no safe variant carries no safer command; every `core.*`
///   rule carries a safer command or `who_acts` instead, pinned in
///   `coreWhoActs`.
/// - A `stop` example must make its own rule fire with its pack on; at
///   critical or high severity that is a deny. A shadowed rule (another
///   rule, often a core pack, always fires first on its commands) instead
///   needs its own pattern to match and the command to be denied; the
///   shadowed set is pinned in `shadowedRules`.
/// - An `allow` example must allow with its pack on, on the pack evaluate
///   and the door, and its rule must not fire on either.
/// - No example pastes a rule's regex alternatives side by side
///   (`gh secret delete remove`): each is a command a person would type.
///
/// Rules no command can reach today carry no examples: placeholder `(?!)`
/// patterns that only a semantic analyzer could emit, and packs with no
/// keywords (quick-reject never lets them scan). A few more cannot fire on
/// the commands they describe because quick-reject drops those commands
/// first (`unreachableRules`). These sets are pinned here so they cannot
/// grow silently; each one is a pack bug to fix, not a guidance gap.
///
/// Run: `tools/gate.sh --quiet RVCorpusTests --filter RuleGuidance`
@Suite("Rule guidance")
struct RuleGuidanceTests {
    static let strictGit = PackID(rawValue: "strict_git")
    static let unreachablePlaceholderCount = 52
    static let keywordlessPackRuleCount = 89

    /// Rules whose own commands never reach them: the command carries none
    /// of the pack's keywords as a word (`terraform destroy
    /// -target=cloudflare_record.www`, `ssh-add -D`), or normalization masks
    /// the quoted `-e` value the pattern needs.
    static let unreachableRules: Set<String> = [
        "dns.cloudflare:cloudflare-terraform-destroy-record",
        "infrastructure.ansible:extra-vars-delete",
        "monitoring.datadog:terraform-datadog-destroy",
        "remote.ssh:ssh-add-delete-all",
    ]

    /// Rules another rule always beats on their own commands (rule to the
    /// rule that reports instead). The command still stops; the deny names
    /// the other rule. Each is an overlap to untangle in its pack.
    static let shadowedRules: [String: String] = [
        "apigateway.aws:apigatewayv2-delete-integration-response": "apigateway.aws:apigatewayv2-delete-integration",
        "apigateway.aws:apigatewayv2-delete-route-response": "apigateway.aws:apigatewayv2-delete-route",
        "apigateway.kong:kong-admin-delete-generic": "apigateway.kong:kong-admin-delete-consumers",
        "apigateway.kong:kong-admin-delete-targets": "apigateway.kong:kong-admin-delete-upstreams",
        "database.mongodb:collection-drop": "database.mongodb:drop-collection",
        "infrastructure.ansible:shell-rm-rf": "core.filesystem:rm-rf-root-home",
        "infrastructure.terraform:plan-destroy": "infrastructure.terraform:destroy",
        "remote.ssh:ssh-remote-git-clean": "core.git:clean-force",
        "remote.ssh:ssh-remote-git-reset-hard": "core.git:reset-hard",
        "remote.ssh:ssh-remote-rm-rf": "core.filesystem:rm-rf-root-home",
        "search.elasticsearch:es-curl-delete-doc": "search.elasticsearch:es-curl-delete-index",
        "search.elasticsearch:es-http-delete-doc": "search.elasticsearch:es-http-delete-index",
        "search.meilisearch:meili-http-delete-document": "search.meilisearch:meili-http-delete-index",
        "search.opensearch:os-curl-delete-doc": "search.opensearch:os-curl-delete-index",
        "search.opensearch:os-http-delete-doc": "search.opensearch:os-http-delete-index",
        "system.disk:dd-wipe": "system.disk:dd-device",
        "system.permissions:chmod-recursive-root": "system.permissions:chmod-777",
    ]

    @Test func everyRule_hasGuidanceUnderItsStableID() throws {
        let documents = try PackRegistry.loadAllDocuments()
        let catalog = RuleGuidanceCatalog(documents: documents)
        var total = 0
        for document in documents {
            let names = document.destructive.map(\.name)
            #expect(Set(names).count == names.count, "duplicate rule name in \(document.id.rawValue)")
            #expect(document.guidance.map(\.ruleID.pattern) == names)
            for name in names {
                total += 1
                #expect(isStableRuleName(name), "rule name \(document.id.rawValue):\(name)")
                let id = RuleID(pack: document.id, pattern: name)
                #expect(catalog[id]?.ruleID == id)
                #expect(RuleID(rawValue: id.rawValue) == id)
            }
        }
        #expect(catalog.count == total)
    }

    @Test func everyReachableRule_hasStopAndAllowExamples() throws {
        let documents = try PackRegistry.loadAllDocuments()
        var placeholders = 0
        var keywordless = 0
        var unreachable = 0
        for document in documents {
            for (rule, guidance) in zip(document.destructive, document.guidance) {
                let id = guidance.ruleID.rawValue
                if document.keywords.isEmpty || rule.pattern == "(?!)" || Self.unreachableRules.contains(id) {
                    if document.keywords.isEmpty {
                        keywordless += 1
                    } else if rule.pattern == "(?!)" {
                        placeholders += 1
                    } else {
                        unreachable += 1
                    }
                    #expect(guidance.examples == RuleExamples(), "\(id) can never fire; its examples could not pass")
                    // A semantic analyzer can still emit a placeholder id
                    // (core.git:git-alias-semantic-unverified), so it may
                    // say who acts, but it has no command to suggest.
                    #expect(guidance.saferCommand == nil, "\(id) can never fire; nothing would show its advice")
                    continue
                }
                #expect(guidance.examples.stop.isEmpty == false, "\(id) has no stop example")
                #expect(guidance.examples.allow.isEmpty == false, "\(id) has no allow example")
            }
        }
        #expect(placeholders == Self.unreachablePlaceholderCount)
        #expect(keywordless == Self.keywordlessPackRuleCount)
        #expect(unreachable == Self.unreachableRules.count)
    }

    @Test func everyExample_evaluatesAsLabelled() throws {
        let harness = try StressHarness.catalog()
        let documents = try PackRegistry.loadAllDocuments()
        var failures = 0
        for document in documents {
            let enabled = uniquePackIDs(dayOnePackIDs + [document.id])
            for (rule, guidance) in zip(document.destructive, document.guidance) {
                let id = guidance.ruleID
                for command in guidance.examples.stop {
                    let result = harness.pin(command, enabled: enabled)
                    let denied = if case .deny = result.decision { true } else { false }
                    let labelled: Bool
                    if let shadowing = Self.shadowedRules[id.rawValue] {
                        labelled = denied
                            && result.outcome.explainRuleID?.rawValue == shadowing
                            && harness.ownPatternMatches(id, command: command)
                    } else {
                        labelled = result.outcome.explainRuleID == id
                            && rule.severity.blocksByDefault == denied
                    }
                    if labelled == false {
                        failures += 1
                        Issue.record("\(id.rawValue) stop example \(command) gave \(describeDecision(result))")
                    }
                }
                for command in guidance.examples.allow {
                    let pin = harness.pin(command, enabled: enabled)
                    let door = harness.door(command, enabled: enabled)
                    if pin.decision != .allow || door.decision != .allow
                        || pin.outcome.explainRuleID == id || door.outcome.explainRuleID == id
                    {
                        failures += 1
                        Issue.record(
                            "\(id.rawValue) allow example \(command) gave pin \(describeDecision(pin)), door \(describeDecision(door))"
                        )
                    }
                }
            }
        }
        #expect(failures == 0)
    }

    /// Redirects, pipes, separators and backgrounding: a safer command is one
    /// plain command, so `<name>` placeholders and `>>` are both out.
    static let shellOperators = CharacterSet(charactersIn: "<>|;&`")

    @Test func everySaferCommand_isAllowedByThePacksAndTheDoor() throws {
        let harness = try StressHarness.catalog()
        let documents = try PackRegistry.loadAllDocuments()
        let catalogMinusStrict = documents.map(\.id).filter { $0 != Self.strictGit }
        var checked = 0
        for document in documents {
            let enabled = uniquePackIDs(dayOnePackIDs + [document.id])
            for guidance in document.guidance {
                guard let safer = guidance.saferCommand else { continue }
                checked += 1
                let id = guidance.ruleID.rawValue
                #expect(safer.isEmpty == false, "\(id) has an empty safer command")
                #expect(guidance.examples.stop.contains(safer) == false, "\(id) suggests its own stop example")
                // The literal text is what a person or agent pastes.
                #expect(
                    safer.rangeOfCharacter(from: Self.shellOperators) == nil && safer.contains("$(") == false,
                    "\(id) suggests \(safer), which the shell would not run as one plain command"
                )
                let packs = harness.pin(safer, enabled: catalogMinusStrict)
                #expect(packs.decision == .allow, "\(id) suggests \(safer), packs give \(describeDecision(packs))")
                let door = harness.door(safer, enabled: enabled)
                #expect(door.decision == .allow, "\(id) suggests \(safer), the door gives \(describeDecision(door))")
            }
        }
        #expect(checked > 0)
    }

    /// A safer command is shown to an agent and may be run as is. It may
    /// list, describe or dry-run; it must never print a secret's value.
    static let secretReaders = [
        #"get-secret-value"#, #"\bkv\s+get\b"#, #"(^|\s)read(\s|$)"#, #"\bdownload\b"#,
        #"\bdocument\s+get\b"#, #"\btoken\s+lookup\b"#, #"\bsecrets\s+get\b"#, #"\bitem\s+get\b"#,
        #"get-parameters?\b"#, #"--with-decryption"#, #"--reveal"#, #"--include-values?\b"#, #"--plain\b"#,
        #"\bhelm\s+get\s+values\b"#, #"\bget\s+secrets?\b.*\s-o\b"#, #"(^|\s)(env|printenv)(\s|$)"#,
    ]
    /// In a secrets.* pack nothing may fetch at all: a `get` other than
    /// `kv metadata get` (versions, not values), a lookup or an export.
    static let secretPackFetchers = [#"(?<!metadata )\bget\b"#, #"\blookup\b"#, #"\bexport\b"#]

    @Test func noSaferCommand_readsASecret() throws {
        let documents = try PackRegistry.loadAllDocuments()
        // The check itself must catch the commands it exists for.
        for leak in ["aws secretsmanager get-secret-value --secret-id x", "vault kv get secret/db", "vault read secret/db",
                     "doppler secrets download", "doppler secrets get DB", "op document get doc", "vault token lookup",
                     "helm get values RELEASE", "kubectl get secret NAME -o yaml",
                     "kubectl get secret x -o jsonpath={.data.password}", "env", "printenv", "doppler run -- env"] {
            #expect(readsSecret(leak, inSecretsPack: false), "\(leak) slipped past the secret check")
        }
        #expect(readsSecret("vault kv metadata get secret/db", inSecretsPack: true) == false)
        for document in documents {
            let secretsPack = document.id.rawValue.hasPrefix("secrets.")
            for guidance in document.guidance {
                guard let safer = guidance.saferCommand else { continue }
                #expect(
                    readsSecret(safer, inSecretsPack: secretsPack) == false,
                    "\(guidance.ruleID.rawValue) suggests \(safer), which can print a secret"
                )
            }
        }
    }

    /// A safer command only lists, describes or dry-runs. These verbs change
    /// something (a file, the work tree, a container, a remote) and are never
    /// advice. `git stash list` and `git stash show` only read.
    static let writeVerbs = [
        #"\bexport\b"#, #"--output\b"#,
        #"(^|\s)(stop|down|rm|cp|mv|tee|kill|delete|remove|destroy|purge|prune|reset|truncate|disable|scale|set)(\s|$)"#,
        #"\btar\s+-[A-Za-z]*c"#, #">"#, #"\bgit\s+stash\b(?!\s+(list|show)\b)"#,
    ]

    @Test func noSaferCommand_writes() throws {
        for write in ["wrangler d1 export db --output b.sql", "docker compose stop", "docker compose down",
                      "tar -cf out.tar ./build", "echo x >> log", "mv ./build /tmp/", "cp a b", "date | tee log",
                      "git reset --hard", "podman system prune -f", "truncate -s 0 f", "systemctl disable x",
                      "kubectl scale deployment web --replicas=0", "gh secret set X", "git stash", "git stash drop"] {
            #expect(writes(write), "\(write) slipped past the write check")
        }
        for read in ["git stash list", "git stash show -p stash@{0}", "git status", "git diff REF -- FILE"] {
            #expect(writes(read) == false, "\(read) only reads")
        }
        for document in try PackRegistry.loadAllDocuments() {
            for guidance in document.guidance {
                guard let safer = guidance.saferCommand else { continue }
                #expect(writes(safer) == false, "\(guidance.ruleID.rawValue) suggests \(safer), which writes")
            }
        }
    }

    static let ownFiles = "you, in your own terminal, after checking what is in it"
    /// The `*-root-home` and sensitive-source rules match `~` as well as
    /// system paths, so their text must be true for both.
    static let ownOrSystem = "you, in your own terminal, for your own files; an admin for system files"
    static let coreWhoActs: [String: String] = [
        "core.git:push-force-long": "you, in your own terminal, after checking no one else pushed",
        "core.git:push-force-short": "you, in your own terminal, after checking no one else pushed",
        "core.git:git-alias-semantic-unverified": "you, after reading the alias with git config --get-regexp alias",
        "core.git:branch-dynamic-token": "you, with the branch name written out",
        "core.filesystem:sed-exec-unverified": "you, after reading the rendered command",
        "core.filesystem:rm-rf-general": ownFiles,
        "core.filesystem:rm-r-f-separate": ownFiles,
        "core.filesystem:rm-recursive-force-long": ownFiles,
        "core.filesystem:unlink-general": ownFiles,
        "core.filesystem:tar-remove-files-general": ownFiles,
        "core.filesystem:truncate-zero-general": "you, in your own terminal",
        "core.filesystem:shred-general": "you, in your own terminal",
        "core.filesystem:dd-overwrite-general": "you, in your own terminal",
        "core.filesystem:mv-dynamic-path": "you, with the paths written out",
        "core.filesystem:redirect-truncate-dynamic-path": "you, with the path written out",
        "core.filesystem:cp-sensitive-then-delete": ownOrSystem,
        "core.filesystem:ln-symlink-sensitive-then-delete": ownOrSystem,
        "core.filesystem:rsync-sensitive-then-delete": ownOrSystem,
        "core.filesystem:rm-rf-root-home": ownOrSystem,
        "core.filesystem:rm-r-f-separate-root-home": ownOrSystem,
        "core.filesystem:rm-recursive-force-root-home": ownOrSystem,
        "core.filesystem:find-delete-root-home": ownOrSystem,
        "core.filesystem:unlink-root-home": ownOrSystem,
        "core.filesystem:truncate-zero-root-home": ownOrSystem,
        "core.filesystem:shred-root-home": ownOrSystem,
        "core.filesystem:tar-remove-files-root-home": ownOrSystem,
        "core.filesystem:dd-overwrite-root-home": ownOrSystem,
        "core.filesystem:mv-sensitive-source-root-home": ownOrSystem,
        "core.filesystem:redirect-truncate-root-home": ownOrSystem,
        "core.filesystem:fork-bomb": "no one: there is no safe form",
    ]

    /// B1 prints this text on a deny line, so it is pinned word for word.
    @Test func coreWhoActs_isPinnedPerRule() throws {
        let catalog = try PackRegistry.loadRuleGuidance()
        var seen: [String: String] = [:]
        for document in try PackRegistry.loadAllDocuments() {
            for guidance in document.guidance {
                guard let who = guidance.whoActs else { continue }
                seen[guidance.ruleID.rawValue] = who
            }
        }
        #expect(seen == Self.coreWhoActs)
        let rmHome = try #require(catalog[RuleID(pack: .coreFilesystem, pattern: "rm-rf-root-home")])
        #expect(rmHome.whoActs?.contains("your own files") == true)
    }

    /// The plan: every stop shows a safer command, or exactly who has to act.
    @Test func everyCoreRule_offersASaferCommandOrSaysWhoActs() throws {
        var checked = 0
        for document in try PackRegistry.loadAllDocuments() where document.id.rawValue.hasPrefix("core.") {
            for guidance in document.guidance {
                checked += 1
                let offers = guidance.saferCommand != nil || guidance.whoActs != nil
                #expect(offers, "\(guidance.ruleID.rawValue) has neither a safer command nor who_acts")
            }
        }
        #expect(checked > 0)
    }

    @Test func noExample_pastesRegexAlternativesSideBySide() throws {
        #expect(pastesAlternatives("gh secret delete remove my-app", pattern: #"gh\s+secret\s+(?:delete|remove)\b"#))
        #expect(pastesAlternatives("gh secret delete MY_SECRET", pattern: #"gh\s+secret\s+(?:delete|remove)\b"#) == false)
        for document in try PackRegistry.loadAllDocuments() {
            for (rule, guidance) in zip(document.destructive, document.guidance) {
                for command in guidance.examples.stop + guidance.examples.allow {
                    #expect(
                        pastesAlternatives(command, pattern: rule.pattern) == false,
                        "\(guidance.ruleID.rawValue) example \(command) pastes the pattern's alternatives"
                    )
                }
            }
        }
    }

    /// `--force-with-lease` is a pack-level allow, but the built-in action
    /// policy sends every remote push to a human. So the force-push rules
    /// offer no safer command (they say who acts), their descriptions no
    /// longer advise it, and both forms of force still stop.
    @Test func forcePush_stillStops_andOffersNoSaferCommand() throws {
        let harness = try StressHarness.catalog()
        let guidance = try PackRegistry.loadRuleGuidance()
        for name in ["push-force-long", "push-force-short"] {
            let rule = try #require(guidance[RuleID(pack: .coreGit, pattern: name)])
            #expect(rule.saferCommand == nil)
            #expect(rule.whoActs?.isEmpty == false)
        }
        let stops: [(String, String)] = [
            ("git push --force origin main", "push-force-long"),
            ("git push --force", "push-force-long"),
            ("git push -f origin main", "push-force-short"),
            ("git push origin main -f", "push-force-short"),
        ]
        for (command, name) in stops {
            guard case .deny(let deny) = harness.pin(command).decision else {
                Issue.record("\(command) must still deny")
                continue
            }
            #expect(deny.ruleID == RuleID(pack: .coreGit, pattern: name))
        }
        #expect(harness.pin("git push --force-with-lease").decision == .allow)
        let git = try PackRegistry.loadDocument(.coreGit)
        for rule in git.destructive where rule.name.hasPrefix("push-force") {
            #expect(rule.reason.contains("force-with-lease") == false)
        }
        guard case .deny(let door) = harness.door("git push --force-with-lease origin feature").decision else {
            Issue.record("the door must still send force-with-lease to a human")
            return
        }
        #expect(door.ruleID.pack == ActionPolicyEngine.Builtin.pack)
    }
}

extension StressHarness {
    func ownPatternMatches(_ id: RuleID, command: String) -> Bool {
        guard let pack = compiled.packs.first(where: { $0.snapshot.id == id.pack }),
              let rule = pack.destructive.first(where: { $0.rule.name == id.pattern })
        else { return false }
        return engine.matches(rule.compiled, in: Normalize.matchingView(of: command).rawValue)
    }
}

private func writes(_ command: String) -> Bool {
    RuleGuidanceTests.writeVerbs.contains { command.range(of: $0, options: .regularExpression) != nil }
}

private func readsSecret(_ command: String, inSecretsPack: Bool) -> Bool {
    let patterns = RuleGuidanceTests.secretReaders + (inSecretsPack ? RuleGuidanceTests.secretPackFetchers : [])
    return patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
}

/// True when two different words from one `(a|b|c)` group of the rule's
/// pattern sit next to each other in the command (`delete remove`).
private func pastesAlternatives(_ command: String, pattern: String) -> Bool {
    guard let group = try? NSRegularExpression(pattern: #"\((?:\?:)?([A-Za-z0-9_-]+(?:\|[A-Za-z0-9_-]+)+)\)"#) else {
        return false
    }
    let range = NSRange(pattern.startIndex..., in: pattern)
    let groups = group.matches(in: pattern, range: range).compactMap { match -> Set<String>? in
        Range(match.range(at: 1), in: pattern).map { Set(pattern[$0].split(separator: "|").map(String.init)) }
    }
    let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
    return zip(words, words.dropFirst()).contains { first, second in
        first != second && groups.contains { $0.contains(first) && $0.contains(second) }
    }
}

private func isStableRuleName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else {
        return false
    }
    let allowed = CharacterSet.lowercaseLetters
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: "-_"))
    return name.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
}
