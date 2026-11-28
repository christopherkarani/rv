#ifndef RV_HOOK_FALLBACK_H
#define RV_HOOK_FALLBACK_H

#include <stddef.h>

/*
 * What the C hook prints when it cannot get a verdict from rvd. Pure:
 * no I/O, no environment reads; rv.c passes getenv(RV_HOOK_WHEN_DOWN_ENV)
 * through rv_when_down_parse and writes the rendered bytes itself.
 *
 * - INPUT (unreadable / oversized / NUL / invalid UTF-8 stdin, request
 *   build failure), UNTRUSTED (daemon identity verification failed or
 *   HelloAck refused) and PROTOCOL (malformed reply): always the host's
 *   deny shape and deny exit code. Impersonation must never soften.
 * - UNREACHABLE / TIMEOUT / CONNECTION (daemon absent, slow, or the
 *   connection failed in a way that does not prove rvd is absent):
 *   RV_HOOK_WHEN_DOWN selects the rendering.
 *     ask (default, also any value but "deny"): Claude and Cursor get
 *       their native ask wire (exit 0) so the human decides in the host;
 *       hosts without an ask primitive get their deny shape.
 *     deny: the host's deny shape.
 *   There is deliberately no allow/bypass value: the variable can reach
 *   the hook from project-scoped host config an agent can write.
 *   RV_WHEN_DOWN_OBSERVE (the host's allow wire, plus a stderr notice) is
 *   never parsed from the environment: rv.c selects it only when the
 *   owner's config.json puts the host in observe mode (observe_gate.h).
 *   It applies to UNREACHABLE only, which rv.c reports solely for a
 *   connect that fails before any request byte is sent: on Linux ENOENT or
 *   ECONNREFUSED on the uid-derived socket (/run/user/<uid>), on Darwin an
 *   invalid (unregistered) discovery connection. TIMEOUT and CONNECTION
 *   under it render as ask: a live but slow rvd would have enforced rv's
 *   self-protection, rvd drops in-flight requests while draining, an
 *   agent can cause either, and an agent can point XDG_RUNTIME_DIR at an
 *   empty directory through project-scoped host config.
 *   Even then rv.c steps aside only when the rvd state marker allows it
 *   (rvd_state.h); otherwise it reports STOPPED, which renders as ask/deny.
 * Every case carries a distinct, actionable message. Mirrored by
 * `RVCLI/Service/HookDaemonFallback.swift`.
 */

#define RV_HOOK_WHEN_DOWN_ENV "RV_HOOK_WHEN_DOWN"

enum RvHookFailure {
    RV_HOOK_FAIL_INPUT = 1,
    RV_HOOK_FAIL_UNREACHABLE = 2,
    RV_HOOK_FAIL_TIMEOUT = 3,
    RV_HOOK_FAIL_UNTRUSTED = 4,
    RV_HOOK_FAIL_PROTOCOL = 5,
    RV_HOOK_FAIL_CONNECTION = 6,
    /* UNREACHABLE under observe mode, but the rvd state marker
     * (rvd_state.h) says rvd ran and was stopped or crashed without an
     * announced restart: rendered like UNREACHABLE outside observe
     * (RV_HOOK_WHEN_DOWN ask/deny), never the observe allow. */
    RV_HOOK_FAIL_STOPPED = 7
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

/* Constant, JSON-safe `why` for the failure class, under ten words
 * (never NULL). */
const char *rv_hook_failure_message(enum RvHookFailure failure);

/* Constant rule id of the failure class (`rv.hook/unreachable`). */
const char *rv_hook_failure_rule(enum RvHookFailure failure);

/* Constant rv command the owner runs for the failure class (`rv doctor`). */
const char *rv_hook_failure_fix(enum RvHookFailure failure);

/* Longest first name printed, in bytes (`OwnerName.maxBytes`). */
#define RV_OWNER_NAME_MAX 32

/* Longest plain stop text. */
#define RV_HOOK_STOP_TEXT_MAX 256

/* The first word of `gecos`'s first comma field into `out` when it is a
 * plain name (`OwnerName` in RVDomain: 1-32 bytes, uppercase first
 * letter, ASCII or Latin-1/Latin Extended letters, `-` or `'` only between
 * letters). 0 on a name; -1 (and `out` empty) otherwise. Pure. */
int rv_owner_first_name(const char *gecos, char *out, size_t cap);

/* The plain stop text for `failure` (B1 shape, real newlines):
 * `✕ Stopped   (<rule>)`, `why     <why>`, `who     ask <owner> to run  <fix>`.
 * `owner` must already be a first name the rule accepts; NULL or anything
 * else says "your user". 0 on success, -1 when `cap` is too small. */
int rv_hook_stop_text(enum RvHookFailure failure, const char *owner, char *out, size_t cap);

/* Fills `out` (stdout text, stderr text, exit code). 0 on success, -1 on
 * a NULL argument or a buffer overflow (callers then fail closed). */
int rv_hook_fallback_render(
    const char *host,
    enum RvHookFailure failure,
    enum RvWhenDown mode,
    struct RvHookFallback *out
);

/* `rv_hook_fallback_render` with the owner's first name in the `who` line
 * (rv.c reads it from passwd, never the environment). NULL says "your user". */
int rv_hook_fallback_render_for(
    const char *host,
    enum RvHookFailure failure,
    enum RvWhenDown mode,
    const char *owner,
    struct RvHookFallback *out
);

#endif
