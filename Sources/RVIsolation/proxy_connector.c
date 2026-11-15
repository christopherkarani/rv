/*
 * The connector of the MCP server cage
 * (docs/security/mcp-linux-sandbox.md). Compiled only into
 * rv-isolation-exec, which includes this file after socket_filter.c.
 *
 * With `sandbox.hosts` a caged server may open TCP connections to one
 * place: rv's allowlist proxy, on loopback. Landlock can name a port but
 * not an address, so a port rule would leave that port open on every
 * host. Instead the server never carries out a `connect` on an internet
 * socket itself:
 *
 *   - Landlock allows no TCP connection at all;
 *   - the socket filter hands each `connect` the cage makes to this
 *     process, the server's parent, outside the cage (a seccomp user
 *     notification);
 *   - this process takes its own copy of the socket and connects it to
 *     the proxy on 127.0.0.1, or answers EACCES.
 *
 * The address the server asked for is read only to refuse what is not
 * the proxy. It is never used, so a server that changes it after it was
 * read gains nothing: the connection made is this process's, to an
 * address this process chose. A `connect` on a socket that is not an
 * internet socket is handed back to the kernel, where Landlock decides
 * it; if the server puts an internet socket under that number in
 * between, the kernel's own `connect` is the one Landlock refuses.
 *
 * The gateway holds this process, not the server: it relays the
 * server's exit and the signals sent to it, kills a server that outlives
 * SIGTERM, and the server is killed if this process is.
 */
#ifdef __linux__

#include <errno.h>
#include <fcntl.h>
#include <linux/seccomp.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef SECCOMP_GET_NOTIF_SIZES
#define SECCOMP_GET_NOTIF_SIZES 3
#endif

/* How long a server may outlive a SIGTERM sent to this process. The
 * gateway kills what it holds a second after its own SIGTERM, and that
 * would be this process, not the server. */
#define RV_CONNECTOR_GRACE_MILLISECONDS 500

/* Sends descriptor `fd` over the Unix socket `channel`. 0 or -1. */
static int rv_connector_send(int channel, int fd) {
    char byte = 'l';
    struct iovec data = { .iov_base = &byte, .iov_len = 1 };
    union {
        struct cmsghdr header;
        char space[CMSG_SPACE(sizeof(int))];
    } control;
    struct msghdr message;
    struct cmsghdr *header;

    memset(&control, 0, sizeof(control));
    memset(&message, 0, sizeof(message));
    message.msg_iov = &data;
    message.msg_iovlen = 1;
    message.msg_control = control.space;
    message.msg_controllen = sizeof(control.space);
    header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &fd, sizeof(int));
    return sendmsg(channel, &message, MSG_NOSIGNAL) == 1 ? 0 : -1;
}

/* The descriptor sent over `channel`, or -1 when the other end closed
 * without sending one. */
static int rv_connector_receive(int channel) {
    char byte = 0;
    struct iovec data = { .iov_base = &byte, .iov_len = 1 };
    union {
        struct cmsghdr header;
        char space[CMSG_SPACE(sizeof(int))];
    } control;
    struct msghdr message;
    struct cmsghdr *header;
    ssize_t count;
    int fd = -1;

    memset(&control, 0, sizeof(control));
    memset(&message, 0, sizeof(message));
    message.msg_iov = &data;
    message.msg_iovlen = 1;
    message.msg_control = control.space;
    message.msg_controllen = sizeof(control.space);
    do {
        count = recvmsg(channel, &message, MSG_CMSG_CLOEXEC);
    } while (count < 0 && errno == EINTR);
    if (count != 1 || (message.msg_flags & MSG_CTRUNC) != 0) {
        return -1;
    }
    header = CMSG_FIRSTHDR(&message);
    if (header == NULL || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS
        || header->cmsg_len != CMSG_LEN(sizeof(int))) {
        return -1;
    }
    memcpy(&fd, CMSG_DATA(header), sizeof(int));
    return fd;
}

/* The process (thread group) that thread `thread` belongs to, from
 * /proc; 0 when it cannot be read. */
static pid_t rv_connector_process(pid_t thread) {
    char path[64];
    char text[2048];
    char *line;
    ssize_t count;
    int fd;

    snprintf(path, sizeof(path), "/proc/%d/status", (int)thread);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return 0;
    }
    count = read(fd, text, sizeof(text) - 1);
    close(fd);
    if (count <= 0) {
        return 0;
    }
    text[count] = '\0';
    line = strstr(text, "\nTgid:");
    return line == NULL ? 0 : (pid_t)strtol(line + 6, NULL, 10);
}

/* This process's own copy of descriptor `number` of `process`, or -1.
 * `listener` and `id`, when given, are the notification this is for: the
 * process is checked to be the one still waiting on it, so that a pid
 * reused since the notification is not read from. */
static int rv_connector_take(pid_t process, int number, int listener, const __u64 *id) {
    int handle = (int)syscall(SYS_pidfd_open, process, 0u);
    int copy = -1;
    int failure;

    if (handle < 0) {
        return -1;
    }
    if (id != NULL && ioctl(listener, SECCOMP_IOCTL_NOTIF_ID_VALID, id) != 0) {
        failure = ENOENT;
    } else {
        copy = (int)syscall(SYS_pidfd_getfd, handle, number, 0u);
        failure = errno;
    }
    close(handle);
    errno = failure;
    return copy;
}

/* Whether this process can do for `server` what a connection needs:
 * find its process in /proc and copy a descriptor from it. A host that
 * forbids either (no /proc, kernel.yama.ptrace_scope 2 or 3, a container
 * that filters the calls) has errno set and gets no server. */
static int rv_connector_can_serve(pid_t server) {
    int copy;

    if (rv_connector_process(server) != server) {
        errno = ENOENT;
        return 0;
    }
    copy = rv_connector_take(server, STDIN_FILENO, -1, NULL);
    if (copy >= 0) {
        close(copy);
        return 1;
    }
    /* A server started with no standard input has nothing to copy. */
    return errno == EBADF;
}

/* The answer to one `connect` the cage made. */
static void rv_connector_answer(
    int listener, const struct seccomp_notif *request, struct seccomp_notif_resp *answer, unsigned short port) {
    struct sockaddr_storage asked;
    struct sockaddr_in to_proxy;
    struct sockaddr_in6 to_proxy6;
    struct sockaddr unspecified;
    const struct sockaddr_in *asked4 = (const struct sockaddr_in *)&asked;
    const struct sockaddr_in6 *asked6 = (const struct sockaddr_in6 *)&asked;
    struct iovec local;
    struct iovec remote;
    socklen_t size = sizeof(int);
    size_t length;
    pid_t process;
    int domain = 0;
    int result;
    int sock;

    answer->id = request->id;
    answer->val = 0;
    answer->flags = 0;
    answer->error = -EACCES;
    if (request->data.nr != SYS_connect) {
        return;
    }
    process = rv_connector_process((pid_t)request->pid);
    if (process <= 0) {
        return;
    }
    sock = rv_connector_take(process, (int)request->data.args[0], listener, &request->id);
    if (sock < 0) {
        if (errno == EBADF) {
            answer->error = -EBADF;
        }
        return;
    }
    if (getsockopt(sock, SOL_SOCKET, SO_DOMAIN, &domain, &size) != 0) {
        answer->error = -ENOTSOCK;
        close(sock);
        return;
    }
    if (domain != AF_INET && domain != AF_INET6) {
        /* The kernel carries it out, and Landlock decides it there. */
        answer->error = 0;
        answer->flags = SECCOMP_USER_NOTIF_FLAG_CONTINUE;
        close(sock);
        return;
    }

    /* connect(fd, address, length): what was asked for, to refuse what
     * is not the proxy. */
    if ((int)request->data.args[2] < (int)sizeof(sa_family_t)) {
        answer->error = -EINVAL;
        close(sock);
        return;
    }
    length = (size_t)(int)request->data.args[2];
    if (length > sizeof(asked)) {
        length = sizeof(asked);
    }
    memset(&asked, 0, sizeof(asked));
    local.iov_base = &asked;
    local.iov_len = length;
    remote.iov_base = (void *)(unsigned long)request->data.args[1];
    remote.iov_len = length;
    if (process_vm_readv(process, &local, 1, &remote, 1, 0) != (ssize_t)length) {
        answer->error = -EFAULT;
        close(sock);
        return;
    }
    if (asked.ss_family == AF_UNSPEC) {
        /* Dissolves a connection; it makes none. */
        memset(&unspecified, 0, sizeof(unspecified));
        unspecified.sa_family = AF_UNSPEC;
        result = connect(sock, &unspecified, sizeof(unspecified));
    } else if (domain == AF_INET && asked.ss_family == AF_INET && length >= sizeof(*asked4)
        && asked4->sin_port == htons(port) && (ntohl(asked4->sin_addr.s_addr) >> 24) == IN_LOOPBACKNET) {
        memset(&to_proxy, 0, sizeof(to_proxy));
        to_proxy.sin_family = AF_INET;
        to_proxy.sin_port = htons(port);
        to_proxy.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        result = connect(sock, (const struct sockaddr *)&to_proxy, sizeof(to_proxy));
    } else if (domain == AF_INET6 && asked.ss_family == AF_INET6 && length >= sizeof(*asked6)
        && asked6->sin6_port == htons(port)
        && (IN6_IS_ADDR_LOOPBACK(&asked6->sin6_addr)
            || (IN6_IS_ADDR_V4MAPPED(&asked6->sin6_addr) && asked6->sin6_addr.s6_addr[12] == IN_LOOPBACKNET))) {
        /* The proxy listens on 127.0.0.1: reached from an IPv6 socket as
         * ::ffff:127.0.0.1. */
        memset(&to_proxy6, 0, sizeof(to_proxy6));
        to_proxy6.sin6_family = AF_INET6;
        to_proxy6.sin6_port = htons(port);
        to_proxy6.sin6_addr.s6_addr[10] = 0xff;
        to_proxy6.sin6_addr.s6_addr[11] = 0xff;
        to_proxy6.sin6_addr.s6_addr[12] = IN_LOOPBACKNET;
        to_proxy6.sin6_addr.s6_addr[15] = 1;
        result = connect(sock, (const struct sockaddr *)&to_proxy6, sizeof(to_proxy6));
    } else {
        close(sock);
        return;
    }
    answer->error = result == 0 ? 0 : -errno;
    close(sock);
}

/* Ends this process the way the server ended. */
static int rv_connector_finish(int status) {
    struct rlimit none = { 0, 0 };
    sigset_t unblocked;
    int number;

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    number = WIFSIGNALED(status) ? WTERMSIG(status) : SIGKILL;
    /* Die of the same signal, without a core file of our own. */
    setrlimit(RLIMIT_CORE, &none);
    signal(number, SIG_DFL);
    sigemptyset(&unblocked);
    sigaddset(&unblocked, number);
    sigprocmask(SIG_UNBLOCK, &unblocked, NULL);
    raise(number);
    return 128 + number;
}

static long rv_connector_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/* The signals this process passes on to the server, and SIGCHLD. The
 * caller blocks them before the server exists, so none is lost. */
static void rv_connector_signals(sigset_t *signals) {
    sigemptyset(signals);
    sigaddset(signals, SIGCHLD);
    sigaddset(signals, SIGTERM);
    sigaddset(signals, SIGINT);
    sigaddset(signals, SIGHUP);
    sigaddset(signals, SIGQUIT);
}

/* Serves the cage's connections until `server` ends; returns the exit
 * status for this process (or dies of the signal the server died of). */
static int rv_connector_serve(int listener, pid_t server, unsigned short port) {
    struct seccomp_notif_sizes sizes;
    struct seccomp_notif *request;
    struct seccomp_notif_resp *answer;
    struct signalfd_siginfo heard;
    struct pollfd watched[2];
    sigset_t signals;
    size_t request_size;
    size_t answer_size;
    long kill_at = 0;
    int signal_fd;
    int status;
    int ready;
    int wait;

    rv_connector_signals(&signals);
    signal_fd = signalfd(-1, &signals, SFD_CLOEXEC);
    request_size = sizeof(*request);
    answer_size = sizeof(*answer);
    if (syscall(SYS_seccomp, SECCOMP_GET_NOTIF_SIZES, 0u, &sizes) == 0) {
        request_size = sizes.seccomp_notif > request_size ? sizes.seccomp_notif : request_size;
        answer_size = sizes.seccomp_notif_resp > answer_size ? sizes.seccomp_notif_resp : answer_size;
    }
    request = calloc(1, request_size);
    answer = calloc(1, answer_size);
    if (signal_fd < 0 || request == NULL || answer == NULL) {
        kill(server, SIGKILL);
        return 125;
    }
    for (;;) {
        wait = -1;
        if (kill_at != 0) {
            long left = kill_at - rv_connector_now();
            if (left <= 0) {
                kill(server, SIGKILL);
                kill_at = 0;
            } else {
                wait = (int)left;
            }
        }
        watched[0].fd = listener;
        watched[0].events = POLLIN;
        watched[0].revents = 0;
        watched[1].fd = signal_fd;
        watched[1].events = POLLIN;
        watched[1].revents = 0;
        ready = poll(watched, 2, wait);
        if (ready < 0 && errno != EINTR) {
            kill(server, SIGKILL);
            return 125;
        }
        if (ready <= 0) {
            continue;
        }
        if ((watched[1].revents & POLLIN) != 0 && read(signal_fd, &heard, sizeof(heard)) == (ssize_t)sizeof(heard)) {
            if (heard.ssi_signo == SIGCHLD) {
                if (waitpid(server, &status, WNOHANG) == server) {
                    return rv_connector_finish(status);
                }
            } else {
                kill(server, (int)heard.ssi_signo);
                if (heard.ssi_signo == SIGTERM && kill_at == 0) {
                    kill_at = rv_connector_now() + RV_CONNECTOR_GRACE_MILLISECONDS;
                }
            }
        }
        if ((watched[0].revents & POLLIN) != 0) {
            memset(request, 0, request_size);
            memset(answer, 0, answer_size);
            if (ioctl(listener, SECCOMP_IOCTL_NOTIF_RECV, request) == 0) {
                rv_connector_answer(listener, request, answer, port);
                /* A caller that is gone by now has no use for the answer. */
                (void)ioctl(listener, SECCOMP_IOCTL_NOTIF_SEND, answer);
            }
        } else if ((watched[0].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
            /* Nothing in the cage is left to ask; the server's exit follows. */
            listener = -1;
        }
    }
}

#endif
