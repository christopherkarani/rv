#include "hook_fallback.h"

#include <stdio.h>
#include <string.h>

/* Constants are spliced into JSON verbatim: no quote, backslash or control
 * byte may appear (pinned by hook_fallback_test). Keep in sync with
 * `HookDaemonFallback.message(for:)` in RVCLI. */
static const char kInputMessage[] =
    "RV could not read this hook request (unreadable, over 1 MiB, NUL byte, or invalid UTF-8), so it was blocked.";
static const char kUnreachableMessage[] =
    "RV daemon is not reachable (dev.rv.evaluate). Run `rv doctor`; `rv setup` repairs the service.";
static const char kTimeoutMessage[] =
    "RV daemon did not answer in time. Retry; if it persists run `rv doctor`.";
static const char kUntrustedMessage[] =
    "RV daemon identity check failed (stale or mismatched rvd after an upgrade?). Run `rv service restart`; if it persists, `rv setup`.";
static const char kProtocolMessage[] =
    "RV daemon sent an unexpected reply (version skew after an upgrade?). Run `rv service restart`; if it persists, `rv setup`.";

/* Existing Cursor deny `agent_message`; down-case asks never use it. */
static const char kCursorDenyAgentLine[] = "RV blocked this command. Wait for the human.";

enum RvWhenDown rv_when_down_parse(const char *value) {
    if (value == NULL) {
        return RV_WHEN_DOWN_ASK;
    }
    if (strcmp(value, "deny") == 0) {
        return RV_WHEN_DOWN_DENY;
    }
    return RV_WHEN_DOWN_ASK;
}

const char *rv_hook_failure_message(enum RvHookFailure failure) {
    switch (failure) {
    case RV_HOOK_FAIL_INPUT:
        return kInputMessage;
    case RV_HOOK_FAIL_UNREACHABLE:
        return kUnreachableMessage;
    case RV_HOOK_FAIL_TIMEOUT:
        return kTimeoutMessage;
    case RV_HOOK_FAIL_UNTRUSTED:
        return kUntrustedMessage;
    case RV_HOOK_FAIL_PROTOCOL:
        return kProtocolMessage;
    }
    return kProtocolMessage;
}

static int fits(int n, size_t cap) {
    return n >= 0 && (size_t)n < cap;
}

/* Host deny shape and exit code (unchanged from the pre-classification
 * deny_hook): Codex block + stderr + exit 2; Claude / Cursor native deny,
 * exit 0; leftover `decision: deny` exits 0 for Grok / Antigravity, else 1. */
static int render_deny(const char *host, const char *msg, struct RvHookFallback *out) {
    int n;
    if (strcmp(host, "codex") == 0) {
        n = snprintf(out->out, sizeof out->out,
                     "{\"decision\":\"block\",\"reason\":\"%s\"}\n", msg);
        if (!fits(n, sizeof out->out)) {
            return -1;
        }
        n = snprintf(out->err, sizeof out->err, "%s\n", msg);
        out->exit_code = 2;
        return fits(n, sizeof out->err) ? 0 : -1;
    }
    if (strcmp(host, "claude") == 0) {
        n = snprintf(out->out, sizeof out->out,
                     "{\"systemMessage\":\"%s\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
                     "\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"%s\"}}\n",
                     msg, msg);
    } else if (strcmp(host, "cursor") == 0) {
        n = snprintf(out->out, sizeof out->out,
                     "{\"permission\":\"deny\",\"user_message\":\"%s\",\"agent_message\":\"%s\"}\n",
                     msg, kCursorDenyAgentLine);
    } else {
        n = snprintf(out->out, sizeof out->out,
                     "{\"decision\":\"deny\",\"reason\":\"%s\"}\n", msg);
        if (strcmp(host, "grok") != 0 && strcmp(host, "antigravity") != 0) {
            out->exit_code = 1;
        }
    }
    return fits(n, sizeof out->out) ? 0 : -1;
}

/* Native ask for hosts that have one; 1 when rendered, 0 when the host has
 * no ask primitive, -1 on overflow. */
static int render_ask(const char *host, const char *msg, struct RvHookFallback *out) {
    int n;
    if (strcmp(host, "claude") == 0) {
        n = snprintf(out->out, sizeof out->out,
                     "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
                     "\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"%s\"},"
                     "\"systemMessage\":\"%s\"}\n",
                     msg, msg);
    } else if (strcmp(host, "cursor") == 0) {
        n = snprintf(out->out, sizeof out->out,
                     "{\"permission\":\"ask\",\"user_message\":\"%s\",\"agent_message\":\"%s\"}\n",
                     msg, msg);
    } else {
        return 0;
    }
    return fits(n, sizeof out->out) ? 1 : -1;
}

int rv_hook_fallback_render(
    const char *host,
    enum RvHookFailure failure,
    enum RvWhenDown mode,
    struct RvHookFallback *out
) {
    const char *msg;
    if (host == NULL || out == NULL) {
        return -1;
    }
    out->out[0] = '\0';
    out->err[0] = '\0';
    out->exit_code = 0;
    msg = rv_hook_failure_message(failure);
    /* Only an absent or slow daemon is configurable. Malformed input, a
     * daemon that fails identity verification (possible impersonation) and
     * a malformed reply always deny. */
    if (failure != RV_HOOK_FAIL_UNREACHABLE && failure != RV_HOOK_FAIL_TIMEOUT) {
        return render_deny(host, msg, out);
    }
    switch (mode) {
    case RV_WHEN_DOWN_DENY:
        return render_deny(host, msg, out);
    case RV_WHEN_DOWN_ASK:
    default: {
        int asked = render_ask(host, msg, out);
        if (asked != 0) {
            return asked > 0 ? 0 : -1;
        }
        return render_deny(host, msg, out);
    }
    }
}
