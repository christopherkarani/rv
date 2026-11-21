#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "local_eval.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

static void set_reason(char *reason, size_t cap, const char *text) {
    if (reason == NULL || cap == 0) {
        return;
    }
    (void)snprintf(reason, cap, "%s", text);
}

enum RvLocalVerdict rv_local_parse_output(
    const char *out,
    size_t out_len,
    const char **body,
    size_t *body_len,
    char *reason,
    size_t reason_cap
) {
    const size_t final_len = sizeof RV_LOCAL_FINAL_TAG - 1;
    const size_t escalate_len = sizeof RV_LOCAL_ESCALATE_TAG - 1;
    *body = NULL;
    *body_len = 0;
    if (out == NULL) {
        set_reason(reason, reason_cap, "protocol");
        return RV_LOCAL_ESCALATE;
    }
    if (out_len > final_len && memcmp(out, RV_LOCAL_FINAL_TAG, final_len) == 0) {
        *body = out + final_len;
        *body_len = out_len - final_len;
        if (memchr(*body, '\0', *body_len) != NULL) {
            *body = NULL;
            *body_len = 0;
            set_reason(reason, reason_cap, "protocol");
            return RV_LOCAL_ESCALATE;
        }
        return RV_LOCAL_FINAL;
    }
    if (out_len > escalate_len && memcmp(out, RV_LOCAL_ESCALATE_TAG, escalate_len) == 0
        && out[out_len - 1] == '\n') {
        size_t n = out_len - escalate_len - 1;
        size_t i;
        for (i = 0; i < n; i++) {
            char ch = out[escalate_len + i];
            if (!((ch >= 'a' && ch <= 'z') || ch == '-')) {
                set_reason(reason, reason_cap, "protocol");
                return RV_LOCAL_ESCALATE;
            }
        }
        if (reason != NULL && reason_cap > 0) {
            size_t copy = n < reason_cap - 1 ? n : reason_cap - 1;
            memcpy(reason, out + escalate_len, copy);
            reason[copy] = '\0';
        }
        return RV_LOCAL_ESCALATE;
    }
    set_reason(reason, reason_cap, "protocol");
    return RV_LOCAL_ESCALATE;
}

static long long now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void close_fd(int *fd) {
    if (*fd >= 0) {
        close(*fd);
        *fd = -1;
    }
}

/* SIGKILL and reap: nothing the child does after this is read. */
static void kill_and_reap(pid_t pid) {
    int status;
    (void)kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
}

/* Gives up on a child: SIGKILL first, then close its pipes, then reap. On
 * Linux the child is already running, so closing its stdin first would
 * wake it with EOF and let it act on an empty call before the kill. */
static void abandon(pid_t pid, int *to_child, int *from_child) {
    (void)kill(pid, SIGKILL);
    close_fd(to_child);
    close_fd(from_child);
    kill_and_reap(pid);
}

/* Reaps `pid` by `deadline`; 1 when it exited normally with status 0. A
 * child still running at the deadline is killed. */
static int reap_ok(pid_t pid, long long deadline) {
    for (;;) {
        int status = 0;
        pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) {
            return WIFEXITED(status) && WEXITSTATUS(status) == 0;
        }
        if (got < 0 && errno != EINTR) {
            return 0;
        }
        if (now_ms() >= deadline) {
            kill_and_reap(pid);
            return 0;
        }
        {
            struct timespec ts = { 0, 1000000L };
            (void)nanosleep(&ts, NULL);
        }
    }
}

#ifdef __APPLE__
#ifndef POSIX_SPAWN_START_SUSPENDED
#define POSIX_SPAWN_START_SUSPENDED 0x0080
#endif
#endif

/* posix_spawn the evaluator with pipes for stdin/stdout, stderr on
 * /dev/null, cwd "/", default signal dispositions and the fixed `envp`.
 * Darwin starts it suspended. 0 on success. */
static int spawn_evaluator(
    const char *path,
    char *const argv[],
    char *const envp[],
    pid_t *pid,
    int *to_child,
    int *from_child
) {
    int in_pipe[2] = { -1, -1 };
    int out_pipe[2] = { -1, -1 };
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    sigset_t defaults;
    sigset_t empty;
    short flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    int rc = -1;

    if (pipe(in_pipe) != 0) {
        return -1;
    }
    if (pipe(out_pipe) != 0) {
        close(in_pipe[0]);
        close(in_pipe[1]);
        return -1;
    }
    (void)fcntl(in_pipe[1], F_SETFD, FD_CLOEXEC);
    (void)fcntl(out_pipe[0], F_SETFD, FD_CLOEXEC);
    if (posix_spawn_file_actions_init(&actions) != 0) {
        goto out_pipes;
    }
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        goto out_pipes;
    }
#ifdef __APPLE__
    /* Only the three standard descriptors cross into the evaluator. */
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED;
#endif
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    sigemptyset(&empty);
    if (posix_spawnattr_setflags(&attr, flags) != 0
        || posix_spawnattr_setsigdefault(&attr, &defaults) != 0
        || posix_spawnattr_setsigmask(&attr, &empty) != 0
        || posix_spawn_file_actions_adddup2(&actions, in_pipe[0], STDIN_FILENO) != 0
        || posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO) != 0
        || posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) != 0
        || posix_spawn_file_actions_addchdir_np(&actions, "/") != 0) {
        goto out_spawn;
    }
#ifndef __APPLE__
    /* Linux has no close-on-exec default: close the pipe originals so only
     * the dup2'd standard descriptors remain. */
    if (posix_spawn_file_actions_addclose(&actions, in_pipe[0]) != 0
        || posix_spawn_file_actions_addclose(&actions, out_pipe[1]) != 0) {
        goto out_spawn;
    }
#endif
    if (posix_spawn(pid, path, &actions, &attr, argv, envp) == 0) {
        rc = 0;
    }
out_spawn:
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
out_pipes:
    close(in_pipe[0]);
    close(out_pipe[1]);
    if (rc == 0) {
        *to_child = in_pipe[1];
        *from_child = out_pipe[0];
    } else {
        close(in_pipe[1]);
        close(out_pipe[0]);
    }
    return rc;
}

enum RvLocalVerdict rv_local_evaluate(
    const char *path,
    const char *host,
    const char *request_id,
    const char *home,
    const char *user,
    const unsigned char *stdin_bytes,
    size_t stdin_len,
    long deadline_ms,
    RvLocalVerify verify,
    char **reply_json,
    size_t *reply_len,
    char *reason,
    size_t reason_cap
) {
    char env_home[4096 + 8];
    char env_user[512];
    char env_logname[512];
    char *envp[5];
    char *argv[6];
    pid_t pid = -1;
    int to_child = -1;
    int from_child = -1;
    char *out = NULL;
    size_t out_len = 0;
    size_t written = 0;
    long long deadline;
    int exited_ok;
    enum RvLocalVerdict verdict;
    const char *body = NULL;
    size_t body_len = 0;

    *reply_json = NULL;
    *reply_len = 0;
    set_reason(reason, reason_cap, "unavailable");
    if (path == NULL || host == NULL || request_id == NULL || home == NULL || home[0] != '/'
        || user == NULL || verify == NULL) {
        return RV_LOCAL_ESCALATE;
    }
    if (snprintf(env_home, sizeof env_home, "HOME=%s", home) >= (int)sizeof env_home
        || snprintf(env_user, sizeof env_user, "USER=%s", user) >= (int)sizeof env_user
        || snprintf(env_logname, sizeof env_logname, "LOGNAME=%s", user) >= (int)sizeof env_logname) {
        return RV_LOCAL_ESCALATE;
    }
    envp[0] = env_home;
    envp[1] = env_user;
    envp[2] = env_logname;
    envp[3] = (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin";
    envp[4] = NULL;
    argv[0] = (char *)path;
    argv[1] = (char *)"--host";
    argv[2] = (char *)host;
    argv[3] = (char *)"--request-id";
    argv[4] = (char *)request_id;
    argv[5] = NULL;

    deadline = now_ms() + deadline_ms;
    if (spawn_evaluator(path, argv, envp, &pid, &to_child, &from_child) != 0) {
        set_reason(reason, reason_cap, "spawn");
        return RV_LOCAL_ESCALATE;
    }
    /* Identity before input: the child has not read a byte yet (and on
     * Darwin has not run an instruction). */
    if (!verify(pid, path)) {
        abandon(pid, &to_child, &from_child);
        set_reason(reason, reason_cap, "untrusted");
        return RV_LOCAL_ESCALATE;
    }
    /* A slow verify spends the budget too: past the deadline the child
     * never runs (Darwin) and never gets the call. */
    if (now_ms() >= deadline) {
        abandon(pid, &to_child, &from_child);
        set_reason(reason, reason_cap, "timeout");
        return RV_LOCAL_ESCALATE;
    }
#ifdef __APPLE__
    if (kill(pid, SIGCONT) != 0) {
        abandon(pid, &to_child, &from_child);
        set_reason(reason, reason_cap, "spawn");
        return RV_LOCAL_ESCALATE;
    }
#endif
    if (set_nonblocking(to_child) != 0 || set_nonblocking(from_child) != 0) {
        goto fail_kill;
    }
    out = (char *)malloc(RV_LOCAL_OUTPUT_MAX + 1);
    if (out == NULL) {
        goto fail_kill;
    }
    if (stdin_len == 0) {
        close_fd(&to_child);
    }
    while (from_child >= 0) {
        struct pollfd fds[2];
        nfds_t count = 0;
        int out_index = -1;
        int in_index = -1;
        long long left = deadline - now_ms();
        int ready;
        if (left <= 0) {
            set_reason(reason, reason_cap, "timeout");
            goto fail_kill_quiet;
        }
        fds[count].fd = from_child;
        fds[count].events = POLLIN;
        fds[count].revents = 0;
        out_index = (int)count++;
        if (to_child >= 0) {
            fds[count].fd = to_child;
            fds[count].events = POLLOUT;
            fds[count].revents = 0;
            in_index = (int)count++;
        }
        ready = poll(fds, count, (int)left);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            goto fail_kill;
        }
        if (ready == 0) {
            continue;
        }
        if (in_index >= 0 && fds[in_index].revents != 0) {
            if ((fds[in_index].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                goto fail_kill;
            }
            {
                ssize_t w = write(to_child, stdin_bytes + written, stdin_len - written);
                if (w < 0 && errno != EAGAIN && errno != EINTR) {
                    goto fail_kill;
                }
                if (w > 0) {
                    written += (size_t)w;
                }
                if (written == stdin_len) {
                    close_fd(&to_child);
                }
            }
        }
        if (fds[out_index].revents != 0) {
            ssize_t r = read(from_child, out + out_len, RV_LOCAL_OUTPUT_MAX + 1 - out_len);
            if (r < 0) {
                if (errno == EAGAIN || errno == EINTR) {
                    continue;
                }
                goto fail_kill;
            }
            if (r == 0) {
                close_fd(&from_child);
                break;
            }
            out_len += (size_t)r;
            if (out_len > RV_LOCAL_OUTPUT_MAX) {
                set_reason(reason, reason_cap, "oversize");
                goto fail_kill_quiet;
            }
        }
    }
    /* stdout closed before all of stdin went in: the evaluator answered
     * without the whole call. */
    if (to_child >= 0) {
        goto fail_kill;
    }
    exited_ok = reap_ok(pid, deadline);
    pid = -1;
    if (!exited_ok) {
        free(out);
        set_reason(reason, reason_cap, "exit");
        return RV_LOCAL_ESCALATE;
    }
    verdict = rv_local_parse_output(out, out_len, &body, &body_len, reason, reason_cap);
    if (verdict != RV_LOCAL_FINAL) {
        free(out);
        return RV_LOCAL_ESCALATE;
    }
    memmove(out, body, body_len);
    out[body_len] = '\0';
    *reply_json = out;
    *reply_len = body_len;
    return RV_LOCAL_FINAL;

fail_kill:
    set_reason(reason, reason_cap, "io");
fail_kill_quiet:
    if (pid > 0) {
        abandon(pid, &to_child, &from_child);
    } else {
        close_fd(&to_child);
        close_fd(&from_child);
    }
    free(out);
    return RV_LOCAL_ESCALATE;
}
