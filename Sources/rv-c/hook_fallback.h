#ifndef RV_HOOK_FALLBACK_H
#define RV_HOOK_FALLBACK_H

/*
 * What the C hook prints when it cannot get a verdict from rvd. Pure:
 * no I/O, no environment reads; rv.c passes getenv(RV_HOOK_WHEN_DOWN_ENV)
 * through rv_when_down_parse and writes the rendered bytes itself.
 *
 * - INPUT (unreadable / oversized / NUL / invalid UTF-8 stdin, request
 *   build failure), UNTRUSTED (daemon identity verification failed or
 *   HelloAck refused) and PROTOCOL (malformed reply): always the host's
 *   deny shape and deny exit code. Impersonation must never soften.
 * - UNREACHABLE / TIMEOUT (daemon absent or slow): RV_HOOK_WHEN_DOWN
 *   selects the rendering.
 *     ask (default, also any value but "deny"): Claude and Cursor get
 *       their native ask wire (exit 0) so the human decides in the host;
 *       hosts without an ask primitive get their deny shape.
 *     deny: the host's deny shape.
 *   There is deliberately no allow/bypass value: the variable can reach
 *   the hook from project-scoped host config an agent can write.
 *   RV_WHEN_DOWN_OBSERVE (the host's allow wire, plus a stderr notice) is
 *   never parsed from the environment: rv.c selects it only when the
 *   owner's config.json puts the host in observe mode (observe_gate.h).
 *   It applies to UNREACHABLE only; TIMEOUT under it renders as ask,
 *   because a live but slow rvd would have enforced rv's self-protection
 *   and an agent can make rvd slow.
 * Every case carries a distinct, actionable message. Mirrored by
 * `RVCLI/Service/HookDaemonFallback.swift`.
 */

#define RV_HOOK_WHEN_DOWN_ENV "RV_HOOK_WHEN_DOWN"

enum RvHookFailure {
    RV_HOOK_FAIL_INPUT = 1,
    RV_HOOK_FAIL_UNREACHABLE = 2,
    RV_HOOK_FAIL_TIMEOUT = 3,
    RV_HOOK_FAIL_UNTRUSTED = 4,
    RV_HOOK_FAIL_PROTOCOL = 5
};

enum RvWhenDown {
    RV_WHEN_DOWN_ASK = 0,
    RV_WHEN_DOWN_DENY = 1,
    RV_WHEN_DOWN_OBSERVE = 2
};

#define RV_HOOK_FALLBACK_OUT_MAX 1024
#define RV_HOOK_FALLBACK_ERR_MAX 512

struct RvHookFallback {
    char out[RV_HOOK_FALLBACK_OUT_MAX];
    char err[RV_HOOK_FALLBACK_ERR_MAX];
    int exit_code;
};

/* Exactly "deny" is deny; NULL, empty, or anything else is ask. */
enum RvWhenDown rv_when_down_parse(const char *value);

/* Constant, JSON-safe sentence for the failure class (never NULL). */
const char *rv_hook_failure_message(enum RvHookFailure failure);

/* Fills `out` (stdout text, stderr text, exit code). 0 on success, -1 on
 * a NULL argument or a buffer overflow (callers then fail closed). */
int rv_hook_fallback_render(
    const char *host,
    enum RvHookFailure failure,
    enum RvWhenDown mode,
    struct RvHookFallback *out
);

#endif
