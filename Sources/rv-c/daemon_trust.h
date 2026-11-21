#ifndef RV_DAEMON_TRUST_H
#define RV_DAEMON_TRUST_H

/*
 * Daemon-identity verification for the C hook front door. Mirrors the Swift
 * client's checks (`XPCEvaluateClient` + `MacOSPeerCodeVerifier` +
 * `ProtectedPeerTrustConfiguration`):
 *
 * - Darwin: every XPC reply's sender is verified before any field is
 *   consumed. An installed root-owned trust manifest requires the
 *   `.service` role. With no manifest (one-click install) the daemon must
 *   be the exact sibling `rvd` bytes (canonical path + CDHash). A manifest
 *   that exists but fails validation fails closed. Entries whose role this
 *   build does not know (written by a newer RV) are skipped, not fatal;
 *   known roles keep every check.
 * - Linux: the connected AF_UNIX peer must be same-uid (`SO_PEERCRED`) and
 *   its `/proc/<pid>/exe` must be the sibling `rvd`.
 *
 * Every failure returns 0; callers never consume the reply and report the
 * `untrusted` failure class (hook_fallback.h).
 *
 * The hook-local evaluator (local_eval.h) is pinned the same way, as a
 * child the hook spawned rather than a peer: it must run from the
 * canonical sibling path, and on Darwin its live code must be the exact
 * on-disk sibling bytes (no manifest), or the Developer ID signed
 * `dev.rv.rv-hook-local` of the team the manifest pins rvd to.
 */

#include <sys/types.h>

#define RV_EVALUATOR_NAME "rv-hook-local"
#define RV_EVALUATOR_IDENTIFIER "dev.rv.rv-hook-local"

/* 1 when the running, unreaped child `pid`, spawned from `path`, is the
 * trusted sibling `rv-hook-local`, else 0. */
int rv_verify_local_evaluator(pid_t pid, const char *path);

#ifdef __APPLE__
#include <xpc/xpc.h>

/* 1 when `reply` was sent by the trusted `rvd`, else 0. */
int rv_verify_daemon_reply(xpc_object_t reply);
#else
/* 1 when the connected peer on `fd` is the sibling `rvd`, else 0. */
int rv_verify_unix_daemon(int fd);
#endif

#endif
