/*
 * Darwin pre-sandbox exec helper for a contained runtime's leader.
 *
 *   rv-pty-claim [--rlimit=NAME:VALUE]... [--deadline-seconds=N]
 *                [--rlimit-fault] SLAVE|- PAYLOAD [ARGS...]
 *
 * This image runs outside Seatbelt, as the process-group (or session)
 * leader rv just spawned, START_SUSPENDED. It does three things, then
 * execs the absolute PAYLOAD (sandbox-exec, or a test program). The pid
 * does not change, so the recorded process group stays the leader's.
 *
 * 1. Terminal claim (SLAVE is /dev/ttysN; "-" means no terminal).
 *    POSIX_SPAWN_SETSID made this process the session leader and cleared
 *    any controlling terminal. A slave opened by a posix_spawn file action
 *    is not the controlling terminal, and leaving that descriptor open
 *    makes TIOCSCTTY fail. This process closes the spawn-installed stdio,
 *    reopens the slave, calls TIOCSCTTY, and makes its own pid the
 *    foreground group. The temporary fd is closed before exec; stdin,
 *    stdout and stderr are the slave. The signal mask is restored so the
 *    payload does not inherit a blocked SIGTTIN or SIGTTOU.
 *
 * 2. Deadline watchdog (--deadline-seconds). A double-forked process in
 *    its own session, outside the runtime's group and outside Seatbelt,
 *    holds a kqueue on this leader's exit and a timer. At the deadline it
 *    SIGKILLs the whole group. When the leader exits first it SIGKILLs
 *    the group at once (leader death is session death, as in the host)
 *    and exits. It holds no descriptor of the runtime. It exists so the
 *    deadline holds when the workspace host that also enforces it dies;
 *    the host's deadline is earlier, so a live host records the timeout.
 *    The cage cannot signal it: the profile allows same-sandbox signals
 *    only. Exec does not happen until the watchdog reports it is armed.
 *
 * 3. Resource limits (--rlimit). NAME is core, nofile, fsize or cpu. Each
 *    only lowers: hard = min(VALUE, inherited hard), soft = min(inherited
 *    soft, new hard). Every limit is read back after it is set.
 *    --rlimit-fault is a test seam that asks the kernel for soft > hard,
 *    which it refuses, to prove that a refused limit stops the launch.
 *
 * Nothing is written to stdout. A failed claim or bad argv exits 127, a
 * watchdog or limit failure exits 125; neither execs, so no handshake
 * reaches rv and the launch fails closed.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define RV_CLAIM_FAILED 127
#define RV_LIMIT_FAILED 125
#define RV_MAX_LIMITS 4

struct rv_limit {
    int resource;
    const char *name;
    rlim_t cap;
};

static int is_slave_path(const char *path) {
    return path != NULL
        && strncmp(path, "/dev/", 5) == 0
        && strstr(path, "..") == NULL;
}

static int claim_controlling_terminal(const char *slave) {
    pid_t self = getpid();
    int opened;
    pid_t foreground = -1;
    if (self <= 1 || is_slave_path(slave) == 0) {
        return -1;
    }
    /*
     * Drop the descriptor posix_spawn already opened. TIOCSCTTY on a second
     * fd fails while that first slave fd is still open, and the parent then
     * cannot observe this pid as the foreground group.
     */
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    opened = open(slave, O_RDWR);
    if (opened < 0) {
        return -1;
    }
    /* EPERM means this open already made the slave our controlling terminal.
     * A terminal owned by another session fails the foreground check below. */
    if (ioctl(opened, TIOCSCTTY, 0) != 0 && errno != EPERM) {
        close(opened);
        return -1;
    }
    if (dup2(opened, STDIN_FILENO) < 0 || dup2(opened, STDOUT_FILENO) < 0
        || dup2(opened, STDERR_FILENO) < 0) {
        close(opened);
        return -1;
    }
    if (opened > STDERR_FILENO && close(opened) != 0) {
        return -1;
    }
    if (tcsetpgrp(STDIN_FILENO, self) != 0 && ioctl(STDIN_FILENO, TIOCSPGRP, &self) != 0) {
        return -1;
    }
    if (ioctl(STDIN_FILENO, TIOCGPGRP, &foreground) != 0 || foreground != self) {
        return -1;
    }
    return 0;
}

static int claim(const char *slave) {
    sigset_t blocked;
    sigset_t previous;
    int claimed;
    if (sigemptyset(&blocked) != 0 || sigaddset(&blocked, SIGTTIN) != 0
        || sigaddset(&blocked, SIGTTOU) != 0) {
        return -1;
    }
    if (sigprocmask(SIG_BLOCK, &blocked, &previous) != 0) {
        return -1;
    }
    claimed = claim_controlling_terminal(slave);
    if (sigprocmask(SIG_SETMASK, &previous, NULL) != 0) {
        return -1;
    }
    return claimed;
}

/* Decimal only, no sign, no leading '+', at most 20 digits, no overflow. */
static int parse_u64(const char *text, uint64_t *out) {
    uint64_t value = 0;
    size_t length = 0;
    if (text == NULL || text[0] == '\0') {
        return -1;
    }
    for (; text[length] != '\0'; length++) {
        unsigned digit;
        if (text[length] < '0' || text[length] > '9' || length >= 20) {
            return -1;
        }
        digit = (unsigned)(text[length] - '0');
        if (value > (UINT64_MAX - digit) / 10) {
            return -1;
        }
        value = value * 10 + digit;
    }
    *out = value;
    return 0;
}

static int parse_limit(const char *spec, struct rv_limit *out) {
    static const struct {
        const char *name;
        int resource;
    } known[] = {
        {"core", RLIMIT_CORE},
        {"nofile", RLIMIT_NOFILE},
        {"fsize", RLIMIT_FSIZE},
        {"cpu", RLIMIT_CPU},
    };
    const char *colon = strchr(spec, ':');
    uint64_t value;
    size_t index;
    if (colon == NULL || parse_u64(colon + 1, &value) != 0 || value >= RLIM_INFINITY) {
        return -1;
    }
    for (index = 0; index < sizeof(known) / sizeof(known[0]); index++) {
        size_t length = strlen(known[index].name);
        if ((size_t)(colon - spec) == length && strncmp(spec, known[index].name, length) == 0) {
            out->resource = known[index].resource;
            out->name = known[index].name;
            out->cap = (rlim_t)value;
            return 0;
        }
    }
    return -1;
}

static rlim_t lower(rlim_t left, rlim_t right) {
    return left < right ? left : right;
}

static int apply_limit(const struct rv_limit *limit) {
    struct rlimit inherited;
    struct rlimit wanted;
    struct rlimit applied;
    if (getrlimit(limit->resource, &inherited) != 0) {
        return -1;
    }
    wanted.rlim_max = lower(limit->cap, inherited.rlim_max);
    if (limit->resource == RLIMIT_NOFILE) {
        /* A NOFILE limit above kern.maxfilesperproc is refused or clamped
         * by the kernel, so never ask for more than it grants. */
        int per_process = 0;
        size_t size = sizeof(per_process);
        if (sysctlbyname("kern.maxfilesperproc", &per_process, &size, NULL, 0) != 0
            || per_process <= 0) {
            return -1;
        }
        wanted.rlim_max = lower(wanted.rlim_max, (rlim_t)per_process);
    }
    wanted.rlim_cur = lower(inherited.rlim_cur, wanted.rlim_max);
    if (setrlimit(limit->resource, &wanted) != 0) {
        return -1;
    }
    /* The kernel may clamp lower still; it must never be higher. */
    if (getrlimit(limit->resource, &applied) != 0
        || applied.rlim_max > wanted.rlim_max || applied.rlim_cur > wanted.rlim_cur) {
        return -1;
    }
    return 0;
}

/* Soft above hard: the kernel refuses it with EINVAL. */
static int apply_refused_limit(void) {
    struct rlimit inherited;
    struct rlimit refused;
    if (getrlimit(RLIMIT_NOFILE, &inherited) != 0 || inherited.rlim_max == 0) {
        return -1;
    }
    refused.rlim_max = inherited.rlim_max - 1;
    refused.rlim_cur = inherited.rlim_max;
    return setrlimit(RLIMIT_NOFILE, &refused);
}

static void close_every_descriptor_but(int keep) {
    int top = getdtablesize();
    int fd;
    for (fd = 0; fd < top; fd++) {
        if (fd != keep) {
            close(fd);
        }
    }
}

/* Runs in the detached watchdog. Never returns. */
static void watch_leader(pid_t leader, uint64_t seconds, int ready) {
    struct kevent changes[2];
    struct kevent fired;
    int queue = kqueue();
    if (queue < 0) {
        _exit(1);
    }
    EV_SET(&changes[0], (uintptr_t)leader, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    EV_SET(&changes[1], 1, EVFILT_TIMER, EV_ADD | EV_ONESHOT, NOTE_SECONDS, (intptr_t)seconds, NULL);
    if (kevent(queue, changes, 2, NULL, 0, NULL) != 0) {
        _exit(1);
    }
    if (write(ready, "1", 1) != 1) {
        _exit(1);
    }
    close_every_descriptor_but(queue);
    for (;;) {
        int count = kevent(queue, NULL, 0, &fired, 1, NULL);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        /* Deadline, leader exit, or a kqueue failure: each ends the group. */
        kill(-leader, SIGKILL);
        _exit(0);
    }
}

/*
 * Arms the watchdog for this leader. Returns 0 only after the watchdog
 * has registered both events. The intermediate child is reaped here, so
 * the watchdog belongs to launchd, not to the payload.
 */
static int start_deadline_watchdog(uint64_t seconds) {
    pid_t leader = getpid();
    int ready[2];
    pid_t intermediate;
    int status = 0;
    char byte = 0;
    ssize_t got;
    /* The watchdog signals the group named by this pid; a leader that does
     * not lead its own group would leave the deadline unenforced. */
    if (seconds == 0 || seconds > INTPTR_MAX || getpgrp() != leader || pipe(ready) != 0) {
        return -1;
    }
    if (fcntl(ready[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(ready[1], F_SETFD, FD_CLOEXEC) != 0) {
        close(ready[0]);
        close(ready[1]);
        return -1;
    }
    intermediate = fork();
    if (intermediate < 0) {
        close(ready[0]);
        close(ready[1]);
        return -1;
    }
    if (intermediate == 0) {
        pid_t watchdog;
        close(ready[0]);
        if (setsid() < 0) {
            _exit(1);
        }
        watchdog = fork();
        if (watchdog < 0) {
            _exit(1);
        }
        if (watchdog > 0) {
            _exit(0);
        }
        watch_leader(leader, seconds, ready[1]);
    }
    close(ready[1]);
    while (waitpid(intermediate, &status, 0) < 0) {
        if (errno != EINTR) {
            close(ready[0]);
            return -1;
        }
    }
    do {
        got = read(ready[0], &byte, 1);
    } while (got < 0 && errno == EINTR);
    close(ready[0]);
    if (WIFEXITED(status) == 0 || WEXITSTATUS(status) != 0 || got != 1 || byte != '1') {
        return -1;
    }
    return 0;
}

static int refuse(const char *what) {
    /* stderr is the slave or what rv granted; the message names no secret. */
    dprintf(STDERR_FILENO, "rv-pty-claim: %s; the runtime was not started\n", what);
    return RV_LIMIT_FAILED;
}

int main(int argc, char **argv) {
    struct rv_limit limits[RV_MAX_LIMITS];
    int limit_count = 0;
    int seen_resources = 0;
    uint64_t deadline = 0;
    int has_deadline = 0;
    int inject_fault = 0;
    int index = 1;
    int limit;
    const char *slave;

    for (; index < argc && argv[index] != NULL && strncmp(argv[index], "--", 2) == 0; index++) {
        const char *arg = argv[index];
        if (strncmp(arg, "--rlimit=", 9) == 0) {
            int bit;
            if (limit_count >= RV_MAX_LIMITS || parse_limit(arg + 9, &limits[limit_count]) != 0) {
                return RV_CLAIM_FAILED;
            }
            bit = 1 << limits[limit_count].resource;
            if ((seen_resources & bit) != 0) {
                return RV_CLAIM_FAILED;
            }
            seen_resources |= bit;
            limit_count++;
        } else if (strncmp(arg, "--deadline-seconds=", 19) == 0) {
            if (has_deadline || parse_u64(arg + 19, &deadline) != 0 || deadline == 0) {
                return RV_CLAIM_FAILED;
            }
            has_deadline = 1;
        } else if (strcmp(arg, "--rlimit-fault") == 0 && inject_fault == 0) {
            inject_fault = 1;
        } else {
            return RV_CLAIM_FAILED;
        }
    }
    if (argc - index < 2 || argv[index] == NULL || argv[index + 1] == NULL
        || argv[index + 1][0] != '/') {
        return RV_CLAIM_FAILED;
    }
    slave = argv[index];
    if (strcmp(slave, "-") != 0 && claim(slave) != 0) {
        return RV_CLAIM_FAILED;
    }
    if (has_deadline && start_deadline_watchdog(deadline) != 0) {
        return refuse("the deadline watchdog could not be armed");
    }
    for (limit = 0; limit < limit_count; limit++) {
        if (apply_limit(&limits[limit]) != 0) {
            char message[96];
            snprintf(message, sizeof(message), "resource limit %s could not be applied", limits[limit].name);
            return refuse(message);
        }
    }
    if (inject_fault) {
        /* A kernel that accepted soft > hard would still not exec. */
        return apply_refused_limit() == 0
            ? RV_CLAIM_FAILED
            : refuse("resource limit nofile could not be applied");
    }
    execv(argv[index + 1], argv + index + 1);
    return RV_CLAIM_FAILED;
}
