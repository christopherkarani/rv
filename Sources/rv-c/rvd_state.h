#ifndef RV_RVD_STATE_H
#define RV_RVD_STATE_H

/*
 * The rvd state marker (`~/.config/rv/rvd-state`): whether rvd ever ran on
 * this account, and whether its absence right now was announced.
 *
 * Observe mode lets a hook step aside when rvd is unreachable, so that a
 * fresh install or an upgrade does not block the agent. Without this marker
 * that also let an agent bypass rv by stopping rvd (`launchctl bootout`,
 * `systemctl --user stop`, deleting the socket) or crashing it. The marker
 * narrows the step-aside to the cases that are not an attack:
 *
 *   absent              rvd never ran here (fresh install): step aside.
 *   "restarting <t>\n"  rv announced a restart (rv setup, rv service
 *                       restart, rvd exiting for an upgraded binary) and
 *                       `now <= t <= now + RV_RVD_STATE_RESTART_WINDOW_S`:
 *                       step aside.
 *   "armed\n"           rvd ran and no restart was announced: it was
 *                       stopped or crashed. Fail closed.
 *   anything else       expired or far-future restart, any other content,
 *                       a symlink, not a regular file, another owner,
 *                       group/world-writable, over RV_RVD_STATE_MAX bytes,
 *                       unreadable: fail closed.
 *
 * Writers (Swift, `RVDStateMarker`): rvd writes "armed" at startup and on
 * its stale-check tick (leaving a pending restart alone), and
 * "restarting" once it sees its binary replaced; `rv setup` and
 * `rv service restart` write "restarting" before they bounce rvd;
 * `rv uninstall` removes it. A stop or crash writes nothing.
 *
 * The marker can only take away the observe step-aside, never grant
 * anything: rv.c consults it only where observe would already allow.
 * Mirrored by `HookObserveFallback` in RVCLI.
 */

#include <stddef.h>

#define RV_RVD_STATE_MAX 64
#define RV_RVD_STATE_RESTART_WINDOW_S 120

enum RvRvdState {
    RV_RVD_STATE_ABSENT = 0,
    RV_RVD_STATE_RESTARTING = 1,
    RV_RVD_STATE_ARMED = 2,
    RV_RVD_STATE_RESTART_EXPIRED = 3,
    RV_RVD_STATE_INVALID = 4
};

/* Classifies marker contents (`len` bytes, need not be NUL-terminated)
 * at wall-clock `now` (seconds since the epoch). Never ABSENT. */
enum RvRvdState rv_rvd_state_parse(const char *buf, size_t len, long long now);

/* Reads and classifies the marker at `path`. ABSENT only when open fails
 * with ENOENT; every other failure is INVALID. */
enum RvRvdState rv_rvd_state_read(const char *path, long long now);

/* 1 for ABSENT and RESTARTING (observe may step aside), else 0. */
int rv_rvd_state_allows_observe(enum RvRvdState state);

#endif
