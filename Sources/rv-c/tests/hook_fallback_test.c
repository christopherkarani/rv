#include "hook_fallback.h"
#include "json_escape.h"

#include <stdio.h>
#include <string.h>

static int g_fails;

static void fail(const char *name, const char *detail) {
    fprintf(stderr, "FAIL %s: %s\n", name, detail);
    g_fails += 1;
}

static const char *const kHosts[] = {
    "grok", "pi", "opencode", "claude", "openclaw",
    "hermes", "codex", "cursor", "antigravity", "muse",
};
#define HOST_COUNT (sizeof kHosts / sizeof kHosts[0])

/* Absent, slow or dropped daemon: RV_HOOK_WHEN_DOWN decides. */
static const enum RvHookFailure kDown[] = {
    RV_HOOK_FAIL_UNREACHABLE,
    RV_HOOK_FAIL_TIMEOUT,
    RV_HOOK_FAIL_CONNECTION,
    RV_HOOK_FAIL_STOPPED,
};
#define DOWN_COUNT (sizeof kDown / sizeof kDown[0])

/* Malformed input, impersonation and malformed replies: deny in every mode. */
static const enum RvHookFailure kHard[] = {
    RV_HOOK_FAIL_INPUT,
    RV_HOOK_FAIL_UNTRUSTED,
    RV_HOOK_FAIL_PROTOCOL,
};
#define HARD_COUNT (sizeof kHard / sizeof kHard[0])
static const enum RvWhenDown kModes[] = { RV_WHEN_DOWN_ASK, RV_WHEN_DOWN_DENY };
#define MODE_COUNT (sizeof kModes / sizeof kModes[0])

static int deny_exit(const char *host) {
    if (strcmp(host, "codex") == 0) {
        return 2;
    }
    if (strcmp(host, "grok") == 0 || strcmp(host, "claude") == 0
        || strcmp(host, "cursor") == 0 || strcmp(host, "antigravity") == 0
        || strcmp(host, "muse") == 0) {
        return 0;
    }
    return 1;
}

static void render(
    const char *name,
    const char *host,
    enum RvHookFailure failure,
    enum RvWhenDown mode,
    struct RvHookFallback *out
) {
    memset(out, 0x5a, sizeof *out);
    if (rv_hook_fallback_render(host, failure, mode, out) != 0) {
        fail(name, "render failed");
        memset(out, 0, sizeof *out);
    }
}

static void expect_exact(
    const char *name,
    const char *host,
    enum RvHookFailure failure,
    enum RvWhenDown mode,
    const char *out_want,
    const char *err_want,
    int exit_want
) {
    struct RvHookFallback r;
    render(name, host, failure, mode, &r);
    if (strcmp(r.out, out_want) != 0) {
        fprintf(stderr, "  got:  %s\n  want: %s\n", r.out, out_want);
        fail(name, "stdout mismatch");
    }
    if (strcmp(r.err, err_want) != 0) {
        fprintf(stderr, "  got stderr:  %s\n  want stderr: %s\n", r.err, err_want);
        fail(name, "stderr mismatch");
    }
    if (r.exit_code != exit_want) {
        fail(name, "exit code mismatch");
    }
}

static void test_mode_parse(void) {
    if (rv_when_down_parse(NULL) != RV_WHEN_DOWN_ASK) fail("parse_null", "not ask");
    if (rv_when_down_parse("") != RV_WHEN_DOWN_ASK) fail("parse_empty", "not ask");
    if (rv_when_down_parse("ask") != RV_WHEN_DOWN_ASK) fail("parse_ask", "not ask");
    if (rv_when_down_parse("deny") != RV_WHEN_DOWN_DENY) fail("parse_deny", "not deny");
    /* No bypass value exists: "allow" can come from agent-writable config. */
    if (rv_when_down_parse("allow") != RV_WHEN_DOWN_ASK) fail("parse_allow", "not ask");
    if (rv_when_down_parse("ALLOW") != RV_WHEN_DOWN_ASK) fail("parse_upper", "not ask");
    if (rv_when_down_parse("allow ") != RV_WHEN_DOWN_ASK) fail("parse_space", "not ask");
    if (rv_when_down_parse("1") != RV_WHEN_DOWN_ASK) fail("parse_junk", "not ask");
    /* Observe comes only from the owner's config file, never the environment. */
    if (rv_when_down_parse("observe") != RV_WHEN_DOWN_ASK) fail("parse_observe", "not ask");
}

static void test_messages(void) {
    const enum RvHookFailure all[] = {
        RV_HOOK_FAIL_INPUT, RV_HOOK_FAIL_UNREACHABLE, RV_HOOK_FAIL_TIMEOUT,
        RV_HOOK_FAIL_UNTRUSTED, RV_HOOK_FAIL_PROTOCOL, RV_HOOK_FAIL_CONNECTION,
        RV_HOOK_FAIL_STOPPED,
    };
    size_t i;
    size_t j;
    for (i = 0; i < sizeof all / sizeof all[0]; i++) {
        const char *parts[3];
        size_t p;
        size_t words = 1;
        const char *c;
        parts[0] = rv_hook_failure_message(all[i]);
        parts[1] = rv_hook_failure_rule(all[i]);
        parts[2] = rv_hook_failure_fix(all[i]);
        for (p = 0; p < 3; p++) {
            const char *m = parts[p];
            char escaped[512];
            size_t n = 0;
            if (m == NULL || m[0] == '\0') {
                fail("message_present", "empty message part");
                continue;
            }
            /* Constants hold nothing JSON must escape. */
            if (rv_json_escape((const unsigned char *)m, strlen(m), escaped, sizeof escaped, &n) != 0
                || n != strlen(m) || strcmp(escaped, m) != 0) {
                fail("message_json_safe", m);
            }
        }
        /* Why, in under ten words. */
        for (c = parts[0]; *c != '\0'; c++) {
            if (*c == ' ') {
                words++;
            }
        }
        if (words > 9) {
            fail("why_under_ten_words", parts[0]);
        }
        if (strncmp(parts[1], "rv.hook/", 8) != 0) {
            fail("rule_id", parts[1]);
        }
        if (strcmp(parts[2], "rv doctor") != 0 && strcmp(parts[2], "rv service restart") != 0) {
            fail("fix_is_an_rv_command", parts[2]);
        }
        for (j = i + 1; j < sizeof all / sizeof all[0]; j++) {
            if (strcmp(parts[0], rv_hook_failure_message(all[j])) == 0
                || strcmp(parts[1], rv_hook_failure_rule(all[j])) == 0) {
                fail("message_distinct", parts[0]);
            }
        }
    }
    if (strcmp(rv_hook_failure_fix(RV_HOOK_FAIL_UNREACHABLE), "rv doctor") != 0) {
        fail("unreachable_actionable", "missing rv doctor");
    }
    if (strcmp(rv_hook_failure_fix(RV_HOOK_FAIL_UNTRUSTED), "rv service restart") != 0) {
        fail("untrusted_actionable", "missing rv service restart");
    }
    if (strcmp(rv_hook_failure_fix(RV_HOOK_FAIL_STOPPED), "rv service restart") != 0) {
        fail("stopped_actionable", "missing rv service restart");
    }
    /* Unknown class is never NULL: the caller still has to say something. */
    if (rv_hook_failure_message((enum RvHookFailure)99) == NULL) {
        fail("unknown_class_message", "NULL");
    }
}

/* Same cases as `OwnerNameTests` in RVDomainTests. */
static void test_owner_name(void) {
    static const struct { const char *gecos; const char *want; } cases[] = {
        {"Christopher Karani", "Christopher"},
        {"Chris", "Chris"},
        {"Chris Karani,,,", "Chris"},
        {"  Chris", "Chris"},
        {"Zo\xC3\xAB Smith", "Zo\xC3\xAB"},
        {"\xC3\x89mile", "\xC3\x89mile"},
        {"Mary-Jane Watson", "Mary-Jane"},
        {"O'Brien", "O'Brien"},
        {"root", ""},
        {"runner", ""},
        {"", ""},
        {",,,", ""},
        {"-Chris", ""},
        {"Chris-", ""},
        {"Ch--ris", ""},
        {"Chris2", ""},
        {"Chris.", ""},
        {"Chris\"", ""},
        {"Chris\\n", ""},
        {"Chris\x1b[31m", ""},
        {"\xC3\x97" "Chris", ""},
        {"Chr\xC3\xB7is", ""},
        {"Chris\xE2\x80\xAE", ""},
        {"\xD0\x98\xD0\xB2\xD0\xB0\xD0\xBD", ""},
        {"Abcdefghijklmnopqrstuvwxyzabcdef", "Abcdefghijklmnopqrstuvwxyzabcdef"},
        {"Abcdefghijklmnopqrstuvwxyzabcdefg", ""},
    };
    size_t i;
    char out[RV_OWNER_NAME_MAX + 1];
    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        int rc = rv_owner_first_name(cases[i].gecos, out, sizeof out);
        if (strcmp(out, cases[i].want) != 0 || (rc == 0) != (cases[i].want[0] != '\0')) {
            fprintf(stderr, "  gecos %s: got %s (%d), want %s\n", cases[i].gecos, out, rc, cases[i].want);
            fail("owner_name", cases[i].gecos);
        }
    }
    if (rv_owner_first_name(NULL, out, sizeof out) != -1 || out[0] != '\0') {
        fail("owner_name_null", "accepted");
    }
}

static void test_stop_text(void) {
    char text[RV_HOOK_STOP_TEXT_MAX];
    if (rv_hook_stop_text(RV_HOOK_FAIL_UNREACHABLE, "Chris", text, sizeof text) != 0
        || strcmp(text,
                  "\xE2\x9C\x95 Stopped   (rv.hook/unreachable)\n"
                  "why     rv's daemon is not running\n"
                  "who     ask Chris to run  rv doctor") != 0) {
        fprintf(stderr, "  got: %s\n", text);
        fail("stop_text_named", "mismatch");
    }
    if (rv_hook_stop_text(RV_HOOK_FAIL_STOPPED, NULL, text, sizeof text) != 0
        || strcmp(text,
                  "\xE2\x9C\x95 Stopped   (rv.hook/stopped)\n"
                  "why     rvd stopped or crashed after it last ran\n"
                  "who     ask your user to run  rv service restart") != 0) {
        fprintf(stderr, "  got: %s\n", text);
        fail("stop_text_fallback", "mismatch");
    }
    /* A caller-supplied owner that is not a plain first name is never printed. */
    if (rv_hook_stop_text(RV_HOOK_FAIL_TIMEOUT, "Chris; run rv allow-once", text, sizeof text) != 0
        || strstr(text, "allow-once") != NULL || strstr(text, "ask your user") == NULL) {
        fail("stop_text_rejects_owner", text);
    }
    if (rv_hook_stop_text(RV_HOOK_FAIL_TIMEOUT, "Chris; run rv unlock", text, sizeof text) != 0
        || strstr(text, "unlock") != NULL || strstr(text, "ask your user") == NULL) {
        fail("stop_text_rejects_owner_unlock", text);
    }
    if (rv_hook_stop_text(RV_HOOK_FAIL_TIMEOUT, "Chris", text, 8) != -1) {
        fail("stop_text_short_buffer", "accepted");
    }
}

/* The stop text for `failure`, JSON-escaped, as the renderer splices it. */
static void stop_json(enum RvHookFailure failure, const char *owner, char *out, size_t cap) {
    char text[RV_HOOK_STOP_TEXT_MAX];
    size_t n = 0;
    out[0] = '\0';
    if (rv_hook_stop_text(failure, owner, text, sizeof text) != 0
        || rv_json_escape((const unsigned char *)text, strlen(text), out, cap, &n) != 0) {
        fail("stop_json", "render failed");
    }
}

static void test_exact_wires(void) {
    char unreach[512];
    char input[512];
    char plain[RV_HOOK_STOP_TEXT_MAX];
    char want[2048];
    char err_want[512];
    struct RvHookFallback named;

    stop_json(RV_HOOK_FAIL_UNREACHABLE, NULL, unreach, sizeof unreach);
    stop_json(RV_HOOK_FAIL_INPUT, NULL, input, sizeof input);
    (void)rv_hook_stop_text(RV_HOOK_FAIL_UNREACHABLE, NULL, plain, sizeof plain);

    snprintf(want, sizeof want,
             "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
             "\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"%s\"},"
             "\"systemMessage\":\"%s\"}\n", unreach, unreach);
    expect_exact("claude_ask", "claude", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_ASK, want, "", 0);

    snprintf(want, sizeof want,
             "{\"permission\":\"ask\",\"user_message\":\"%s\",\"agent_message\":\"%s\"}\n",
             unreach, unreach);
    expect_exact("cursor_ask", "cursor", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_ASK, want, "", 0);

    snprintf(want, sizeof want,
             "{\"systemMessage\":\"%s\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
             "\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"%s\"}}\n",
             unreach, unreach);
    expect_exact("claude_deny", "claude", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_DENY, want, "", 0);

    /* Cursor's agent reads the same stop as the person. */
    snprintf(want, sizeof want,
             "{\"permission\":\"deny\",\"user_message\":\"%s\",\"agent_message\":\"%s\"}\n", unreach, unreach);
    expect_exact("cursor_deny", "cursor", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_DENY, want, "", 0);

    /* MuseHostCodec: hookSpecificOutput deny, exit 0; `decision: block` is rejected. */
    snprintf(want, sizeof want,
             "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
             "\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"%s\"}}\n", unreach);
    expect_exact("muse_ask_falls_back", "muse", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_ASK, want, "", 0);

    /* Codex has no ask primitive: deny shape (block + stderr + exit 2) even in
     * ask mode. Its stderr carries the plain stop, real newlines included. */
    snprintf(want, sizeof want, "{\"decision\":\"block\",\"reason\":\"%s\"}\n", unreach);
    snprintf(err_want, sizeof err_want, "%s\n", plain);
    expect_exact("codex_ask_falls_back", "codex", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_ASK,
                 want, err_want, 2);

    snprintf(want, sizeof want, "{\"decision\":\"deny\",\"reason\":\"%s\"}\n", unreach);
    expect_exact("grok_ask_falls_back", "grok", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_ASK, want, "", 0);
    expect_exact("opencode_deny", "opencode", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_DENY, want, "", 1);

    /* Input is a deny whatever the mode: malformed bytes never reach a human or the host. */
    snprintf(want, sizeof want,
             "{\"systemMessage\":\"%s\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
             "\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"%s\"}}\n",
             input, input);
    expect_exact("claude_input_ask_mode", "claude", RV_HOOK_FAIL_INPUT, RV_WHEN_DOWN_ASK, want, "", 0);

    /* The owner's first name reaches the who line. */
    memset(&named, 0, sizeof named);
    if (rv_hook_fallback_render_for("grok", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_DENY, "Chris", &named) != 0
        || strcmp(named.out,
                  "{\"decision\":\"deny\",\"reason\":\"\xE2\x9C\x95 Stopped   (rv.hook/unreachable)\\n"
                  "why     rv's daemon is not running\\nwho     ask Chris to run  rv doctor\"}\n") != 0) {
        fprintf(stderr, "  got: %s\n", named.out);
        fail("named_owner_wire", "mismatch");
    }
}

static void test_matrix(void) {
    size_t h;
    size_t f;
    for (h = 0; h < HOST_COUNT; h++) {
        const char *host = kHosts[h];
        int ask_host = strcmp(host, "claude") == 0 || strcmp(host, "cursor") == 0;
        struct RvHookFallback r;
        char name[96];

        for (f = 0; f < DOWN_COUNT; f++) {
            const char *msg = rv_hook_failure_message(kDown[f]);

            snprintf(name, sizeof name, "%s_deny_%d", host, (int)kDown[f]);
            render(name, host, kDown[f], RV_WHEN_DOWN_DENY, &r);
            if (r.exit_code != deny_exit(host) || strstr(r.out, msg) == NULL
                || strstr(r.out, "\"ask\"") != NULL) {
                fail(name, "deny shape/exit/message");
            }
            if (strcmp(host, "codex") == 0 && strcmp(r.err, "") == 0) {
                fail(name, "codex deny needs stderr");
            }

            snprintf(name, sizeof name, "%s_ask_%d", host, (int)kDown[f]);
            render(name, host, kDown[f], RV_WHEN_DOWN_ASK, &r);
            if (strstr(r.out, msg) == NULL) {
                fail(name, "ask missing message");
            }
            if (ask_host) {
                if (r.exit_code != 0 || strstr(r.out, "\"ask\"") == NULL
                    || strstr(r.out, "\"deny\"") != NULL
                    || strstr(r.out, "Wait for the human") != NULL) {
                    fail(name, "ask host must emit native ask, exit 0");
                }
            } else if (r.exit_code != deny_exit(host) || strstr(r.out, "\"ask\"") != NULL) {
                fail(name, "non-ask host must fall back to deny");
            }
        }

        for (f = 0; f < HARD_COUNT; f++) {
            size_t m;
            for (m = 0; m < MODE_COUNT; m++) {
                snprintf(name, sizeof name, "%s_hard_%d_mode_%d", host, (int)kHard[f], (int)kModes[m]);
                render(name, host, kHard[f], kModes[m], &r);
                if (r.exit_code != deny_exit(host) || r.out[0] == '\0'
                    || strstr(r.out, "\"ask\"") != NULL
                    || strstr(r.out, rv_hook_failure_message(kHard[f])) == NULL) {
                    fail(name, "input/untrusted/protocol must deny in every mode");
                }
            }
        }
    }
}

static const char kObserveErr[] =
    "RV observe mode: daemon unavailable, so this call was allowed without being checked or logged. Run `rv doctor`.\n";

/* The host's own allow wire (HostCodec.encodeAllow): rv steps aside. */
static const char *observe_allow_out(const char *host) {
    if (strcmp(host, "cursor") == 0) {
        return "{\"permission\":\"allow\"}\n";
    }
    if (strcmp(host, "antigravity") == 0) {
        return "{\"decision\":\"allow\"}\n";
    }
    return "";
}

static void test_observe(void) {
    size_t h;
    size_t f;
    char name[96];
    for (h = 0; h < HOST_COUNT; h++) {
        const char *host = kHosts[h];
        struct RvHookFallback r;
        struct RvHookFallback ask;
        snprintf(name, sizeof name, "%s_observe_unreachable", host);
        expect_exact(name, host, RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_OBSERVE,
                     observe_allow_out(host), kObserveErr, 0);
        /* A live but slow daemon would have applied rv's self-protection, and
         * an agent can make it slow: a timeout keeps the default ask render. */
        snprintf(name, sizeof name, "%s_observe_timeout", host);
        render(name, host, RV_HOOK_FAIL_TIMEOUT, RV_WHEN_DOWN_OBSERVE, &r);
        render(name, host, RV_HOOK_FAIL_TIMEOUT, RV_WHEN_DOWN_ASK, &ask);
        if (strcmp(r.out, ask.out) != 0 || strcmp(r.err, ask.err) != 0 || r.exit_code != ask.exit_code) {
            fail(name, "timeout under observe must render like ask");
        }
        /* A dropped or unverifiable connection (rvd draining mid-request, an
         * agent-chosen XDG_RUNTIME_DIR) is not proof rvd is absent. */
        snprintf(name, sizeof name, "%s_observe_connection", host);
        render(name, host, RV_HOOK_FAIL_CONNECTION, RV_WHEN_DOWN_OBSERVE, &r);
        render(name, host, RV_HOOK_FAIL_CONNECTION, RV_WHEN_DOWN_ASK, &ask);
        if (strcmp(r.out, ask.out) != 0 || strcmp(r.err, ask.err) != 0 || r.exit_code != ask.exit_code
            || strstr(r.err, "observe") != NULL) {
            fail(name, "connection failure under observe must render like ask");
        }
        /* The rvd state marker said rvd was stopped or crashed: observe
         * mode must not step aside, whatever mode reaches the renderer. */
        snprintf(name, sizeof name, "%s_observe_stopped", host);
        render(name, host, RV_HOOK_FAIL_STOPPED, RV_WHEN_DOWN_OBSERVE, &r);
        render(name, host, RV_HOOK_FAIL_STOPPED, RV_WHEN_DOWN_ASK, &ask);
        if (strcmp(r.out, ask.out) != 0 || strcmp(r.err, ask.err) != 0 || r.exit_code != ask.exit_code
            || r.out[0] == '\0'
            || strstr(r.out, rv_hook_failure_message(RV_HOOK_FAIL_STOPPED)) == NULL) {
            fail(name, "stopped under observe must render like ask");
        }
        /* Observe never softens impersonation, a malformed reply or bad input. */
        for (f = 0; f < HARD_COUNT; f++) {
            snprintf(name, sizeof name, "%s_observe_hard_%d", host, (int)kHard[f]);
            render(name, host, kHard[f], RV_WHEN_DOWN_OBSERVE, &r);
            if (r.exit_code != deny_exit(host) || r.out[0] == '\0'
                || strstr(r.out, rv_hook_failure_message(kHard[f])) == NULL
                || strstr(r.out, "allow") != NULL) {
                fail(name, "hard failure must deny under observe");
            }
        }
    }
}

static void test_bad_args(void) {
    struct RvHookFallback r;
    if (rv_hook_fallback_render(NULL, RV_HOOK_FAIL_TIMEOUT, RV_WHEN_DOWN_ASK, &r) == 0) {
        fail("null_host", "accepted");
    }
    if (rv_hook_fallback_render("claude", RV_HOOK_FAIL_TIMEOUT, RV_WHEN_DOWN_ASK, NULL) == 0) {
        fail("null_out", "accepted");
    }
    /* Unknown mode value is treated like the default (ask), never allow. */
    render("unknown_mode", "grok", RV_HOOK_FAIL_TIMEOUT, (enum RvWhenDown)42, &r);
    if (r.out[0] == '\0' || strstr(r.out, "\"deny\"") == NULL) {
        fail("unknown_mode", "must not allow");
    }
}

int main(void) {
    test_mode_parse();
    test_messages();
    test_owner_name();
    test_stop_text();
    test_exact_wires();
    test_matrix();
    test_observe();
    test_bad_args();
    if (g_fails != 0) {
        fprintf(stderr, "%d failure(s)\n", g_fails);
        return 1;
    }
    printf("hook_fallback tests ok\n");
    return 0;
}
