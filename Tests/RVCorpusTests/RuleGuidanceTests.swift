import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

/// Every rule's guidance is proven by the engine it describes.
///
/// - A safer command is advice rv must not block. It must allow under the
///   pack evaluate with every catalog pack on except `strict_git` (which
///   denies even `--force-with-lease` by design) and under the hook door
///   (`evaluateWithSemantics`) with its own pack on. A rule with no safe
///   variant carries no safer command.
/// - A `stop` example must make its own rule fire with its pack on; at
///   critical or high severity that is a deny. A shadowed rule (another
///   rule, often a core pack, always fires first on its commands) instead
///   needs its own pattern to match and the command to be denied; the
///   shadowed set is pinned in `shadowedRules`.
/// - An `allow` example must allow with its pack on, and its rule must not
///   fire, on the pack evaluate or the door.
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
                    if pin.decision != .allow || pin.outcome.explainRuleID == id || door.outcome.explainRuleID == id {
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
                let packs = harness.pin(safer, enabled: catalogMinusStrict)
                #expect(packs.decision == .allow, "\(id) suggests \(safer), packs give \(describeDecision(packs))")
                let door = harness.door(safer, enabled: enabled)
                #expect(door.decision == .allow, "\(id) suggests \(safer), the door gives \(describeDecision(door))")
            }
        }
        #expect(checked > 0)
    }

    /// The force-push advice in core.git's explanation (`--force-with-lease`)
    /// is a pack-level allow, but the built-in action policy sends every
    /// remote push to a human. So the force-push rules offer no safer
    /// command, and both forms of force still stop.
    @Test func forcePush_stillStops_andOffersNoSaferCommand() throws {
        let harness = try StressHarness.catalog()
        let guidance = try PackRegistry.loadRuleGuidance()
        for name in ["push-force-long", "push-force-short"] {
            let rule = try #require(guidance[RuleID(pack: .coreGit, pattern: name)])
            #expect(rule.saferCommand == nil)
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

private func isStableRuleName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else {
        return false
    }
    let allowed = CharacterSet.lowercaseLetters
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: "-_"))
    return name.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
}
