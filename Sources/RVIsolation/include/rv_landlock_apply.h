#ifndef RV_LANDLOCK_APPLY_H
#define RV_LANDLOCK_APPLY_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * First-slice Landlock apply. Invoked only by rv-isolation-exec in that
 * process. IsolationBackends.apply / run must never call this —
 * landlock_restrict_self would jail the caller (tests, later rvd).
 * Fork-from-Swift is unsafe; this exists so restrict_self + exec happen
 * in a fresh helper, the way Darwin uses /usr/bin/sandbox-exec.
 *
 * Returns 0 after NO_NEW_PRIVS + ABI ≥ 2 + restrict_self. Nonzero means
 * the trampoline must exit 125 and must not exec.
 */
int rv_landlock_restrict_self_to_workspace(const char *workspace);

#ifdef __cplusplus
}
#endif

#endif
