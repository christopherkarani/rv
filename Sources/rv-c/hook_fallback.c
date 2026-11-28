#include "hook_fallback.h"
#include "json_escape.h"

#include <stdio.h>
#include <string.h>

/* One shape for every stop (North Star B1), as the Swift hook prints it:
 *
 *     ✕ Stopped   (rv.hook/unreachable)
 *     why     rv's daemon is not running
 *     who     ask Chris to run  rv doctor
 *
 * The rule, why and fix constants hold no quote, backslash or control byte
 * (pinned by hook_fallback_test); the composed text is JSON-escaped before
 * it is spliced into host JSON. Keep in sync with
 * `HookDaemonFallback.rule(for:)`, `why(for:)` and `fix(for:)` in RVCLI
 * (HookDaemonFallbackTests reads this file). */
struct RvFailureText {
    const char *rule;
    const char *why;
    const char *fix;
};

static const char kDoctor[] = "rv doctor";
static const char kRestart[] = "rv service restart";

static const struct RvFailureText kInputText = {
    "rv.hook/input", "rv could not read this hook request", kDoctor};
static const struct RvFailureText kUnreachableText = {
    "rv.hook/unreachable", "rv's daemon is not running", kDoctor};
static const struct RvFailureText kTimeoutText = {
    "rv.hook/timeout", "rv's daemon did not answer in time", kDoctor};
static const struct RvFailureText kConnectionText = {
    "rv.hook/connection", "rv lost its daemon before a verdict", kDoctor};
static const struct RvFailureText kUntrustedText = {
    "rv.hook/untrusted", "rv's daemon failed its identity check", kRestart};
static const struct RvFailureText kProtocolText = {
    "rv.hook/protocol", "rv's daemon sent a reply rv cannot read", kRestart};
static const struct RvFailureText kStoppedText = {
    "rv.hook/stopped", "rvd stopped or crashed after it last ran", kRestart};

/* `OwnerName.fallback` in RVDomain. */
static const char kOwnerFallback[] = "your user";

static const char kObserveMessage[] =
    "RV observe mode: daemon unavailable, so this call was allowed without being checked or logged. Run `rv doctor`.";

enum RvWhenDown rv_when_down_parse(const char *value) {
    if (value == NULL) {
        return RV_WHEN_DOWN_ASK;
    }
    if (strcmp(value, "deny") == 0) {
        return RV_WHEN_DOWN_DENY;
    }
    return RV_WHEN_DOWN_ASK;
}

static const struct RvFailureText *failure_text(enum RvHookFailure failure) {
    switch (failure) {
    case RV_HOOK_FAIL_INPUT:
        return &kInputText;
    case RV_HOOK_FAIL_UNREACHABLE:
        return &kUnreachableText;
    case RV_HOOK_FAIL_TIMEOUT:
        return &kTimeoutText;
    case RV_HOOK_FAIL_UNTRUSTED:
        return &kUntrustedText;
    case RV_HOOK_FAIL_PROTOCOL:
        return &kProtocolText;
    case RV_HOOK_FAIL_CONNECTION:
        return &kConnectionText;
    case RV_HOOK_FAIL_STOPPED:
        return &kStoppedText;
    }
    return &kProtocolText;
}

const char *rv_hook_failure_message(enum RvHookFailure failure) {
    return failure_text(failure)->why;
}

const char *rv_hook_failure_rule(enum RvHookFailure failure) {
    return failure_text(failure)->rule;
}

const char *rv_hook_failure_fix(enum RvHookFailure failure) {
    return failure_text(failure)->fix;
}

/* Uppercase first letter: ASCII A-Z or U+00C0..U+00DE except U+00D7. */
static int name_upper_at(const unsigned char *s, size_t n, size_t i, size_t *width) {
    if (s[i] >= 'A' && s[i] <= 'Z') {
        *width = 1;
        return 1;
    }
    if (s[i] == 0xC3 && i + 1 < n && s[i + 1] >= 0x80 && s[i + 1] <= 0x9E && s[i + 1] != 0x97) {
        *width = 2;
        return 1;
    }
    return 0;
}

/* A letter: ASCII, or U+00C0..U+024F except U+00D7 and U+00F7 (2-byte
 * UTF-8, lead C3..C9). Same set as `OwnerName` in RVDomain. */
static int name_letter_at(const unsigned char *s, size_t n, size_t i, size_t *width) {
    unsigned int cp;
    if ((s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= 'a' && s[i] <= 'z')) {
        *width = 1;
        return 1;
    }
    if (s[i] < 0xC3 || s[i] > 0xC9 || i + 1 >= n || (s[i + 1] & 0xC0) != 0x80) {
        return 0;
    }
    cp = ((unsigned int)(s[i] & 0x1F) << 6) | (unsigned int)(s[i + 1] & 0x3F);
    if (cp < 0xC0 || cp > 0x24F || cp == 0xD7 || cp == 0xF7) {
        return 0;
    }
    *width = 2;
    return 1;
}

int rv_owner_first_name(const char *gecos, char *out, size_t cap) {
    const unsigned char *s;
    size_t start = 0;
    size_t end;
    size_t i;
    size_t width = 0;
    int joiner = 0;
    if (out == NULL || cap == 0) {
        return -1;
    }
    out[0] = '\0';
    if (gecos == NULL) {
        return -1;
    }
    s = (const unsigned char *)gecos;
    while (s[start] == ' ') {
        start++;
    }
    end = start;
    while (s[end] != '\0' && s[end] != ',' && s[end] != ' ') {
        end++;
    }
    if (end == start || end - start > RV_OWNER_NAME_MAX || end - start >= cap) {
        return -1;
    }
    if (!name_upper_at(s, end, start, &width)) {
        return -1;
    }
    for (i = start; i < end; i += width) {
        if (s[i] == '-' || s[i] == '\'') {
            if (joiner) {
                return -1;
            }
            joiner = 1;
            width = 1;
            continue;
        }
        if (!name_letter_at(s, end, i, &width)) {
            return -1;
        }
        joiner = 0;
    }
    if (joiner) {
        return -1;
    }
    memcpy(out, s + start, end - start);
    out[end - start] = '\0';
    return 0;
}

int rv_hook_stop_text(enum RvHookFailure failure, const char *owner, char *out, size_t cap) {
    const struct RvFailureText *text = failure_text(failure);
    char name[RV_OWNER_NAME_MAX + 1];
    int n;
    if (out == NULL || cap == 0) {
        return -1;
    }
    /* Only a name the shared rule accepts is printed. */
    if (owner == NULL || rv_owner_first_name(owner, name, sizeof name) != 0 || strcmp(name, owner) != 0) {
        snprintf(name, sizeof name, "%s", kOwnerFallback);
    }
    n = snprintf(out, cap, "\xE2\x9C\x95 Stopped   (%s)\nwhy     %s\nwho     ask %s to run  %s",
                 text->rule, text->why, name, text->fix);
    return n >= 0 && (size_t)n < cap ? 0 : -1;
}

static int fits(int n, size_t cap) {
    return n >= 0 && (size_t)n < cap;
}

/* Host deny shape and exit code (unchanged from the pre-classification
 * deny_hook): Codex block + stderr + exit 2; Claude / Cursor native deny,
 * exit 0; leftover `decision: deny` exits 0 for Grok / Antigravity, else 1.
 * `msg` is the JSON-escaped stop text, `plain` the same text unescaped
 * (Codex stderr). Cursor's agent reads the same stop as its user. */
static int render_deny(const char *host, const char *msg, const char *plain, struct RvHookFallback *out) {
    int n;
    if (strcmp(host, "codex") == 0) {
        n = snprintf(out->out, sizeof out->out,
                     "{\"decision\":\"block\",\"reason\":\"%s\"}\n", msg);
        if (!fits(n, sizeof out->out)) {
            return -1;
        }
        n = snprintf(out->err, sizeof out->err, "%s\n", plain);
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
                     msg, msg);
    } else if (strcmp(host, "muse") == 0) {
        /* MuseHostCodec: `decision: block` is rejected on this event. */
        n = snprintf(out->out, sizeof out->out,
                     "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
                     "\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"%s\"}}\n",
                     msg);
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

/* The host's own allow wire (HostCodec.encodeAllow): Cursor and
 * Antigravity need explicit allow JSON; every other host allows on empty
 * stdout and exit 0. The notice goes to stderr, never into host JSON. */
static int render_observe(const char *host, struct RvHookFallback *out) {
    int n;
    const char *allow = "";
    if (strcmp(host, "cursor") == 0) {
        allow = "{\"permission\":\"allow\"}\n";
    } else if (strcmp(host, "antigravity") == 0) {
        allow = "{\"decision\":\"allow\"}\n";
    }
    n = snprintf(out->out, sizeof out->out, "%s", allow);
    if (!fits(n, sizeof out->out)) {
        return -1;
    }
    n = snprintf(out->err, sizeof out->err, "%s\n", kObserveMessage);
    return fits(n, sizeof out->err) ? 0 : -1;
}

int rv_hook_fallback_render(
    const char *host,
    enum RvHookFailure failure,
    enum RvWhenDown mode,
    struct RvHookFallback *out
) {
    return rv_hook_fallback_render_for(host, failure, mode, NULL, out);
}

int rv_hook_fallback_render_for(
    const char *host,
    enum RvHookFailure failure,
    enum RvWhenDown mode,
    const char *owner,
    struct RvHookFallback *out
) {
    char plain[RV_HOOK_STOP_TEXT_MAX];
    char msg[2 * RV_HOOK_STOP_TEXT_MAX];
    size_t msg_len = 0;
    if (host == NULL || out == NULL) {
        return -1;
    }
    out->out[0] = '\0';
    out->err[0] = '\0';
    out->exit_code = 0;
    if (rv_hook_stop_text(failure, owner, plain, sizeof plain) != 0
        || rv_json_escape((const unsigned char *)plain, strlen(plain), msg, sizeof msg, &msg_len) != 0) {
        return -1;
    }
    /* Only an absent, slow or dropped daemon is configurable. Malformed
     * input, a daemon that fails identity verification (possible
     * impersonation) and a malformed reply always deny. */
    if (failure != RV_HOOK_FAIL_UNREACHABLE && failure != RV_HOOK_FAIL_TIMEOUT
        && failure != RV_HOOK_FAIL_CONNECTION && failure != RV_HOOK_FAIL_STOPPED) {
        return render_deny(host, msg, plain, out);
    }
    /* Observe steps aside only for a daemon positively absent before the
     * request was sent: a slow or dropped one may be live and would have
     * applied rv's self-protection, and an agent can cause either. */
    if (mode == RV_WHEN_DOWN_OBSERVE && failure == RV_HOOK_FAIL_UNREACHABLE) {
        return render_observe(host, out);
    }
    switch (mode) {
    case RV_WHEN_DOWN_DENY:
        return render_deny(host, msg, plain, out);
    case RV_WHEN_DOWN_ASK:
    default: {
        int asked = render_ask(host, msg, out);
        if (asked != 0) {
            return asked > 0 ? 0 : -1;
        }
        return render_deny(host, msg, plain, out);
    }
    }
}
