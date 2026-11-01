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
    "hermes", "codex", "cursor", "antigravity",
};
#define HOST_COUNT (sizeof kHosts / sizeof kHosts[0])

/* Absent or slow daemon: RV_HOOK_WHEN_DOWN decides. */
static const enum RvHookFailure kDown[] = {
    RV_HOOK_FAIL_UNREACHABLE,
    RV_HOOK_FAIL_TIMEOUT,
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
        || strcmp(host, "cursor") == 0 || strcmp(host, "antigravity") == 0) {
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
}

static void test_messages(void) {
    const enum RvHookFailure all[] = {
        RV_HOOK_FAIL_INPUT, RV_HOOK_FAIL_UNREACHABLE, RV_HOOK_FAIL_TIMEOUT,
        RV_HOOK_FAIL_UNTRUSTED, RV_HOOK_FAIL_PROTOCOL,
    };
    size_t i;
    size_t j;
    for (i = 0; i < sizeof all / sizeof all[0]; i++) {
        const char *m = rv_hook_failure_message(all[i]);
        char escaped[512];
        size_t n = 0;
        if (m == NULL || m[0] == '\0') {
            fail("message_present", "empty message");
            continue;
        }
        /* Constants are spliced into JSON verbatim: escaping must be a no-op. */
        if (rv_json_escape((const unsigned char *)m, strlen(m), escaped, sizeof escaped, &n) != 0
            || n != strlen(m) || strcmp(escaped, m) != 0) {
            fail("message_json_safe", m);
        }
        for (j = i + 1; j < sizeof all / sizeof all[0]; j++) {
            if (strcmp(m, rv_hook_failure_message(all[j])) == 0) {
                fail("message_distinct", m);
            }
        }
    }
    if (strstr(rv_hook_failure_message(RV_HOOK_FAIL_UNREACHABLE), "rv doctor") == NULL) {
        fail("unreachable_actionable", "missing rv doctor");
    }
    if (strstr(rv_hook_failure_message(RV_HOOK_FAIL_UNREACHABLE), "dev.rv.evaluate") == NULL) {
        fail("unreachable_names_service", "missing dev.rv.evaluate");
    }
    if (strstr(rv_hook_failure_message(RV_HOOK_FAIL_TIMEOUT), "rv doctor") == NULL) {
        fail("timeout_actionable", "missing rv doctor");
    }
    if (strstr(rv_hook_failure_message(RV_HOOK_FAIL_UNTRUSTED), "rv setup") == NULL) {
        fail("untrusted_actionable", "missing rv setup");
    }
    /* Unknown class is never NULL: the caller still has to say something. */
    if (rv_hook_failure_message((enum RvHookFailure)99) == NULL) {
        fail("unknown_class_message", "NULL");
    }
}

static void test_exact_wires(void) {
    const char *unreach = rv_hook_failure_message(RV_HOOK_FAIL_UNREACHABLE);
    const char *input = rv_hook_failure_message(RV_HOOK_FAIL_INPUT);
    char want[2048];
    char err_want[512];

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

    snprintf(want, sizeof want,
             "{\"permission\":\"deny\",\"user_message\":\"%s\","
             "\"agent_message\":\"RV blocked this command. Wait for the human.\"}\n", unreach);
    expect_exact("cursor_deny", "cursor", RV_HOOK_FAIL_UNREACHABLE, RV_WHEN_DOWN_DENY, want, "", 0);

    /* Codex has no ask primitive: deny shape (block + stderr + exit 2) even in ask mode. */
    snprintf(want, sizeof want, "{\"decision\":\"block\",\"reason\":\"%s\"}\n", unreach);
    snprintf(err_want, sizeof err_want, "%s\n", unreach);
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
    test_exact_wires();
    test_matrix();
    test_bad_args();
    if (g_fails != 0) {
        fprintf(stderr, "%d failure(s)\n", g_fails);
        return 1;
    }
    printf("hook_fallback tests ok\n");
    return 0;
}
