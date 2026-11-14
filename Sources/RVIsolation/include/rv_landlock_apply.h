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
 * Returns 0 after NO_NEW_PRIVS + ABI ≥ 3 + restrict_self. Nonzero means
 * the trampoline must exit 125 and must not exec. ABI 2 is fail-closed
 * because it cannot handle TRUNCATE (truncate(2) / O_TRUNC would stay
 * allowed outside the workspace).
 *
 * Phase 6 handles read+write FS bits beneath the workspace. The system
 * read-only layer, EXECUTE, network, and process controls are still not
 * installed, so Swift refuses contained before exec and this entry point
 * stays unreachable from production launch.
 */
int rv_landlock_restrict_self_to_workspace(const char *workspace);

/*
 * MCP server confinement (landlock_confine.c). Applies the ruleset argv
 * describes to this process and returns the index of the executable to
 * exec, or -1 after printing why nothing was applied. On success it also
 * reports the Landlock ABI applied and the loopback TCP port the cage's
 * connector may connect it to (0 for none), which decide the socket
 * filter that follows.
 */
int rv_landlock_confine(int argc, char **argv, int *kernel_abi, int *tcp_port);

/* Whether the request names such a port: 1, 0, or -1 when malformed. */
int rv_landlock_confine_has_port(int argc, char **argv);

/* The running kernel's Landlock ABI; 0 when it has none. */
int rv_landlock_abi(void);

#ifdef __cplusplus
}
#endif

#endif
