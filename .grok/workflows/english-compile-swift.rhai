// english-compile-swift — Swift TDD runner for the English-compile program.
// NOT Zig implementor. Sibling of orchestrate-implement-swift.
//
// Bakes W1 (default) / W2 / W3 units from
// planning/2026-09-04-english-compile-implementable-program.md
// so a decomposer cannot invent Host Ask, MCP, or hook Auto-review.
//
// Args:
//   wave (string) — W1 | W2 | W3 (default W1)
//   mode (string) — lite | standard | full (default full for W1/W3, standard for W2)
//   repo (string) — default cwd repo
//   max_fix (int) — override
//
// Launch: workflow name=english-compile-swift agent_budget=256 args={ wave: "W1" }

let meta = #{
    name: "english-compile-swift",
    description: "Swift TDD waves for rv English-compile: typed gitPush rules, then pin, then English draft CLI — not Zig implementor",
    when_to_use: "Implement planning/2026-09-04-english-compile W1/W2/W3 with Swift dual review and tools/gate.sh",
    phases: [
        #{ title: "Setup", detail: "run dir, dirty policy, gate baseline" },
        #{ title: "Units", detail: "baked wave units, TDD, dual review, fix" },
        #{ title: "Integrate", detail: "combined-diff Behavior + Safety" },
        #{ title: "Oracle", detail: "tools/gate.sh + rv policy show" },
        #{ title: "Report", detail: "scratch markdown" },
    ],
};

let setup_schema = #{
    "type": "object",
    "required": ["ok", "run_dir", "baseline_cmd", "baseline_summary", "dirty_policy", "error"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "run_dir": #{ "type": "string" },
        "baseline_cmd": #{ "type": "string" },
        "baseline_summary": #{ "type": "string" },
        "dirty_policy": #{ "type": "string" },
        "error": #{ "type": "string" },
    },
};

let implement_schema = #{
    "type": "object",
    "required": ["unit_id", "status", "summary", "files_changed", "tests_touched", "handoff_path"],
    "properties": #{
        "unit_id": #{ "type": "string" },
        "status": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "files_changed": #{ "type": "array", "maxItems": 24, "items": #{ "type": "string" } },
        "tests_touched": #{ "type": "boolean" },
        "handoff_path": #{ "type": "string" },
        "error": #{ "type": "string" },
    },
};

let review_schema = #{
    "type": "object",
    "required": ["lane", "clean", "verdict", "summary", "blockers"],
    "properties": #{
        "lane": #{ "type": "string" },
        "clean": #{ "type": "boolean" },
        "verdict": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "blockers": #{
            "type": "array",
            "maxItems": 10,
            "items": #{
                "type": "object",
                "required": ["title", "file", "suggestion"],
                "properties": #{
                    "title": #{ "type": "string" },
                    "file": #{ "type": "string" },
                    "suggestion": #{ "type": "string" },
                    "severity": #{ "type": "string" },
                },
            },
        },
    },
};

let oracle_schema = #{
    "type": "object",
    "required": ["ok", "summary", "commands"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "summary": #{ "type": "string" },
        "commands": #{ "type": "array", "maxItems": 12, "items": #{ "type": "string" } },
        "error": #{ "type": "string" },
    },
};

fn trimmed(s) {
    if type_of(s) == "string" {
        s.trim();
        s
    } else {
        ""
    }
}

fn as_int(v, fallback) {
    if v == () {
        fallback
    } else if type_of(v) == "i64" || type_of(v) == "int" || type_of(v) == "f64" {
        v
    } else {
        fallback
    }
}

fn clamp_int(v, lo, hi) {
    let x = v;
    if x < lo { x = lo; }
    if x > hi { x = hi; }
    x
}

fn join_paths(arr) {
    if arr == () || type_of(arr) != "array" || arr.len() == 0 {
        return "(none)";
    }
    let s = "";
    for p in arr {
        if s != "" { s += ", "; }
        s += trimmed(p.to_string());
    }
    s
}

fn join_acceptance(arr) {
    if arr == () || type_of(arr) != "array" || arr.len() == 0 {
        return "(none listed)";
    }
    let s = "";
    for a in arr {
        if s != "" { s += "\n- "; } else { s += "- "; }
        s += trimmed(a.to_string());
    }
    s
}

fn unit_state(results, id) {
    let st = "missing";
    for r in results {
        if r.id == id { st = r.status; }
    }
    st
}

fn deps_ready(u, results) {
    if u.depends_on == () || type_of(u.depends_on) != "array" || u.depends_on.len() == 0 {
        return true;
    }
    let ok = true;
    for d in u.depends_on {
        let did = trimmed(d.to_string());
        if did == "" { continue; }
        if unit_state(results, did) != "passed" {
            ok = false;
        }
    }
    ok
}

fn swift_pack_block() {
    let s = "";
    s += "REQUIRED READS (read_file before coding or judging):\n";
    s += "1. Repo AGENTS.md (wins)\n";
    s += "2. planning/2026-09-04-english-compile-implementable-program.md (this wave's unit)\n";
    s += "3. .grok/skills/swift-hexagonal-spm/SKILL.md\n";
    s += "4. docs/dev/SWIFT.md\n";
    s += "5. ~/.grok/skills/tdd/SKILL.md\n";
    s += "6. ~/.grok/skills/orchestrate-implement/references/handoff-schema.md\n";
    s += "Do NOT load Zig skills or run Zig implementor.\n";
    s += "SEAM OVERRIDE: unit seams are pre-confirmed. Do not re-grill.\n";
    s += "Gate: tools/gate.sh via tools/swift-6.3.3. Warm .build. No swift package clean.\n";
    s += "Do NOT wrap tools/swift-6.3.3 in HOME=$(mktemp -d). Darwin pin is $HOME/Library/Developer/Toolchains.\n";
    s += "CLI proof: build with real HOME, then run the binary under TMP HOME. Full RVCLITests is not wave proof.\n";
    s += "--filter is substring: use unique names (EnglishCompilerTests, FakeEnglishCompilerTests, PolicyDraftCommand, ActionPolicyEngineTests). Never --filter ActionPolicyEngine or --filter TypedRule or --filter EnglishCompiler alone.\n";
    s
}

fn swift_defect_block() {
    let s = "";
    s += "HARD FAIL: class in Domain/Engine/Policy; try! / IUO; Date/FileManager/ProcessInfo in pure evaluate; matching supportingCommand as primary; ReviewBind on hook; RV_BYPASS; English saved as matcher; scratch/english-review import; pack Decision.ask; Foundation Models in RVDomain/RVEngine.\n";
    s
}

fn reject_block() {
    let s = "";
    s += "GLOBAL REJECT: Zig implementor; live Auto-review; Host Ask 264; companion app; ProposedAction.mcp; npm process analyzer; Wax policy store; live HOME tests; command text in os_log.\n";
    s
}

// ---------- args ----------
let wave = "W1";
let run_mode = "";
let repo = "/Users/chriskarani/CodingProjects/rv";
let max_fix = -1;

if args != () {
    if args.wave != () { wave = trimmed(args.wave.to_string()); }
    if args.mode != () { run_mode = trimmed(args.mode.to_string()); }
    if args.repo != () { repo = trimmed(args.repo.to_string()); }
    if args.max_fix != () { max_fix = as_int(args.max_fix, -1); }
}

if wave != "W1" && wave != "W2" && wave != "W3" {
    wave = "W1";
}

if run_mode == "" {
    if wave == "W2" {
        run_mode = "standard";
    } else {
        run_mode = "full";
    }
}
if run_mode != "lite" && run_mode != "standard" && run_mode != "full" {
    run_mode = "full";
}

if max_fix < 0 {
    if run_mode == "full" {
        max_fix = 6;
    } else if run_mode == "lite" {
        max_fix = 2;
    } else {
        max_fix = 3;
    }
}
max_fix = clamp_int(max_fix, 0, 8);

let plan_path = repo + "/planning/2026-09-04-english-compile-implementable-program.md";

let units = [];
if wave == "W1" {
    units = [
        #{ id: "w1-law", title: "Land english-compile product law", goal: "Overlay doc + 02 pointer", acceptance: ["english-compile.md exists with three products and compile pipeline", "02.md points at it without changing § Order", "AGENTS.md CONTEXT.md MODULES.md one-line pointers"], depends_on: [], code_paths: ["docs/architecture/english-compile.md", "docs/architecture/02.md", "docs/architecture/MODULES.md", "AGENTS.md", "CONTEXT.md"], test_paths: [], fat: false, composition: "AGENTS.md greps english-compile.md", gate: "rg english-compile.md docs/architecture/02.md AGENTS.md" },
        #{ id: "w1-predicate", title: "PolicyPredicate closed AST", goal: "gitPush force+branch only", acceptance: ["PolicyPredicate.gitPush(force:branch:) in RVDomain", "no npm/mcp/status cases", "Codable round-trip test"], depends_on: ["w1-law"], code_paths: ["Sources/RVDomain/PolicyPredicate.swift"], test_paths: ["Tests/RVDomainTests/PolicyPredicateTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter PolicyPredicate" },
        #{ id: "w1-rule", title: "TypedRule value", goal: "predicate + verdict + origin", acceptance: ["TypedRule id predicate verdict origin", "allow/ask/deny + builtin/machine/repo", "Codable tests"], depends_on: ["w1-predicate"], code_paths: ["Sources/RVDomain/TypedRule.swift"], test_paths: ["Tests/RVDomainTests/TypedRuleTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter TypedRule" },
        #{ id: "w1-match", title: "Match predicate to ProposedAction", goal: "pure PolicyMatch", acceptance: ["force+main matches GitAction.push force main", "does not match feature branch", "does not read supportingCommand"], depends_on: ["w1-predicate"], code_paths: ["Sources/RVDomain/PolicyMatch.swift"], test_paths: ["Tests/RVDomainTests/PolicyMatchTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter PolicyMatch" },
        #{ id: "w1-engine", title: "Engine applies typed rules restrict-only", goal: "EffectiveActionPolicy.rules", acceptance: ["typed deny force-push main is hardDeny", "typed allow cannot beat builtin shared-branch hardDeny", "typed ask on feature force-push is mandatoryHuman"], depends_on: ["w1-rule", "w1-match"], code_paths: ["Sources/RVDomain/ActionPolicyEngine.swift"], test_paths: ["Tests/RVDomainTests/ActionPolicyEngineTypedRuleTests.swift"], fat: false, composition: "reset-hard path unchanged", gate: "tools/gate.sh RVDomainTests --filter ActionPolicyEngineTypedRule" },
        #{ id: "w1-store", title: "Persist machine typed rules", goal: "TypedRuleStore temp dir", acceptance: ["round-trip gitPush deny in temp dir", "repo allow cannot drop machine deny", "no raw argv in JSON"], depends_on: ["w1-rule", "w1-engine"], code_paths: ["Sources/RVPolicy/TypedRuleStore.swift"], test_paths: ["Tests/RVPolicyTests/TypedRuleStoreTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVPolicyTests --filter TypedRuleStore" },
        #{ id: "w1-explain", title: "Explanation names the typed rule", goal: "ActionPolicyExplanation.ruleID", acceptance: ["typed deny explanation.ruleID matches", "builtin reset-hard still builtin id"], depends_on: ["w1-engine"], code_paths: ["Sources/RVDomain/ActionPolicyEngine.swift"], test_paths: ["Tests/RVDomainTests/TypedRuleExplainTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter TypedRuleExplain" },
        #{ id: "w1-cli", title: "rv policy show", goal: "CLI origins", acceptance: ["subcommand on RV", "names builtin/machine/repo", "temp HOME exit 0 no AFM"], depends_on: ["w1-store", "w1-explain"], code_paths: ["Sources/RVCLI/Commands/PolicyCommand.swift", "Sources/RVCLI/RV.swift"], test_paths: ["Tests/RVCLITests/PolicyCommandTests.swift"], fat: false, composition: "help lists policy", gate: "tools/gate.sh RVCLITests --filter PolicyCommand" },
    ];
} else if wave == "W2" {
    units = [
        #{ id: "w2-preview", title: "Preview is a typed form", goal: "RulePinning draft is PolicyPredicate", acceptance: ["force-push main preview includes gitPush", "hard-stop sentence still blocks allow", "IPC sentence tests updated not deleted"], depends_on: [], code_paths: ["Sources/RVPolicy/RulePinning.swift"], test_paths: ["Tests/RVPolicyTests/RulePinningTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVPolicyTests --filter RulePinning" },
        #{ id: "w2-save", title: "Save writes TypedRule", goal: "RulePinStore -> TypedRuleStore", acceptance: ["block pin loads as machine deny", "allow+hardStop throws", "draftMismatch still throws"], depends_on: ["w2-preview"], code_paths: ["Sources/RVPolicy/RulePinStore.swift"], test_paths: ["Tests/RVPolicyTests/RulePinStoreTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVPolicyTests --filter RulePin" },
        #{ id: "w2-service-preview", title: "Service uses typed preview", goal: "IPC rulePreview still round-trips", acceptance: ["allowedToSave false on hard stop", "cancel writes nothing"], depends_on: ["w2-save"], code_paths: ["Sources/RVService/ServiceRuntime.swift"], test_paths: ["Tests/RVIPCTests/PendingAndRuleRoundTripTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVServiceTests RVIPCTests" },
        #{ id: "w2-verify-wall", title: "Wall still holds", goal: "verify_only builtins", acceptance: ["reset-hard still deny", "blocksAllowOverride tests pass"], depends_on: ["w2-save"], code_paths: [], test_paths: [], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter ActionPolicyEngineTests" },
    ];
} else {
    units = [
        #{ id: "w3-protocol", title: "EnglishCompiler protocol", goal: "english -> RulePreview or refuse", acceptance: ["protocol in RVDomain", "no AFM import in Domain"], depends_on: [], code_paths: ["Sources/RVDomain/EnglishCompiler.swift"], test_paths: ["Tests/RVDomainTests/EnglishCompilerTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter EnglishCompilerTests" },
        #{ id: "w3-fake", title: "Fake compiler", goal: "known sentences to gitPush", acceptance: ["never force-push main -> gitPush force main deny", "unknown sentence refuses"], depends_on: ["w3-protocol"], code_paths: ["Sources/RVDomain/FakeEnglishCompiler.swift"], test_paths: ["Tests/RVDomainTests/FakeEnglishCompilerTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter FakeEnglishCompilerTests" },
        #{ id: "w3-ask-wins", title: "Ask beats allow", goal: "same predicate ask+allow", acceptance: ["engine verdict mandatoryHuman when both match"], depends_on: ["w3-fake"], code_paths: ["Sources/RVDomain/ActionPolicyEngine.swift"], test_paths: ["Tests/RVDomainTests/TypedRuleAskWinsTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter TypedRuleAskWins" },
        #{ id: "w3-cli", title: "rv policy draft", goal: "CLI english preview save", acceptance: ["draft --english prints preview writes nothing", "--save persists", "refuse writes nothing"], depends_on: ["w3-fake"], code_paths: ["Sources/RVCLI/Commands/PolicyDraftCommand.swift", "Sources/RVCLI/RV.swift"], test_paths: ["Tests/RVCLITests/PolicyDraftCommandTests.swift"], fat: false, composition: "help lists policy draft", gate: "tools/gate.sh RVCLITests --filter PolicyDraftCommand" },
        #{ id: "w3-afm", title: "Optional AFM compiler", goal: "RVPolicy #if canImport", acceptance: ["tests inject fake not live Apple", "Domain still has no FoundationModels"], depends_on: ["w3-protocol"], code_paths: ["Sources/RVPolicy/FoundationModelsEnglishCompiler.swift"], test_paths: ["Tests/RVPolicyTests/FoundationModelsEnglishCompilerTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVPolicyTests --filter FoundationModelsEnglishCompiler" },
        #{ id: "w3-refuse", title: "Refuse uncompilable English", goal: "npm/mcp/empty", acceptance: ["npm publish refuses", "mcp__linear__save_issue refuses", "store unchanged"], depends_on: ["w3-cli"], code_paths: ["Sources/RVDomain/FakeEnglishCompiler.swift"], test_paths: ["Tests/RVDomainTests/EnglishRefuseTests.swift"], fat: false, composition: "", gate: "tools/gate.sh RVDomainTests --filter EnglishRefuse" },
    ];
}

// ========== Setup ==========
phase("Setup");
log("english-compile-swift wave=" + wave + " mode=" + run_mode + " units=" + units.len().to_string());

let setup_p = "";
setup_p += "You set up english-compile-swift. Do not implement product code.\n";
setup_p += "Repo: " + repo + "\nWave: " + wave + "\n";
setup_p += "1) ART=`mktemp -d \"${TMPDIR:-/tmp}/grok-ecs.XXXXXX\"` && chmod 700 \"$ART\"\n";
setup_p += "   mkdir -p \"$ART/units\" \"$ART/reviews\" \"$ART/handoffs\" \"$ART/logs\"\n";
setup_p += "2) dirty-policy.md: never stage .grok/ except this workflow if asked; never stage scratch/english-review; never wipe .build.\n";
setup_p += "3) Baseline: cd repo; tools/gate.sh RVDomainTests (or note not runnable). Do not swift package clean.\n";
setup_p += "4) Write baseline.md. Return ok=true only if ART exists. run_dir=absolute ART.\n";
setup_p += "Never invent a green baseline you did not run.\n";
setup_p += "Do not use Zig implementor.\n";

let setup = agent(setup_p, #{
    label: "ecs-setup",
    capability_mode: "all",
    output_schema: setup_schema,
});

if setup == () || !setup.success || setup.output == () {
    complete(#{ summary: "Setup agent failed", ok: false, error: "setup returned nothing", wave: wave });
}

let so = setup.output;
let run_dir = if so.run_dir != () { trimmed(so.run_dir) } else { "" };
if so.ok != true || run_dir == "" {
    let err = if so.error != () { so.error } else { "setup did not return run_dir (smoke path or failed setup)" };
    complete(#{ summary: "Setup incomplete", ok: false, error: err, wave: wave });
}

log("run_dir=" + run_dir);

// ========== Units ==========
phase("Units");

let unit_results = [];
let u_index = 0;
for u in units {
    let uid = if u.id != () { trimmed(u.id) } else { "u" + u_index.to_string() };
    let title = if u.title != () { trimmed(u.title) } else { uid };
    let goal = if u.goal != () { trimmed(u.goal) } else { "" };
    u_index += 1;

    if u.fat == true {
        unit_results.push(#{ id: uid, status: "blocked", title: title, reason: "fat", fix_rounds: 0 });
        continue;
    }
    if !deps_ready(u, unit_results) {
        log("skip " + uid + " — deps not passed");
        unit_results.push(#{ id: uid, status: "blocked", title: title, reason: "depends-on not passed", fix_rounds: 0 });
        continue;
    }

    let code_paths = join_paths(u.code_paths);
    let test_paths = join_paths(u.test_paths);
    let acceptance = join_acceptance(u.acceptance);
    let composition = if u.composition != () { trimmed(u.composition) } else { "" };
    let gate = if u.gate != () { trimmed(u.gate) } else { "tools/gate.sh RVDomainTests" };
    let handoff_path = run_dir + "/handoffs/" + uid + ".md";
    let verify_only = uid == "w2-verify-wall";

    let impl_p = "";
    impl_p += "You are the IMPLEMENTER for english-compile-swift unit " + uid + ".\n";
    if verify_only {
        impl_p += "VERIFY_ONLY: if gates green, write complete handoff with evidence and do not expand scope. Edit only if a gate fails.\n";
    } else {
        impl_p += "Implement ONLY this unit. Do not commit or push.\n";
    }
    impl_p += swift_pack_block();
    impl_p += swift_defect_block();
    impl_p += reject_block();
    impl_p += "Repo: " + repo + "\nPlan: " + plan_path + "\n";
    impl_p += "Unit id: " + uid + "\nTitle: " + title + "\nGoal: " + goal + "\n";
    impl_p += "Acceptance:\n" + acceptance + "\n";
    if composition != "" {
        impl_p += "Composition: " + composition + "\n";
    }
    impl_p += "Exclusive code paths: " + code_paths + "\nTest paths: " + test_paths + "\n";
    impl_p += "Gate: " + gate + "\n";
    impl_p += "Handoff MUST be written to: " + handoff_path + "\n";
    impl_p += "STRICT TDD unless verify_only. tools/gate.sh / tools/swift-6.3.3 only.\n";
    impl_p += "cwd=" + repo + "\n";
    impl_p += "Return status=done|partial|blocked, files_changed, tests_touched, handoff_path.\n";

    let impl = agent(impl_p, #{
        label: "ecs-impl:" + uid,
        capability_mode: "all",
        agent_type: "swift-principal-engineer",
        output_schema: implement_schema,
    });

    let impl_ok = impl != () && impl.success && impl.output != () && impl.output.status == "done";
    if !impl_ok {
        let why = "implement failed or not done";
        if impl != () && impl.output != () && impl.output.summary != () {
            why = trimmed(impl.output.summary);
        }
        log("unit " + uid + " implement not done: " + why);
        unit_results.push(#{ id: uid, status: "blocked", title: title, reason: why, fix_rounds: 0 });
        continue;
    }

    let files_changed = if impl.output.files_changed != () { join_paths(impl.output.files_changed) } else { code_paths };
    let impl_summary = if impl.output.summary != () { trimmed(impl.output.summary) } else { "" };

    let review_round = 0;
    let passed = false;
    let last_reason = "";
    while review_round <= max_fix {
        let review_jobs = [];
        if run_mode == "lite" {
            let lite_p = "";
            lite_p += "COMBINED reviewer for " + uid + ". READ-ONLY. Read the tree.\n";
            lite_p += swift_pack_block();
            lite_p += swift_defect_block();
            lite_p += "Handoff: " + handoff_path + "\nGoal: " + goal + "\nAcceptance:\n" + acceptance + "\nFiles: " + files_changed + "\n";
            lite_p += "verdict PASS or FAIL. clean=true only for PASS.\n";
            review_jobs.push(#{
                prompt: lite_p,
                label: "ecs-lite:" + uid + ":r" + review_round.to_string(),
                capability_mode: "read-only",
                agent_type: "code-reviewer",
                output_schema: review_schema,
            });
        } else {
            let beh_p = "";
            beh_p += "BEHAVIOR/TDD reviewer for " + uid + ". READ-ONLY. Read tree and handoff.\n";
            beh_p += swift_pack_block();
            beh_p += "Handoff: " + handoff_path + "\nGoal: " + goal + "\nAcceptance:\n" + acceptance + "\nFiles: " + files_changed + "\n";
            beh_p += "HARD FAIL if tests missing, acceptance unmet, hollow handoff, stub product.\n";
            beh_p += "verdict PASS or FAIL. Write blockers if FAIL.\n";
            review_jobs.push(#{
                prompt: beh_p,
                label: "ecs-beh:" + uid + ":r" + review_round.to_string(),
                capability_mode: "read-only",
                agent_type: "code-reviewer",
                output_schema: review_schema,
            });
            let saf_p = "";
            saf_p += "SAFETY reviewer for " + uid + ". READ-ONLY.\n";
            saf_p += swift_defect_block();
            saf_p += reject_block();
            saf_p += "Handoff: " + handoff_path + "\nFiles: " + files_changed + "\n";
            saf_p += "HARD FAIL: fail-open, argv as matcher, hook Auto-review, secrets in logs, allow beating hard deny.\n";
            saf_p += "verdict PASS or FAIL.\n";
            review_jobs.push(#{
                prompt: saf_p,
                label: "ecs-saf:" + uid + ":r" + review_round.to_string(),
                capability_mode: "read-only",
                agent_type: "security-reviewer",
                output_schema: review_schema,
            });
        }

        let reviews = parallel(review_jobs);
        let any_fail = false;
        let blocker_text = "";
        for rv in reviews {
            if rv == () || !rv.success || rv.output == () {
                any_fail = true;
                blocker_text += "reviewer missing or failed; ";
                continue;
            }
            let v = trimmed(rv.output.verdict.to_string());
            if v != "PASS" || rv.output.clean == false {
                any_fail = true;
                if rv.output.summary != () {
                    blocker_text += trimmed(rv.output.summary);
                    blocker_text += "; ";
                }
            }
        }

        if !any_fail {
            passed = true;
            break;
        }

        last_reason = blocker_text;
        if review_round == max_fix {
            break;
        }

        let fix_p = "";
        fix_p += "FIX agent for " + uid + ". Apply ONLY merged blockers. No nits. No commit.\n";
        fix_p += swift_pack_block();
        fix_p += "Blockers: " + json_encode(blocker_text) + "\n";
        fix_p += "Exclusive paths: " + code_paths + "\nHandoff rewrite: " + handoff_path + "\n";
        fix_p += "Gate: " + gate + "\nRepo: " + repo + "\n";
        let fix = agent(fix_p, #{
            label: "ecs-fix:" + uid + ":r" + review_round.to_string(),
            capability_mode: "all",
            agent_type: "swift-principal-engineer",
            output_schema: implement_schema,
        });
        if fix == () || !fix.success {
            last_reason = "fix agent failed";
            break;
        }
        review_round += 1;
    }

    if passed {
        unit_results.push(#{ id: uid, status: "passed", title: title, reason: impl_summary, fix_rounds: review_round });
        log("passed " + uid);
    } else {
        unit_results.push(#{ id: uid, status: "failed", title: title, reason: last_reason, fix_rounds: review_round });
        log("failed " + uid + ": " + last_reason);
    }
}

// ========== Integrate ==========
phase("Integrate");

let passed_n = 0;
let failed_n = 0;
for r in unit_results {
    if r.status == "passed" { passed_n += 1; }
    if r.status == "failed" || r.status == "blocked" { failed_n += 1; }
}

let int_jobs = [];
let int_p = "";
int_p += "INTEGRATION Behavior+Safety for english-compile-swift " + wave + ".\n";
int_p += "READ-ONLY. Read the repo at " + repo + ".\n";
int_p += "Plan: " + plan_path + "\n";
int_p += swift_defect_block();
int_p += reject_block();
int_p += "Confirm W1 did not add MCP, hook Auto-review, or scratch imports.\n";
int_p += "verdict PASS or FAIL.\n";
int_jobs.push(#{
    prompt: int_p,
    label: "ecs-int-beh",
    capability_mode: "read-only",
    agent_type: "code-reviewer",
    output_schema: review_schema,
});
int_jobs.push(#{
    prompt: int_p,
    label: "ecs-int-saf",
    capability_mode: "read-only",
    agent_type: "security-reviewer",
    output_schema: review_schema,
});
let int_reviews = parallel(int_jobs);
let int_ok = true;
for ir in int_reviews {
    if ir == () || !ir.success || ir.output == () || trimmed(ir.output.verdict.to_string()) != "PASS" {
        int_ok = false;
    }
}

// ========== Oracle ==========
phase("Oracle");

let ora_p = "";
ora_p += "Run live oracles for english-compile-swift " + wave + " in " + repo + ".\n";
ora_p += "Do not wipe .build. Use tools/gate.sh and tools/swift-6.3.3.\n";
if wave == "W1" {
    ora_p += "Run: tools/gate.sh RVDomainTests ; tools/gate.sh RVPolicyTests ; tools/gate.sh --filter PolicyCommand ;\n";
    ora_p += "Do NOT wrap tools/swift-6.3.3 in HOME=$(mktemp -d). Darwin pin is $HOME/Library/Developer/Toolchains.\n";
    ora_p += "Build with real HOME, then: TMP=$(mktemp -d /tmp/rv-policy-show.XXXXXX); HOME=$TMP .build/arm64-apple-macosx/debug/rv policy show\n";
    ora_p += "Expect exit 0, stdout headings builtin/machine/repo, empty TMP tree. Full RVCLITests is not W1 proof.\n";
    ora_p += "Fail if rg scratch/english-review Sources Package.swift hits.\n";
} else if wave == "W2" {
    ora_p += "Run: tools/gate.sh RVPolicyTests ; tools/gate.sh RVDomainTests ; tools/gate.sh RVPolicyTests --filter RulePinning ; tools/gate.sh RVPolicyTests --filter RulePinStore.\n";
    ora_p += "Do NOT wrap tools/swift-6.3.3 in HOME=$(mktemp -d). Darwin pin is $HOME/Library/Developer/Toolchains.\n";
    ora_p += "Do not use --filter ActionPolicyEngine (substring hits shadow suites / SIGSEGV). Unique wall proof is --filter ActionPolicyEngineTests. Full RVCLITests is not W2 proof.\n";
    ora_p += "Fail if rg scratch/english-review Sources Package.swift hits.\n";
} else {
    ora_p += "Run unique filters only:\n";
    ora_p += "  tools/gate.sh RVDomainTests --filter EnglishCompilerTests\n";
    ora_p += "  tools/gate.sh RVDomainTests --filter FakeEnglishCompilerTests\n";
    ora_p += "  tools/gate.sh RVDomainTests --filter TypedRuleAskWins\n";
    ora_p += "  tools/gate.sh RVDomainTests --filter EnglishRefuse\n";
    ora_p += "  tools/gate.sh RVPolicyTests --filter FoundationModelsEnglishCompiler\n";
    ora_p += "  tools/gate.sh RVCLITests --filter PolicyDraftCommand\n";
    ora_p += "  tools/gate.sh RVDomainTests --filter ActionPolicyEngineTests\n";
    ora_p += "Do NOT wrap tools/swift-6.3.3 in HOME=$(mktemp -d). Darwin pin is $HOME/Library/Developer/Toolchains.\n";
    ora_p += "Do not use --filter ActionPolicyEngine, --filter TypedRule, or --filter EnglishCompiler (substring hits FakeEnglishCompiler / SIGSEGV).\n";
    ora_p += "Full RVCLITests is not W3 proof.\n";
    ora_p += "Build with real HOME, then: TMP=$(mktemp -d /tmp/rv-policy-draft.XXXXXX); HOME=$TMP .build/arm64-apple-macosx/debug/rv policy draft --english \"never allow force-push to main\" --robot\n";
    ora_p += "Expect exit 0, JSON gitPush force main, allowedToSave true, no files written under TMP. Then HOME=$TMP same binary --save, then HOME=$TMP rv policy show lists a machine deny. Refuse: HOME=$TMP rv policy draft --english \"be careful in prod\" writes nothing.\n";
    ora_p += "Fail if rg scratch/english-review Sources Package.swift hits.\n";
}
ora_p += "Return ok=true only if commands you ran exited 0. List commands in commands[].\n";

let oracle = agent(ora_p, #{
    label: "ecs-oracle",
    capability_mode: "all",
    output_schema: oracle_schema,
});

let oracle_ok = oracle != () && oracle.success && oracle.output != () && oracle.output.ok == true;

// ========== Report ==========
phase("Report");

let summary = wave + " passed=" + passed_n.to_string() + " failed=" + failed_n.to_string();
if !int_ok { summary += " integrate=FAIL"; }
if !oracle_ok { summary += " oracle=FAIL"; }

let report = "";
report += "# english-compile-swift " + wave + "\n\n";
report += summary + "\n\n";
for r in unit_results {
    report += "- " + r.id + " " + r.status + " — " + trimmed(r.reason.to_string()) + "\n";
}

let report_path = write_scratch_file("english-compile-report.md", report);

complete(#{
    summary: summary,
    ok: failed_n == 0 && int_ok && oracle_ok,
    wave: wave,
    mode: run_mode,
    run_dir: run_dir,
    report_path: report_path,
    units_passed: passed_n,
    units_failed: failed_n,
});
