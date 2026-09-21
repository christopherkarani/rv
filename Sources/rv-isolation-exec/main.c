/*
 * Linux trampoline: apply first-slice Landlock in *this* process, then exec.
 * IsolationBackends.apply / run must never Landlock the caller — that is why
 * this helper exists (fork-from-Swift is unsafe).
 *
 * Argv lock: rv-isolation-exec --workspace RESOLVED -- INNER...
 * Apply failure or bad argv exits 125 and does not exec.
 *
 * SwiftPM cannot compile C into the RVIsolation Swift target, so this
 * translation unit includes the shim from Sources/RVIsolation.
 */
#include "rv_landlock_apply.h"

#include "../RVIsolation/landlock_apply.c"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef RV_ISOLATION_EXEC_ESTABLISH_FAILED
#define RV_ISOLATION_EXEC_ESTABLISH_FAILED 125
#endif

extern char **environ;

int main(int argc, char **argv) {
    if (argc < 5) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (strcmp(argv[1], "--workspace") != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (argv[2] == NULL || argv[2][0] != '/') {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (strcmp(argv[3], "--") != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (argv[4] == NULL || argv[4][0] != '/') {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (rv_landlock_restrict_self_to_workspace(argv[2]) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    execve(argv[4], &argv[4], environ);
    return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
}
