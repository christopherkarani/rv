/*
 * Linux trampoline: apply first-slice Landlock in *this* process, then exec.
 * IsolationBackends.apply / run must never Landlock the caller — that is why
 * this helper exists (fork-from-Swift is unsafe).
 *
 * Argv lock: rv-isolation-exec --workspace RESOLVED -- INNER...
 * Core dumps are disabled before exec (soft and hard RLIMIT_CORE = 0):
 * a core file can hold injected secrets or gateway placeholders. This
 * mirrors rv-pty-claim on Darwin; the configurable caps stay Darwin-only
 * because Linux contained launch still refuses before exec.
 * Apply failure or bad argv exits 125 and does not exec.
 * Successful apply then failed execve exits 126 and does not claim
 * the inner ran.
 *
 * Second form, for `rv run` (no Landlock):
 *   rv-isolation-exec --stopped FLOOR PARENT -- EXECUTABLE ARGV0 [ARG...]
 * closes every descriptor from FLOOR up, stops itself with SIGSTOP and,
 * once continued, execs EXECUTABLE with the arguments after it. PARENT is
 * the pid of the rv that started it. glibc has
 * no spawn that starts a process stopped; this is that. rv binds its
 * placeholders to this process while it is stopped, and pid, process
 * group and start time survive exec, so what it bound is the command.
 * Bad argv or descriptors that cannot be closed exit 125 before the stop,
 * as does a parent that is not PARENT before or after it (rv is gone); a
 * failed execve says why on stderr and exits 126.
 *
 * Third form, for an MCP server (Sources/RVIsolation/landlock_confine.c):
 *   rv-isolation-exec --confine FLOOR [--read PATH]... [--write PATH]...
 *                     [--temp PATH]... [--tcp PORT]
 *                     -- EXECUTABLE ARGV0 [ARG...]
 * closes inherited descriptors, sets NO_NEW_PRIVS, applies the Landlock
 * ruleset the request describes, installs the socket filter
 * (Sources/RVIsolation/socket_filter.c) and execs. Anything that fails
 * exits 125 with a line on stderr and does not exec. A request with a
 * port (--tcp) does that in a child and stays as the child's connector
 * (Sources/RVIsolation/proxy_connector.c).
 *
 *   rv-isolation-exec --landlock-abi
 * prints the kernel's Landlock ABI (0 when it has none), followed by
 * " no-socket-filter" on a kernel without seccomp filters, and exits 0.
 *
 * SwiftPM cannot compile C into the RVIsolation Swift target, so this
 * translation unit includes the shim from Sources/RVIsolation.
 */
#include "rv_landlock_apply.h"

#include "../RVIsolation/landlock_apply.c"
#include "../RVIsolation/landlock_confine.c"
#include "../RVIsolation/socket_filter.c"
#include "../RVIsolation/proxy_connector.c"

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <string.h>
#include <unistd.h>

#ifndef RV_ISOLATION_EXEC_ESTABLISH_FAILED
#define RV_ISOLATION_EXEC_ESTABLISH_FAILED 125
#endif
#ifndef RV_ISOLATION_EXEC_EXEC_FAILED
#define RV_ISOLATION_EXEC_EXEC_FAILED 126
#endif

extern char **environ;

/* Decimal digits only, from `least` to INT_MAX. FLOOR is 3 or more: stdio
 * is never closed here. */
static int rv_parse_number(const char *text, unsigned long least, unsigned int *number) {
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
    if (value < least) {
        return -1;
    }
    *number = (unsigned int)value;
    return 0;
}

static int rv_run_stopped(int argc, char **argv) {
    unsigned int floor;
    unsigned int parent;
    int failure;

    /* PARENT: any pid. rv is pid 1 or 2 when it is a container's entry point. */
    if (argc < 7 || rv_parse_number(argv[2], 3, &floor) != 0 || rv_parse_number(argv[3], 1, &parent) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (strcmp(argv[4], "--") != 0 || argv[5][0] != '/') {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    /* Everything rv had open that is not close-on-exec is still open here.
     * None of it may reach the command; a kernel without close_range
     * (before 5.9) or a filter that refuses it must not run the command. */
    if (syscall(SYS_close_range, floor, UINT_MAX, 0u) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    /* The rv that started this must still be the parent, or nobody will
     * wait for the stop: stopping would leave this (and rv's stdio) held
     * forever, for any later SIGCONT to run the command. */
    if ((unsigned int)getppid() != parent) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (raise(SIGSTOP) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    /* Continued by someone other than the rv that started this: rv died
     * while this was stopped, so nothing bound the command and nothing
     * will serve it. (The kernel continues a stopped group that its
     * parent's death orphans; where the new parent shares the session it
     * does not, and this stays stopped until someone continues it.) */
    if ((unsigned int)getppid() != parent) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    execve(argv[5], &argv[6], environ);
    failure = errno;
    dprintf(STDERR_FILENO, "rv run: could not start the command: %s\n", strerror(failure));
    return RV_ISOLATION_EXEC_EXEC_FAILED;
}

/* In the process that becomes the server: the cage, then the server.
 * `channel` is the socket to the connector, or -1 when the request has
 * no port and so no connector. */
static int rv_start_confined(int argc, char **argv, int channel) {
    sigset_t none;
    char go = 0;
    int executable;
    int failure;
    int listener = -1;
    int abi = 0;
    int port = 0;

    executable = rv_landlock_confine(argc, argv, &abi, &port);
    if (executable < 0 || (port > 0) != (channel >= 0)) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    /* Plain TCP sockets only where a connector will connect them; Unix
     * sockets only where Landlock confines them (ABI 9). */
    if (rv_socket_filter_install(port > 0, abi >= 9, &listener) != 0) {
        dprintf(STDERR_FILENO, "rv mcp: the server was not started: the socket filter could not be installed: %s\n",
            strerror(errno));
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (channel >= 0) {
        /* The connector gets the filter's listener, and says when it is
         * ready to answer. */
        if (rv_connector_send(channel, listener) != 0 || close(listener) != 0 || read(channel, &go, 1) != 1
            || go != 'g') {
            return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
        }
        close(channel);
    }
    /* The gateway starts servers from a thread that blocks most signals,
     * and a blocked SIGTERM would be one the server never hears. */
    sigemptyset(&none);
    if (sigprocmask(SIG_SETMASK, &none, NULL) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    execve(argv[executable], &argv[executable + 1], environ);
    failure = errno;
    dprintf(STDERR_FILENO, "rv mcp: the server was not started: %s: %s\n", argv[executable], strerror(failure));
    return RV_ISOLATION_EXEC_EXEC_FAILED;
}

/* A cage with a port: the server is this process's child, and this
 * process stays outside the cage as its connector (proxy_connector.c). */
static int rv_run_connected(int argc, char **argv, unsigned short port) {
    sigset_t relayed;
    pid_t self = getpid();
    pid_t server;
    int channel[2];
    int listener;
    int status;
    int null;

    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, channel) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    /* Blocked before the server exists, so that its exit and a signal
     * meant for it are never missed; the server unblocks its own. */
    rv_connector_signals(&relayed);
    if (sigprocmask(SIG_BLOCK, &relayed, NULL) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    server = fork();
    if (server < 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (server == 0) {
        close(channel[0]);
        /* A server must not outlive the process the gateway holds. */
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != self) {
            _exit(RV_ISOLATION_EXEC_ESTABLISH_FAILED);
        }
        _exit(rv_start_confined(argc, argv, channel[1]));
    }
    close(channel[1]);
    listener = rv_connector_receive(channel[0]);
    if (listener < 0) {
        /* The cage was not established; the child said why. */
        kill(server, SIGKILL);
        waitpid(server, &status, 0);
        return WIFEXITED(status) ? WEXITSTATUS(status) : RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (!rv_connector_can_serve(server)) {
        dprintf(STDERR_FILENO,
            "rv mcp: the server was not started: this host does not let rv connect a caged server to its allowlist "
            "proxy (reading the server's sockets: %s). It needs /proc and kernel.yama.ptrace_scope 0 or 1\n",
            strerror(errno));
        kill(server, SIGKILL);
        waitpid(server, &status, 0);
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    /* The server's input and output are its own; this keeps stderr. */
    null = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null < 0 || dup2(null, STDIN_FILENO) < 0 || dup2(null, STDOUT_FILENO) < 0
        || send(channel[0], "g", 1, MSG_NOSIGNAL) != 1) {
        kill(server, SIGKILL);
        waitpid(server, &status, 0);
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    close(null);
    close(channel[0]);
    return rv_connector_serve(listener, server, port);
}

static int rv_run_confined(int argc, char **argv) {
    int port;

    /* Landlock does not revoke descriptors opened before it. */
    if (syscall(SYS_close_range, 3u, UINT_MAX, 0u) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    port = rv_landlock_confine_port(argc, argv);
    if (port > 0) {
        return rv_run_connected(argc, argv, (unsigned short)port);
    }
    /* A malformed request too: rv_landlock_confine says what is wrong. */
    return rv_start_confined(argc, argv, -1);
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--stopped") == 0) {
        return rv_run_stopped(argc, argv);
    }
    if (argc >= 2 && strcmp(argv[1], "--confine") == 0) {
        return rv_run_confined(argc, argv);
    }
    if (argc == 2 && strcmp(argv[1], "--landlock-abi") == 0) {
        /* The cage needs both; a kernel without seccomp filters says so. */
        printf(rv_socket_filter_available() ? "%d\n" : "%d no-socket-filter\n", rv_landlock_abi());
        return 0;
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
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    if (rv_landlock_restrict_self_to_workspace(argv[2]) != 0) {
        return RV_ISOLATION_EXEC_ESTABLISH_FAILED;
    }
    execve(argv[4], &argv[4], environ);
    return RV_ISOLATION_EXEC_EXEC_FAILED;
}
