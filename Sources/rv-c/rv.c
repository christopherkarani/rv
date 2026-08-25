#include "json_escape.h"
#include "json_reply.h"

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/wait.h>
#include <uuid/uuid.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>

extern char **environ;

#define RV_MACH_SERVICE "dev.rv.evaluate"
#define RV_IPC_KEY "rv.ipc"
#define RV_CLIENT_SEMVER "1.0.0"
#define RV_STDIN_XPC_MAX 1048576
#define RV_XPC_TIMEOUT_MS 700

struct ByteBuf {
    unsigned char *p;
    size_t len;
    size_t cap;
    int has_nul;
};

enum BufferReadResult {
    BUF_READ_ERROR = -1,
    BUF_READ_OK = 0,
    BUF_READ_LIMIT = 1
};

static void buf_free(struct ByteBuf *b) {
    free(b->p);
    b->p = NULL;
    b->len = 0;
    b->cap = 0;
    b->has_nul = 0;
}

static int buf_grow_to(struct ByteBuf *b, size_t add, size_t max_cap) {
    size_t need;
    size_t ncap;
    unsigned char *np;
    if (add > (size_t)-1 - b->len) {
        return -1;
    }
    need = b->len + add;
    if (need > max_cap) {
        return -1;
    }
    if (need <= b->cap) {
        return 0;
    }
    ncap = b->cap == 0 ? 4096 : b->cap;
    if (ncap > max_cap) {
        ncap = max_cap;
    }
    while (ncap < need) {
        if (ncap > max_cap / 2) {
            ncap = max_cap;
            break;
        }
        ncap *= 2;
    }
    np = (unsigned char *)realloc(b->p, ncap);
    if (np == NULL) {
        return -1;
    }
    b->p = np;
    b->cap = ncap;
    return 0;
}

static int buf_read_fd_limited(struct ByteBuf *b, int fd, size_t limit) {
    const size_t max_cap = limit == SIZE_MAX ? SIZE_MAX : limit + 1;
    for (;;) {
        size_t room;
        ssize_t r;

        if (b->len == limit) {
            unsigned char extra;
            do {
                r = read(fd, &extra, 1);
            } while (r < 0 && errno == EINTR);
            if (r < 0) {
                return BUF_READ_ERROR;
            }
            if (r == 0) {
                return BUF_READ_OK;
            }
            if (buf_grow_to(b, 1, max_cap) != 0) {
                return BUF_READ_ERROR;
            }
            b->p[b->len] = extra;
            if (extra == 0) {
                b->has_nul = 1;
            }
            b->len += 1;
            return BUF_READ_LIMIT;
        }

        room = limit - b->len;
        if (room > 4096) {
            room = 4096;
        }
        if (buf_grow_to(b, room, max_cap) != 0) {
            return BUF_READ_ERROR;
        }
        r = read(fd, b->p + b->len, room);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            return BUF_READ_ERROR;
        }
        if (r == 0) {
            return BUF_READ_OK;
        }
        if (memchr(b->p + b->len, 0, (size_t)r) != NULL) {
            b->has_nul = 1;
        }
        b->len += (size_t)r;
    }
}

static int buf_read_fd(struct ByteBuf *b, int fd) {
    return buf_read_fd_limited(b, fd, SIZE_MAX);
}

static int write_all(int fd, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    while (n > 0) {
        ssize_t w = write(fd, b, n);
        if (w < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (w == 0) {
            return -1;
        }
        b += (size_t)w;
        n -= (size_t)w;
    }
    return 0;
}

static int copy_fd(int input_fd, int output_fd) {
    unsigned char buffer[8192];
    for (;;) {
        ssize_t r = read(input_fd, buffer, sizeof buffer);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (r == 0) {
            return 0;
        }
        if (write_all(output_fd, buffer, (size_t)r) != 0) {
            return -1;
        }
    }
}

static int is_help_flag(const char *s) {
    return strcmp(s, "-h") == 0 || strcmp(s, "--help") == 0;
}

static int is_valid_host(const char *s) {
    return strcmp(s, "grok") == 0
        || strcmp(s, "pi") == 0
        || strcmp(s, "opencode") == 0
        || strcmp(s, "claude") == 0;
}

/* 0 = pipe, 1 = exec rv-cli with the same argv. */
static int parse_hook_argv(int argc, char **argv, const char **host_out) {
    int i;
    const char *host = "grok";
    for (i = 1; i < argc; i++) {
        if (is_help_flag(argv[i])) {
            return 1;
        }
    }
    if (argc < 2 || strcmp(argv[1], "hook") != 0) {
        return 1;
    }
    for (i = 2; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--host") == 0) {
            if (i + 1 >= argc) {
                return 1;
            }
            i += 1;
            host = argv[i];
            continue;
        }
        if (strncmp(a, "--host=", 7) == 0) {
            host = a + 7;
            continue;
        }
        return 1;
    }
    if (!is_valid_host(host)) {
        return 1;
    }
    *host_out = host;
    return 0;
}

static char g_cli_path[PATH_MAX];

static const char *find_rv_cli(const char *argv0) {
    char resolved[PATH_MAX];
    if (argv0 != NULL && realpath(argv0, resolved) != NULL) {
        char *slash = strrchr(resolved, '/');
        if (slash != NULL) {
            *slash = '\0';
            int n = snprintf(g_cli_path, sizeof g_cli_path, "%s/rv-cli", resolved);
            if (n > 0 && n < (int)sizeof g_cli_path && access(g_cli_path, X_OK) == 0) {
                return g_cli_path;
            }
        }
    }
    {
        const char *home = getenv("HOME");
        if (home != NULL && home[0] != '\0') {
            int n = snprintf(g_cli_path, sizeof g_cli_path, "%s/.local/bin/rv-cli", home);
            if (n > 0 && n < (int)sizeof g_cli_path && access(g_cli_path, X_OK) == 0) {
                return g_cli_path;
            }
        }
    }
    return NULL;
}

/* Grok: empty+0 is allow; exit 2 is deny. Any other exit fail-opens. */
static void last_resort(void) {
    _exit(2);
}

static void exec_same_argv(char **argv) {
    const char *cli = find_rv_cli(argv[0]);
    if (cli == NULL) {
        /*
         * Operator argv (doctor, packs, status, help) must not die silently:
         * silence makes `rv doctor` unreachable in exactly the broken state
         * it exists to diagnose. Hook miss paths never come through here;
         * they keep the silent last_resort deny.
         */
        fprintf(stderr,
                "rv: rv-cli not found next to %s or at $HOME/.local/bin/rv-cli\n",
                argv[0] != NULL ? argv[0] : "rv");
        _exit(2);
    }
    execve(cli, argv, environ);
    fprintf(stderr, "rv: cannot exec %s: %s\n", cli, strerror(errno));
    _exit(2);
}

static void miss_replay_with_tail(
    char **argv,
    const char *host,
    const unsigned char *stdin_bytes,
    size_t stdin_len,
    int tail_fd
) {
    const char *cli;
    int in_pipe[2];
    int out_pipe[2];
    pid_t pid;
    int wr;
    struct ByteBuf out;
    int st;

    cli = find_rv_cli(argv[0]);
    if (cli == NULL) {
        last_resort();
    }
    if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0) {
        last_resort();
    }
    pid = fork();
    if (pid < 0) {
        last_resort();
    }
    if (pid == 0) {
        char *av[5];
        close(in_pipe[1]);
        close(out_pipe[0]);
        if (dup2(in_pipe[0], STDIN_FILENO) < 0) {
            last_resort();
        }
        if (dup2(out_pipe[1], STDOUT_FILENO) < 0) {
            last_resort();
        }
        close(in_pipe[0]);
        close(out_pipe[1]);
        av[0] = (char *)cli;
        av[1] = "hook";
        av[2] = "--host";
        av[3] = (char *)host;
        av[4] = NULL;
        execve(cli, av, environ);
        last_resort();
    }
    close(in_pipe[0]);
    close(out_pipe[1]);
    /*
     * rv-cli reads stdin to EOF before producing its reply. Keep this write
     * serial with the existing child contract; a streaming child would need
     * a full-duplex pump here to avoid a pipe cycle.
     */
    wr = write_all(in_pipe[1], stdin_bytes, stdin_len);
    if (wr == 0 && tail_fd >= 0) {
        wr = copy_fd(tail_fd, in_pipe[1]);
    }
    close(in_pipe[1]);
    memset(&out, 0, sizeof out);
    if (buf_read_fd(&out, out_pipe[0]) != 0) {
        close(out_pipe[0]);
        kill(pid, SIGKILL);
        waitpid(pid, &st, 0);
        buf_free(&out);
        last_resort();
    }
    close(out_pipe[0]);
    if (waitpid(pid, &st, 0) < 0) {
        buf_free(&out);
        last_resort();
    }
    if (wr != 0) {
        buf_free(&out);
        last_resort();
    }
    if (WIFEXITED(st)) {
        int status = WEXITSTATUS(st);
        if (write_all(STDOUT_FILENO, out.p, out.len) != 0) {
            buf_free(&out);
            last_resort();
        }
        buf_free(&out);
        _exit(status);
    }
    buf_free(&out);
    last_resort();
}

static void miss_replay(
    char **argv,
    const char *host,
    const unsigned char *stdin_bytes,
    size_t stdin_len
) {
    miss_replay_with_tail(argv, host, stdin_bytes, stdin_len, -1);
}

static int major_of(const char *semver) {
    const char *dot;
    size_t n;
    size_t i;
    unsigned long v;
    char buf[16];
    char *ep;
    if (semver == NULL || semver[0] == '\0') {
        return -1;
    }
    dot = strchr(semver, '.');
    n = dot == NULL ? strlen(semver) : (size_t)(dot - semver);
    if (n == 0 || n >= sizeof buf) {
        return -1;
    }
    for (i = 0; i < n; i++) {
        if (semver[i] < '0' || semver[i] > '9') {
            return -1;
        }
    }
    memcpy(buf, semver, n);
    buf[n] = '\0';
    v = strtoul(buf, &ep, 10);
    if (ep == buf || *ep != '\0' || v > (unsigned long)INT_MAX) {
        return -1;
    }
    return (int)v;
}

static int is_major_skew(const char *client, const char *service) {
    int c = major_of(client);
    int s = major_of(service);
    if (c < 0 || s < 0) {
        return 0;
    }
    return c != s;
}

static const char kIdPrefix[] = "{\"id\":\"";
static const char kAfterId[] =
    "\",\"method\":{\"hookEvaluate\":{\"clientSemver\":\"1.0.0\",\"host\":\"";
static const char kAfterHost[] = "\",\"stdin\":\"";
static const char kSuffix[] = "\"}},\"protocol\":\"rv.ipc.v1\"}";

static char *build_request(
    const char *host,
    const unsigned char *stdin_bytes,
    size_t stdin_len,
    size_t *out_len,
    char request_id[37]
) {
    uuid_t u;
    char uuid[37];
    size_t esc_len = 0;
    size_t host_len;
    size_t total;
    char *json;
    char *w;
    size_t wrote = 0;

    if (rv_json_escape(stdin_bytes, stdin_len, NULL, 0, &esc_len) != 0) {
        return NULL;
    }
    uuid_generate(u);
    uuid_unparse_lower(u, uuid);
    memcpy(request_id, uuid, sizeof uuid);
    host_len = strlen(host);
    total = (sizeof kIdPrefix - 1) + 36 + (sizeof kAfterId - 1) + host_len
        + (sizeof kAfterHost - 1) + esc_len + (sizeof kSuffix - 1);
    json = (char *)malloc(total + 1);
    if (json == NULL) {
        return NULL;
    }
    w = json;
    memcpy(w, kIdPrefix, sizeof kIdPrefix - 1);
    w += sizeof kIdPrefix - 1;
    memcpy(w, uuid, 36);
    w += 36;
    memcpy(w, kAfterId, sizeof kAfterId - 1);
    w += sizeof kAfterId - 1;
    memcpy(w, host, host_len);
    w += host_len;
    memcpy(w, kAfterHost, sizeof kAfterHost - 1);
    w += sizeof kAfterHost - 1;
    if (rv_json_escape(stdin_bytes, stdin_len, w, esc_len + 1, &wrote) != 0) {
        free(json);
        return NULL;
    }
    w += wrote;
    memcpy(w, kSuffix, sizeof kSuffix - 1);
    w += sizeof kSuffix - 1;
    *w = '\0';
    *out_len = (size_t)(w - json);
    return json;
}

struct XpcWait {
    dispatch_semaphore_t sem;
    xpc_object_t reply;
};

static int xpc_hook_evaluate(
    const void *json,
    size_t json_len,
    char **reply_json,
    size_t *reply_len
) {
    xpc_connection_t conn;
    xpc_object_t msg;
    struct XpcWait *wait;
    long timed_out;
    xpc_type_t type;
    const void *data;
    size_t n = 0;
    char *copy;

    conn = xpc_connection_create_mach_service(RV_MACH_SERVICE, NULL, 0);
    if (conn == NULL) {
        return -1;
    }
    wait = (struct XpcWait *)calloc(1, sizeof *wait);
    if (wait == NULL) {
        xpc_release(conn);
        return -1;
    }
    wait->sem = dispatch_semaphore_create(0);
    if (wait->sem == NULL) {
        free(wait);
        xpc_release(conn);
        return -1;
    }

    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        (void)event;
    });
    xpc_connection_resume(conn);

    msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_data(msg, RV_IPC_KEY, json, json_len);
    xpc_connection_send_message_with_reply(
        conn,
        msg,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(xpc_object_t event) {
            if (event != NULL) {
                wait->reply = xpc_retain(event);
            }
            dispatch_semaphore_signal(wait->sem);
        }
    );
    xpc_release(msg);

    timed_out = dispatch_semaphore_wait(
        wait->sem,
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)RV_XPC_TIMEOUT_MS * (int64_t)NSEC_PER_MSEC
        )
    );
    xpc_connection_cancel(conn);
    xpc_release(conn);

    if (timed_out != 0) {
        /*
         * Intentional orphan on timeout: after xpc_connection_cancel the
         * reply block may still fire once and write wait->reply, so freeing
         * `wait` here would race that block. The struct and its semaphore
         * live until process exit (miss_replay / _exit), bounded to one
         * small allocation per timed-out invocation.
         */
        return -1;
    }
    if (wait->reply == NULL) {
        dispatch_release(wait->sem);
        free(wait);
        return -1;
    }
    type = xpc_get_type(wait->reply);
    if (type == XPC_TYPE_ERROR || type != XPC_TYPE_DICTIONARY) {
        xpc_release(wait->reply);
        dispatch_release(wait->sem);
        free(wait);
        return -1;
    }
    data = xpc_dictionary_get_data(wait->reply, RV_IPC_KEY, &n);
    if (data == NULL || n == 0) {
        xpc_release(wait->reply);
        dispatch_release(wait->sem);
        free(wait);
        return -1;
    }
    copy = (char *)malloc(n + 1);
    if (copy == NULL) {
        xpc_release(wait->reply);
        dispatch_release(wait->sem);
        free(wait);
        return -1;
    }
    memcpy(copy, data, n);
    copy[n] = '\0';
    *reply_json = copy;
    *reply_len = n;
    xpc_release(wait->reply);
    dispatch_release(wait->sem);
    free(wait);
    return 0;
}

int main(int argc, char **argv) {
    const char *host = NULL;
    struct ByteBuf stdin_buf;
    char *request = NULL;
    size_t request_len = 0;
    char *reply_json = NULL;
    size_t reply_len = 0;
    char request_id[37];
    struct RvHookReply reply;

    /*
     * A replay child that dies before consuming stdin must not kill this
     * parent by signal 13: EPIPE then surfaces from write_all and routes to
     * the deterministic last_resort deny instead.
     */
    signal(SIGPIPE, SIG_IGN);

    if (parse_hook_argv(argc, argv, &host) != 0) {
        exec_same_argv(argv);
    }

    memset(&stdin_buf, 0, sizeof stdin_buf);
    int stdin_read = buf_read_fd_limited(&stdin_buf, STDIN_FILENO, RV_STDIN_XPC_MAX);
    if (stdin_read == BUF_READ_ERROR) {
        buf_free(&stdin_buf);
        last_resort();
    }

    if (stdin_read == BUF_READ_LIMIT) {
        miss_replay_with_tail(argv, host, stdin_buf.p, stdin_buf.len, STDIN_FILENO);
    }

    if (stdin_buf.has_nul
        || stdin_buf.len > RV_STDIN_XPC_MAX
        || !rv_utf8_is_valid(stdin_buf.p, stdin_buf.len))
    {
        miss_replay(argv, host, stdin_buf.p, stdin_buf.len);
    }

    request = build_request(host, stdin_buf.p, stdin_buf.len, &request_len, request_id);
    if (request == NULL) {
        miss_replay(argv, host, stdin_buf.p, stdin_buf.len);
    }

    if (xpc_hook_evaluate(request, request_len, &reply_json, &reply_len) != 0) {
        free(request);
        miss_replay(argv, host, stdin_buf.p, stdin_buf.len);
    }
    free(request);

    memset(&reply, 0, sizeof reply);
    if (rv_parse_hook_reply(reply_json, reply_len, &reply) != RV_HOOK_REPLY_OK) {
        free(reply_json);
        miss_replay(argv, host, stdin_buf.p, stdin_buf.len);
    }
    free(reply_json);

    if (!reply.has_id || strcasecmp(reply.id, request_id) != 0) {
        rv_hook_reply_free(&reply);
        miss_replay(argv, host, stdin_buf.p, stdin_buf.len);
    }

    /*
     * Same semver law as the Swift CLI client: an unprovable reply (no
     * serviceSemver at all) or a major-skewed one must not be trusted —
     * replay through rv-cli's in-process evaluation instead.
     */
    if (!reply.has_service_semver
        || is_major_skew(RV_CLIENT_SEMVER, reply.service_semver))
    {
        rv_hook_reply_free(&reply);
        miss_replay(argv, host, stdin_buf.p, stdin_buf.len);
    }

    if (write_all(STDOUT_FILENO, reply.stdout_bytes, reply.stdout_len) != 0) {
        rv_hook_reply_free(&reply);
        buf_free(&stdin_buf);
        last_resort();
    }
    {
        int32_t code = reply.exit_code;
        rv_hook_reply_free(&reply);
        buf_free(&stdin_buf);
        return (int)code;
    }
}
