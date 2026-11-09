#ifndef RV_OBSERVE_GATE_H
#define RV_OBSERVE_GATE_H

/*
 * Whether a hook that got no verdict from an absent or slow rvd may step
 * aside because the owner chose observe mode. rvd normally decides observe
 * itself; this is only consulted on the UNREACHABLE / TIMEOUT fallback.
 *
 * Inputs are paths the caller derives without the environment: rv.c uses
 * the passwd home (never $HOME or XDG vars) and the fixed organization
 * policy directory. RV_GUARD_MODE is deliberately ignored: an agent can set
 * hook environment through project-scoped host config.
 *
 * 1 only when all hold, otherwise 0 (fail closed to the normal fallback):
 *   - managed_dir does not exist (lstat ENOENT). An organization bundle,
 *     valid or not, can pin enforce and only rvd can verify it.
 *   - config_path is a regular file (no symlink), owned by the calling
 *     uid, not group- or world-writable, at most RV_OBSERVE_CONFIG_MAX bytes.
 *   - rv_guard_config_observes(contents, host) is 1.
 */

#define RV_OBSERVE_CONFIG_MAX (1024 * 1024)

int rv_observe_gate_applies(const char *config_path, const char *managed_dir, const char *host);

#endif
