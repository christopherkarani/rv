#ifndef RV_LOCAL_EVAL_H
#define RV_LOCAL_EVAL_H

#include <stddef.h>
#include <sys/types.h>

/*
 * The hook-local door (docs/architecture/hook-local-decide.md). Before it
 * asks rvd, the C hook may run the sibling `rv-hook-local`, which decides
 * a call only when rvd could give no other answer and otherwise says
 * "escalate". This module spawns it and reads its one answer.
 *
 * Only RV_LOCAL_FINAL carries a reply, and only when every step held: the
 * evaluator was spawned, passed `verify` before it read a byte (Darwin
 * starts it suspended until then), answered within the deadline, exited 0,
 * and printed exactly the final tag line followed by a reply body. Every
 * other outcome (missing, untrusted, crashed, hung, killed, malformed, or
 * an explicit escalate) is RV_LOCAL_ESCALATE, and the caller then takes
 * rvd's path exactly as if this door did not exist. A local failure never
 * becomes an answer.
 *
 * The evaluator gets a fixed environment (HOME, USER and LOGNAME from the
 * passwd entry, a system PATH, nothing else), cwd "/", stdin from a pipe,
 * stdout to a pipe and stderr to /dev/null: nothing an agent can set in
 * the hook's environment reaches it.
 */

/* From spawn to exit. A cold evaluation measures ~40 ms; past this the
 * call goes to rvd, which still has its whole budget (rv.c send cutoff). */
#define RV_LOCAL_DEADLINE_MS 1000
#define RV_LOCAL_OUTPUT_MAX (2 * 1024 * 1024)
#define RV_LOCAL_FINAL_TAG "rv-hook-local/1 final\n"
#define RV_LOCAL_ESCALATE_TAG "rv-hook-local/1 escalate "

enum RvLocalVerdict {
    RV_LOCAL_ESCALATE = 0,
    RV_LOCAL_FINAL = 1
};

/* 1 when the running child `pid`, spawned from `path`, is the trusted
 * evaluator. Called before the child has read anything. */
typedef int (*RvLocalVerify)(pid_t pid, const char *path);

/* Splits evaluator output. FINAL sets *body / *body_len to the reply body
 * (a view into `out`); ESCALATE copies the escalate reason (or a local
 * cause such as "protocol") into `reason`. Pure. */
enum RvLocalVerdict rv_local_parse_output(
    const char *out,
    size_t out_len,
    const char **body,
    size_t *body_len,
    char *reason,
    size_t reason_cap
);

/* Runs the evaluator at `path` for one hook call. On FINAL, *reply_json is
 * a malloc'd NUL-terminated reply body the caller frees. `home`, `user`
 * name the passwd entry; NULL `home` escalates without spawning. `reason`
 * receives why it escalated (diagnostics only). */
enum RvLocalVerdict rv_local_evaluate(
    const char *path,
    const char *host,
    const char *request_id,
    const char *home,
    const char *user,
    const unsigned char *stdin_bytes,
    size_t stdin_len,
    long deadline_ms,
    RvLocalVerify verify,
    char **reply_json,
    size_t *reply_len,
    char *reason,
    size_t reason_cap
);

#endif
