/*
 * Out-of-host watchdog for one caged runtime.
 *
 * A double-forked process in its own session, outside the runtime's
 * groups and outside Seatbelt (the profile lets the cage signal only its
 * own sandbox), so it outlives the workspace host and rvd. It holds no
 * descriptor of the runtime except a kqueue on the leader's exit.
 *
 * Every RV_POLL_MS it refreshes the set of processes it tracks: the
 * leader, members of the leader's process group, and every child of a
 * tracked process. A descendant that moves to its own group with
 * setpgid() or setsid() stays tracked, and so does an orphan once seen.
 * Each entry is pinned by its start time, so a reused pid is never
 * signalled. Then:
 *
 * - CPU cap: a tracked process whose user + system time passes the cap
 *   is SIGKILLed. XNU's RLIMIT_CPU only sends one SIGXCPU, which a
 *   process may ignore, so this is what bounds CPU.
 * - Deadline (continuous clock, so sleep counts), leader exit, the
 *   owner's exit (an admitted one-shot ends with its runtime), a
 *   tracking set that would overflow, or a kqueue failure ends the
 *   runtime: everything tracked is stopped until a pass finds nothing
 *   new, then killed, with the leader's group and, for a terminal
 *   runtime, every process of the leader's session, until none is left.
 *
 * Residual: a process that forks, moves itself out of the group, and
 * whose parent exits before the next poll is reparented to launchd
 * unseen; nothing then links it to this runtime. The owner is named by
 * pid only, so an owner that exited before arming is refused but one
 * whose pid was already reused would be watched in its place.
 */
#include "watchdog.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/proc_info.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define RV_TRACK_MAX 4096
#define RV_LIST_MAX 4096
#define RV_POLL_MS 100
#define RV_SWEEP_PASSES 200
#define RV_SWEEP_PAUSE_MS 10

struct rv_tracked {
    pid_t pid;
    uint64_t start;
};

struct rv_watch {
    pid_t leader;
    pid_t owner;
    int session;
    pid_t self;
    pid_t intermediate;
    uint64_t deadline;
    uint64_t cpu_cap_ns;
    mach_timebase_info_data_t timebase;
    struct rv_tracked items[RV_TRACK_MAX];
    int count;
    int overflow;
};

static struct rv_watch watch;
static pid_t listed[RV_LIST_MAX];

static int start_of(pid_t pid, uint64_t *start) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info)) != (int)sizeof(info)) {
        return -1;
    }
    *start = (uint64_t)info.pbi_start_tvsec * 1000000u + (uint64_t)info.pbi_start_tvusec;
    return 0;
}

static int still_alive(const struct rv_tracked *entry) {
    uint64_t start;
    return start_of(entry->pid, &start) == 0 && start == entry->start;
}

static int is_tracked(pid_t pid) {
    int index;
    for (index = 0; index < watch.count; index++) {
        if (watch.items[index].pid == pid) {
            return 1;
        }
    }
    return 0;
}

static void track(pid_t pid) {
    uint64_t start;
    if (pid <= 1 || pid == watch.self || pid == watch.intermediate || is_tracked(pid)) {
        return;
    }
    if (start_of(pid, &start) != 0) {
        return;
    }
    if (watch.count >= RV_TRACK_MAX) {
        watch.overflow = 1;
        return;
    }
    watch.items[watch.count].pid = pid;
    watch.items[watch.count].start = start;
    watch.count++;
}

/* proc_listchildpids and proc_listpgrppids return a pid count. */
static void track_listed(int count) {
    int index;
    if (count >= RV_LIST_MAX) {
        watch.overflow = 1;
    }
    for (index = 0; index < count && index < RV_LIST_MAX; index++) {
        track(listed[index]);
    }
}

static void refresh(void) {
    int index;
    int kept = 0;
    for (index = 0; index < watch.count; index++) {
        if (still_alive(&watch.items[index])) {
            watch.items[kept++] = watch.items[index];
        }
    }
    watch.count = kept;
    track_listed(proc_listpgrppids(watch.leader, listed, (int)sizeof(listed)));
    /* Appended entries are walked too: the loop covers the whole tree. */
    for (index = 0; index < watch.count; index++) {
        track_listed(proc_listchildpids(watch.items[index].pid, listed, (int)sizeof(listed)));
    }
}

/* A terminal runtime's leader leads its own session: every process in
 * that session is the runtime's, including each job-control group. */
static void track_session(void) {
    int capacity;
    int count;
    int index;
    pid_t *all;
    if (watch.session == 0) {
        return;
    }
    capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) {
        return;
    }
    capacity += 256;
    all = calloc((size_t)capacity, sizeof(pid_t));
    if (all == NULL) {
        return;
    }
    count = proc_listallpids(all, capacity * (int)sizeof(pid_t));
    for (index = 0; index < count && index < capacity; index++) {
        if (all[index] > 1 && getsid(all[index]) == watch.leader) {
            track(all[index]);
        }
    }
    free(all);
}

static void signal_tracked(int signal_number) {
    int index;
    for (index = 0; index < watch.count; index++) {
        if (still_alive(&watch.items[index])) {
            kill(watch.items[index].pid, signal_number);
        }
    }
}

static void pause_ms(long milliseconds) {
    struct timespec pause = {0, milliseconds * 1000000L};
    nanosleep(&pause, NULL);
}

static uint64_t ticks_to_ns(uint64_t ticks) {
    uint64_t numer = watch.timebase.numer;
    uint64_t denom = watch.timebase.denom;
    return (ticks / denom) * numer + ((ticks % denom) * numer) / denom;
}

static void enforce_cpu(void) {
    int index;
    if (watch.cpu_cap_ns == 0) {
        return;
    }
    for (index = 0; index < watch.count; index++) {
        struct proc_taskinfo info;
        pid_t pid = watch.items[index].pid;
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, (int)sizeof(info)) != (int)sizeof(info)) {
            continue;
        }
        if (ticks_to_ns(info.pti_total_user + info.pti_total_system) > watch.cpu_cap_ns
            && still_alive(&watch.items[index])) {
            kill(pid, SIGKILL);
        }
    }
}

/* Freeze, so nothing forks while it is collected; then kill until a pass
 * finds no process of the runtime alive. */
static void end_runtime(void) {
    int pass;
    int previous = -1;
    for (pass = 0; pass < RV_SWEEP_PASSES && previous != watch.count; pass++) {
        previous = watch.count;
        refresh();
        track_session();
        signal_tracked(SIGSTOP);
    }
    for (pass = 0; pass < RV_SWEEP_PASSES; pass++) {
        int index;
        int alive = 0;
        signal_tracked(SIGKILL);
        kill(-watch.leader, SIGKILL);
        pause_ms(RV_SWEEP_PAUSE_MS);
        refresh();
        track_session();
        for (index = 0; index < watch.count; index++) {
            alive |= still_alive(&watch.items[index]);
        }
        if (alive == 0) {
            return;
        }
    }
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
static void run_watchdog(int ready) {
    struct kevent change;
    struct kevent fired;
    int queue = kqueue();
    if (queue < 0) {
        _exit(1);
    }
    EV_SET(&change, (uintptr_t)watch.leader, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL) != 0) {
        _exit(1);
    }
    if (watch.owner != 0) {
        EV_SET(&change, (uintptr_t)watch.owner, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
        if (kevent(queue, &change, 1, NULL, 0, NULL) != 0) {
            _exit(1);
        }
    }
    /* The leader is blocked until this byte arrives, so it is alive. */
    track(watch.leader);
    if (watch.count != 1 || write(ready, "1", 1) != 1) {
        _exit(1);
    }
    close_every_descriptor_but(queue);
    for (;;) {
        struct timespec poll = {0, RV_POLL_MS * 1000000L};
        int count = kevent(queue, NULL, 0, &fired, 1, &poll);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count != 0) {
            break;
        }
        refresh();
        if (watch.overflow) {
            break;
        }
        enforce_cpu();
        if (watch.deadline != 0 && mach_continuous_time() >= watch.deadline) {
            break;
        }
    }
    end_runtime();
    _exit(0);
}

int rv_start_watchdog(uint64_t deadline_seconds, uint64_t cpu_seconds, pid_t owner) {
    pid_t leader = getpid();
    int ready[2];
    pid_t intermediate;
    int status = 0;
    char byte = 0;
    ssize_t got;
    /* 31 days in seconds is the largest cap rv sends; refuse what would
     * overflow the nanosecond arithmetic. */
    if ((deadline_seconds == 0 && cpu_seconds == 0 && owner == 0) || deadline_seconds > 31536000u
        || cpu_seconds > 31536000u || owner < 0 || owner == 1 || owner == leader) {
        return -1;
    }
    /* Group-wide kills name this pid: the leader must lead its group. */
    if (getpgrp() != leader || mach_timebase_info(&watch.timebase) != KERN_SUCCESS
        || watch.timebase.numer == 0 || watch.timebase.denom == 0) {
        return -1;
    }
    watch.leader = leader;
    watch.owner = owner;
    watch.session = getsid(0) == leader;
    watch.count = 0;
    watch.overflow = 0;
    watch.cpu_cap_ns = cpu_seconds * 1000000000u;
    watch.deadline = 0;
    if (deadline_seconds != 0) {
        uint64_t ns = deadline_seconds * 1000000000u;
        watch.deadline = mach_continuous_time()
            + (ns / watch.timebase.numer) * watch.timebase.denom
            + ((ns % watch.timebase.numer) * watch.timebase.denom) / watch.timebase.numer;
    }
    if (pipe(ready) != 0) {
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
        watch.intermediate = getpid();
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
        watch.self = getpid();
        run_watchdog(ready[1]);
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
