/*
 * Linux trampoline: apply first-slice Landlock in *this* process, then exec.
 * IsolationBackends.apply / run must never Landlock the caller — that is why
 * this helper exists (fork-from-Swift is unsafe).
 *
 * Argv lock: rv-isolation-exec --workspace RESOLVED -- INNER...
 * Apply failure or bad argv exits 125 and does not exec.
 * Successful apply then failed execve exits 126 and does not claim
 * the inner ran.
 *
 * Second form, for `rv run` (no Landlock):
 *   rv-isolation-exec --stopped FLOOR -- EXECUTABLE ARGV0 [ARG...]
 * closes every descriptor from FLOOR up, stops itself with SIGSTOP and,
 * once continued, execs EXECUTABLE with the arguments after it. glibc has
 * no spawn that starts a process stopped; this is that. rv binds its
 * placeholders to this process while it is stopped, and pid, process
 * group and start time survive exec, so what it bound is the command.
 * Bad argv or descriptors that cannot be closed exit 125 before the stop;
 * a failed execve says why on stderr and exits 126.
 *
 * SwiftPM cannot compile C into the RVIsolation Swift target, so this
 * translation unit includes the shim from Sources/RVIsolation.
 */
#include "rv_landlock_apply.h"

#include "../RVIsolation/landlock_apply.c"

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef RV_ISOLATION_EXEC_ESTABLISH_FAILED
#define RV_ISOLATION_EXEC_ESTABLISH_FAILED 125
#endif
#ifndef RV_ISOLATION_EXEC_EXEC_FAILED
#define RV_ISOLATION_EXEC_EXEC_FAILED 126
#endif

extern char **environ;

/* FLOOR: decimal digits only, 3 or more (stdio is never closed here). */
static int rv_parse_floor(const char *text, unsigned int *floor) {
    unsigned long value = 0;
    const char *digit = text;
    if (*digit == '\0') {
        return -1;
    }
    for (; *digit != '\0'; digit++) {
        if (*digit < '0' || *digit > '9') {
            return -1;
        }
        value = value * 10 + (unsigned long)(*digit - '0');
        if (value > INT_MAX) {
            return -1;
        }
    }
    if (value < 3) {
        return -1;
    }
    *floor = (unsigned int)value;
    return 0;
}

static int rv_run_stopped(int argc, char **argv) {
    unsigned int floor;
    int failure;

    if (argc < 6 || rv_parse_floor(argv[2], &floor) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (strcmp(argv[3], "--") != 0 || argv[4][0] != '/') {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    /* Everything rv had open that is not close-on-exec is still open here.
     * None of it may reach the command; a kernel without close_range
     * (before 5.9) or a filter that refuses it must not run the command. */
    if (syscall(SYS_close_range, floor, UINT_MAX, 0u) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (raise(SIGSTOP) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    execve(argv[4], &argv[5], environ);
    failure = errno;
    dprintf(STDERR_FILENO, "rv run: could not start the command: %s\n", strerror(failure));
    return RV_ISOLATION_EXEC_EXEC_FAILED;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--stopped") == 0) {
        return rv_run_stopped(argc, argv);
    }
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
    /* Landlock cannot revoke access through descriptors opened beforehand.
     * Only the deliberately supplied stdio descriptors survive the boundary.
     * A blocked or unsupported close_range must not run the inner command. */
    if (syscall(SYS_close_range, 3u, UINT_MAX, 0u) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (rv_landlock_restrict_self_to_workspace(argv[2]) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    execve(argv[4], &argv[4], environ);
    return RV_ISOLATION_EXEC_EXEC_FAILED;
}
