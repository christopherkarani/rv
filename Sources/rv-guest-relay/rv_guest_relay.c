/*
 * rv-guest-relay: loopback TCP to unix-socket relay inside an rv micro-VM.
 *
 * The guest has no network interface. rv's egress proxy and secret gateway
 * listen on host loopback, and rv-microvm relays each of them into the guest
 * as a unix socket. This program binds guest 127.0.0.1:<port> for each pair
 * and forwards every accepted connection to the matching unix socket, so the
 * agent's HTTPS_PROXY and gateway URLs keep their host values.
 *
 *   rv-guest-relay [<port>=<absolute unix socket path> ...]
 *
 * It is the container's init process. With no pairs it only idles, so a
 * launch without relayed services still has a long-lived init.
 *
 *   rv-guest-relay --exec-sized <absolute path> [args...]
 *
 * Second role, for terminal launches: wait (at most 2 s) until stdin's pty
 * has a window size, then exec the command. vminitd creates the guest pty
 * at 0x0 and rv-microvm can only resize it after the process starts.
 * Prints "ready\n" on stdout once every listener is bound. Setup failures
 * exit 1 before "ready". Not an SPM target: built statically for Linux by
 * Scripts/build-guest-relay.sh and natively by tests/run.sh.
 */
#define _POSIX_C_SOURCE 200809L
/* struct winsize and TIOCGWINSZ for the native macOS test build. */
#define _DARWIN_C_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define RV_RELAY_MAX_PAIRS 8
#define RV_RELAY_BUFFER 65536

struct relay_pair {
    int port;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int listener;
};

static int parse_pair(const char *argument, struct relay_pair *pair) {
    const char *equals = strchr(argument, '=');
    if (equals == NULL || equals == argument) {
        return -1;
    }
    char *end = NULL;
    errno = 0;
    long port = strtol(argument, &end, 10);
    if (errno != 0 || end != equals || port < 1 || port > 65535) {
        return -1;
    }
    const char *path = equals + 1;
    size_t length = strlen(path);
    if (path[0] != '/' || length >= sizeof(pair->path)) {
        return -1;
    }
    pair->port = (int)port;
    memcpy(pair->path, path, length + 1);
    pair->listener = -1;
    return 0;
}

static int bind_loopback(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)port);
    /* 127.0.0.1. INADDR_LOOPBACK is hidden by strict POSIX headers on Darwin. */
    address.sin_addr.s_addr = htonl(0x7f000001u);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 64) != 0) {
        close(fd);
        return -1;
    }
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

static int connect_unix(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, strlen(path) + 1);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int write_all(int fd, const char *buffer, ssize_t length) {
    while (length > 0) {
        ssize_t written = write(fd, buffer, (size_t)length);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        buffer += written;
        length -= written;
    }
    return 0;
}

/*
 * One direction of a full-duplex copy. Reads from `from` only while the
 * buffer is empty and writes to `to` only while it holds bytes, so a peer
 * that stops reading never stalls the other direction.
 */
struct direction {
    int from;
    int to;
    char buffer[RV_RELAY_BUFFER];
    size_t start;
    size_t end;
    int eof;
    int done;
};

static void direction_init(struct direction *d, int from, int to) {
    d->from = from;
    d->to = to;
    d->start = 0;
    d->end = 0;
    d->eof = 0;
    d->done = 0;
}

/* Returns -1 when the connection must be torn down. */
static int direction_step(struct direction *d, short from_events, short to_events) {
    if (d->done) {
        return 0;
    }
    if (d->start == d->end && d->eof == 0 && (from_events & (POLLIN | POLLHUP | POLLERR)) != 0) {
        ssize_t got = read(d->from, d->buffer, sizeof(d->buffer));
        if (got > 0) {
            d->start = 0;
            d->end = (size_t)got;
        } else if (got == 0) {
            d->eof = 1;
        } else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            return -1;
        }
    }
    if (d->start < d->end && (to_events & (POLLOUT | POLLERR | POLLHUP)) != 0) {
        ssize_t sent = write(d->to, d->buffer + d->start, d->end - d->start);
        if (sent > 0) {
            d->start += (size_t)sent;
        } else if (sent < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            return -1;
        }
    }
    if (d->eof && d->start == d->end) {
        (void)shutdown(d->to, SHUT_WR);
        d->done = 1;
    }
    return 0;
}

static short direction_read_events(const struct direction *d) {
    return (d->done == 0 && d->eof == 0 && d->start == d->end) ? POLLIN : 0;
}

static short direction_write_events(const struct direction *d) {
    return (d->done == 0 && d->start < d->end) ? POLLOUT : 0;
}

/* Copy both directions until both reach EOF or either side fails. */
static void splice_pair(int a, int b) {
    static struct direction up;
    static struct direction down;
    if (fcntl(a, F_SETFL, fcntl(a, F_GETFL) | O_NONBLOCK) != 0 ||
        fcntl(b, F_SETFL, fcntl(b, F_GETFL) | O_NONBLOCK) != 0) {
        return;
    }
    direction_init(&up, a, b);
    direction_init(&down, b, a);
    while (up.done == 0 || down.done == 0) {
        struct pollfd fds[2];
        fds[0].fd = a;
        fds[0].events = (short)(direction_read_events(&up) | direction_write_events(&down));
        fds[1].fd = b;
        fds[1].events = (short)(direction_read_events(&down) | direction_write_events(&up));
        fds[0].revents = 0;
        fds[1].revents = 0;
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR) {
                continue;
            }
            return;
        }
        if (direction_step(&up, fds[0].revents, fds[1].revents) != 0 ||
            direction_step(&down, fds[1].revents, fds[0].revents) != 0) {
            return;
        }
    }
}

static void serve_connection(int client, const struct relay_pair *pair) {
    int upstream = connect_unix(pair->path);
    if (upstream < 0) {
        close(client);
        _exit(0);
    }
    splice_pair(client, upstream);
    close(upstream);
    close(client);
    _exit(0);
}

static int exec_when_sized(int argc, char **argv) {
    if (argc < 1 || argv[0][0] != '/') {
        fprintf(stderr, "usage: rv-guest-relay --exec-sized <absolute path> [args...]\n");
        return 1;
    }
    if (isatty(STDIN_FILENO)) {
        struct timespec tick = {0, 10 * 1000 * 1000};
        for (int i = 0; i < 200; i++) {
            struct winsize size;
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 && size.ws_row > 0) {
                break;
            }
            nanosleep(&tick, NULL);
        }
    }
    execv(argv[0], argv);
    fprintf(stderr, "rv-guest-relay: cannot execute %s: %s\n", argv[0], strerror(errno));
    return 127;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--exec-sized") == 0) {
        return exec_when_sized(argc - 2, argv + 2);
    }
    if (argc < 1 || argc - 1 > RV_RELAY_MAX_PAIRS) {
        fprintf(stderr, "usage: rv-guest-relay [<port>=<unix socket path> ...] (at most %d)\n",
                RV_RELAY_MAX_PAIRS);
        return 1;
    }
    struct relay_pair pairs[RV_RELAY_MAX_PAIRS];
    int count = argc - 1;
    for (int i = 0; i < count; i++) {
        if (parse_pair(argv[i + 1], &pairs[i]) != 0) {
            fprintf(stderr, "rv-guest-relay: invalid relay %s\n", argv[i + 1]);
            return 1;
        }
        for (int j = 0; j < i; j++) {
            if (pairs[j].port == pairs[i].port) {
                fprintf(stderr, "rv-guest-relay: duplicate port %d\n", pairs[i].port);
                return 1;
            }
        }
    }
    /* Children are not waited for. A peer that closes early is not fatal. */
    signal(SIGCHLD, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    for (int i = 0; i < count; i++) {
        pairs[i].listener = bind_loopback(pairs[i].port);
        if (pairs[i].listener < 0) {
            fprintf(stderr, "rv-guest-relay: cannot listen on 127.0.0.1:%d: %s\n", pairs[i].port,
                    strerror(errno));
            return 1;
        }
    }
    if (write_all(STDOUT_FILENO, "ready\n", 6) != 0) {
        return 1;
    }
    if (count == 0) {
        for (;;) {
            pause();
        }
    }
    struct pollfd fds[RV_RELAY_MAX_PAIRS];
    for (int i = 0; i < count; i++) {
        fds[i].fd = pairs[i].listener;
        fds[i].events = POLLIN;
    }
    for (;;) {
        if (poll(fds, (nfds_t)count, -1) < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "rv-guest-relay: poll failed: %s\n", strerror(errno));
            return 1;
        }
        for (int i = 0; i < count; i++) {
            if ((fds[i].revents & POLLIN) == 0) {
                continue;
            }
            int client = accept(pairs[i].listener, NULL, NULL);
            if (client < 0) {
                continue;
            }
            pid_t child = fork();
            if (child == 0) {
                for (int j = 0; j < count; j++) {
                    close(pairs[j].listener);
                }
                serve_connection(client, &pairs[i]);
            }
            close(client);
        }
    }
}
