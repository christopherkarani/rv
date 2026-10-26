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
 *   that exists but fails validation fails closed.
 * - Linux: the connected AF_UNIX peer must be same-uid (`SO_PEERCRED`) and
 *   its `/proc/<pid>/exe` must be the sibling `rvd`.
 *
 * Every failure returns 0; callers fail closed to an explicit denial.
 */

#ifdef __APPLE__
#include <xpc/xpc.h>

/* 1 when `reply` was sent by the trusted `rvd`, else 0. */
int rv_verify_daemon_reply(xpc_object_t reply);
#else
/* 1 when the connected peer on `fd` is the sibling `rvd`, else 0. */
int rv_verify_unix_daemon(int fd);
#endif

#endif
