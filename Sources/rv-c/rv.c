#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "json_escape.h"
#include "json_reply.h"
#include "evaluation_route.h"
#include "daemon_trust.h"
#include "hook_fallback.h"
#include "observe_gate.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <xpc/xpc.h>
#else
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#endif

extern char **environ;

/* ManagedPolicyLocation.installedDirectory. Test builds may pin this and
 * the config path to fixtures at compile time; release builds never do,
 * and neither is ever read from the environment. */
#ifndef RV_HOOK_MANAGED_POLICY_DIR
#ifdef __APPLE__
#define RV_HOOK_MANAGED_POLICY_DIR "/Library/Application Support/RV/managed"
#else
#define RV_HOOK_MANAGED_POLICY_DIR "/etc/rv/managed"
#endif
#endif

/* systemd's per-user runtime root: rvd's unit gets
 * XDG_RUNTIME_DIR=/run/user/<uid> and binds <that>/rv/evaluate.sock
 * (UnixSocketPath.production). Test builds may pin a fixture root; release
 * builds never do, and it is never read from the environment. */
#ifndef RV_HOOK_USER_RUNTIME_ROOT
#define RV_HOOK_USER_RUNTIME_ROOT "/run/user"
#endif

#define RV_MACH_SERVICE "dev.rv.evaluate"
#define RV_IPC_KEY "rv.ipc"
#define RV_STDIN_KEY "rv.stdin"
#define RV_CLIENT_SEMVER "1.0.0"
#define RV_STDIN_XPC_MAX 1048576
/* Hello covers a launchd on-demand spawn of rvd; hookEvaluate covers a
 * cold judge load (the daemon enforces its own shorter deadline). */
#define RV_HELLO_TIMEOUT_MS 3000
#define RV_EVALUATE_TIMEOUT_MS 8000
#define RV_HOOK_RETRY_DELAY_MS 200
/* The evaluate request is never sent later than this after the process
 * started. rvd's own budget (HookDeadline, 7 s) runs from when the request
 * arrives, so this cutoff bounds when rvd can still spend a grant:
 * 5 s + 7 s < the 15 s host shim. Without it, two 3 s hellos plus the one
 * retry could deliver the request about 12 s in, and rvd could spend an
 * allow-once grant after the host had already given up. Past the cutoff the
 * hook fails closed without sending anything. */
#define RV_EVALUATE_SEND_CUTOFF_MS 5000

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

static int is_help_flag(const char *s) {
    return strcmp(s, "-h") == 0 || strcmp(s, "--help") == 0;
}

static int is_valid_host(const char *s) {
    return strcmp(s, "grok") == 0
        || strcmp(s, "pi") == 0
        || strcmp(s, "opencode") == 0
        || strcmp(s, "claude") == 0
        || strcmp(s, "openclaw") == 0
        || strcmp(s, "hermes") == 0
        || strcmp(s, "codex") == 0
        || strcmp(s, "cursor") == 0
        || strcmp(s, "antigravity") == 0
        || strcmp(s, "muse") == 0;
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

static const char *find_rv_cli(void) {
    char executable[PATH_MAX];
    char resolved[PATH_MAX];
    /* argv[0], PATH and HOME are not an authority for locating trusted code. */
#ifdef __APPLE__
    uint32_t capacity = sizeof executable;
    if (_NSGetExecutablePath(executable, &capacity) != 0) {
        return NULL;
    }
#else
    ssize_t size = readlink("/proc/self/exe", executable, sizeof executable - 1);
    if (size < 0 || size >= (ssize_t)sizeof executable - 1) {
        return NULL;
    }
    executable[size] = '\0';
#endif
    if (realpath(executable, resolved) != NULL) {
        char *slash = strrchr(resolved, '/');
        if (slash != NULL) {
            *slash = '\0';
            int n = snprintf(g_cli_path, sizeof g_cli_path, "%s/rv-cli", resolved);
            if (n > 0 && n < (int)sizeof g_cli_path && access(g_cli_path, X_OK) == 0) {
                return g_cli_path;
            }
        }
    }
    return NULL;
}

static void exec_same_argv(char **argv) {
    const char *cli = find_rv_cli();
    if (cli == NULL) {
        /*
         * Operator argv (doctor, packs, status, help) must not die silently:
         * silence makes `rv doctor` unreachable in exactly the broken state
         * it exists to diagnose. Hook miss paths never come through here;
         * they emit an explicit host-compatible denial.
         */
        fprintf(stderr,
                "rv: rv-cli not found next to the running executable (%s)\n",
                argv[0] != NULL ? argv[0] : "rv");
        _exit(2);
    }
    execve(cli, argv, environ);
    fprintf(stderr, "rv: cannot exec %s: %s\n", cli, strerror(errno));
    _exit(2);
}

/* The owner's config.json puts this host in observe mode (observe_gate.h).
 * The home comes from the passwd entry, never $HOME: hook environment can
 * come from project-scoped host config an agent writes. */
static int owner_chose_observe(const char *host) {
#ifdef RV_HOOK_OBSERVE_CONFIG_PATH
    return rv_observe_gate_applies(RV_HOOK_OBSERVE_CONFIG_PATH, RV_HOOK_MANAGED_POLICY_DIR, host);
#else
    char path[PATH_MAX];
    struct passwd *pw = getpwuid(getuid());
    int n;
    if (pw == NULL || pw->pw_dir == NULL || pw->pw_dir[0] != '/') {
        return 0;
    }
    n = snprintf(path, sizeof path, "%s/.config/rv/config.json", pw->pw_dir);
    if (n <= 0 || (size_t)n >= sizeof path) {
        return 0;
    }
    return rv_observe_gate_applies(path, RV_HOOK_MANAGED_POLICY_DIR, host);
#endif
}

/* No CLI replay: neither a transport failure nor malformed input grants
 * authority. Renders the classified fallback (hook_fallback.h): input
 * failures always deny; daemon-unavailable classes follow
 * RV_HOOK_WHEN_DOWN (ask by default), except that an unreachable daemon
 * steps aside when the owner chose observe mode and RV_HOOK_WHEN_DOWN is
 * not deny. */
static void fail_hook(const char *host, enum RvHookFailure failure) {
    struct RvHookFallback fallback;
    enum RvWhenDown mode = rv_when_down_parse(getenv(RV_HOOK_WHEN_DOWN_ENV));
    /* Only an absent daemon (a slow one would still enforce rv's
     * self-protection); an explicit RV_HOOK_WHEN_DOWN=deny is stricter and wins. */
    if (mode == RV_WHEN_DOWN_ASK && failure == RV_HOOK_FAIL_UNREACHABLE
        && owner_chose_observe(host)) {
        mode = RV_WHEN_DOWN_OBSERVE;
    }
    if (rv_hook_fallback_render(host, failure, mode, &fallback) != 0) {
        /* Unreachable for valid hosts; exit 2 blocks on Claude and Codex. */
        _exit(2);
    }
    (void)write_all(STDOUT_FILENO, fallback.out, strlen(fallback.out));
    (void)write_all(STDERR_FILENO, fallback.err, strlen(fallback.err));
    _exit(fallback.exit_code);
}

static long long rv_started_ms = -1;

static long long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* True once the evaluate request may no longer be sent (see
 * RV_EVALUATE_SEND_CUTOFF_MS). A missing start time never blocks. */
static int past_evaluate_send_cutoff(void) {
    if (rv_started_ms < 0) {
        return 0;
    }
    return monotonic_ms() - rv_started_ms > RV_EVALUATE_SEND_CUTOFF_MS;
}

static void sleep_ms(long ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
}

/* RFC 4122 UUID v4 from /dev/urandom. Not Apple-only; not libuuid. */
static int rv_uuid_v4(char out[37]) {
    unsigned char b[16];
    size_t got = 0;
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    while (got < sizeof b) {
        ssize_t n = read(fd, b + got, sizeof b - got);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            return -1;
        }
        if (n == 0) {
            close(fd);
            return -1;
        }
        got += (size_t)n;
    }
    close(fd);
    b[6] = (unsigned char)((b[6] & 0x0f) | 0x40);
    b[8] = (unsigned char)((b[8] & 0x3f) | 0x80);
    (void)snprintf(
        out,
        37,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[0],
        b[1],
        b[2],
        b[3],
        b[4],
        b[5],
        b[6],
        b[7],
        b[8],
        b[9],
        b[10],
        b[11],
        b[12],
        b[13],
        b[14],
        b[15]
    );
    return 0;
}

static const char kIdPrefix[] = "{\"id\":\"";
static const char kAfterId[] =
    "\",\"method\":{\"hookEvaluate\":{\"clientSemver\":\"1.0.0\",\"host\":\"";
#ifdef __APPLE__
/* stdin travels as xpc_data `rv.stdin`, not a JSON string. */
static const char kAfterHost[] = "\"}},\"protocol\":\"rv.ipc.v1\"}";
#else
static const char kAfterHost[] = "\",\"stdin\":\"";
static const char kSuffix[] = "\"}},\"protocol\":\"rv.ipc.v1\"}";
#endif

static char *build_request(
    const char *host,
    const unsigned char *stdin_bytes,
    size_t stdin_len,
    size_t *out_len,
    char request_id[37]
) {
    char uuid[37];
    size_t host_len;
    size_t total;
    char *json;
    char *w;
#ifndef __APPLE__
    size_t esc_len = 0;
    size_t wrote = 0;

    if (rv_json_escape(stdin_bytes, stdin_len, NULL, 0, &esc_len) != 0) {
        return NULL;
    }
#else
    (void)stdin_bytes;
    (void)stdin_len;
#endif
    if (rv_uuid_v4(uuid) != 0) {
        return NULL;
    }
    memcpy(request_id, uuid, sizeof uuid);
    host_len = strlen(host);
#ifdef __APPLE__
    total = (sizeof kIdPrefix - 1) + 36 + (sizeof kAfterId - 1) + host_len
        + (sizeof kAfterHost - 1);
#else
    total = (sizeof kIdPrefix - 1) + 36 + (sizeof kAfterId - 1) + host_len
        + (sizeof kAfterHost - 1) + esc_len + (sizeof kSuffix - 1);
#endif
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
#ifndef __APPLE__
    if (rv_json_escape(stdin_bytes, stdin_len, w, esc_len + 1, &wrote) != 0) {
        free(json);
        return NULL;
    }
    w += wrote;
    memcpy(w, kSuffix, sizeof kSuffix - 1);
    w += sizeof kSuffix - 1;
#endif
    *w = '\0';
    *out_len = (size_t)(w - json);
    return json;
}

#ifdef __APPLE__
struct XpcWait {
    dispatch_semaphore_t sem;
    xpc_object_t reply;
};

/* One XPC request/reply round trip. Returns a retained, sender-verified
 * reply dictionary, or NULL with *failure set (and *retryable set when
 * the failure is transient: timeout, connection invalid/interrupted).
 *
 * UNREACHABLE (the only class observe mode may step aside for) is
 * reported only when `discovery` is set and launchd refuses the Mach
 * service connection (XPC_ERROR_CONNECTION_INVALID: not registered for
 * this user), so nothing reached rvd. Every other connection error is
 * CONNECTION: an interrupted discovery means a live rvd went away, and
 * after discovery the daemon's identity is verified, so a drop there may
 * be rvd draining (which an agent can trigger), never proof of absence. */
static xpc_object_t xpc_exchange(
    xpc_connection_t conn,
    const void *json,
    size_t json_len,
    const void *stdin_bytes,
    size_t stdin_len,
    int64_t timeout_ms,
    int discovery,
    enum RvHookFailure *failure,
    int *retryable
) {
    xpc_object_t msg;
    struct XpcWait *wait;
    long timed_out;
    xpc_object_t reply;

    *failure = RV_HOOK_FAIL_CONNECTION;
    *retryable = 0;
    wait = (struct XpcWait *)calloc(1, sizeof *wait);
    if (wait == NULL) {
        return NULL;
    }
    wait->sem = dispatch_semaphore_create(0);
    if (wait->sem == NULL) {
        free(wait);
        return NULL;
    }

    msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_data(msg, RV_IPC_KEY, json, json_len);
    xpc_dictionary_set_data(
        msg,
        RV_STDIN_KEY,
        stdin_bytes != NULL ? stdin_bytes : "",
        stdin_len
    );
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
        dispatch_time(DISPATCH_TIME_NOW, timeout_ms * (int64_t)NSEC_PER_MSEC)
    );
    if (timed_out != 0) {
        /*
         * Intentional orphan on timeout: the reply block may still fire
         * once and write wait->reply, so freeing `wait` here would race
         * that block. The struct and its semaphore live until process
         * exit (_exit), bounded to one small allocation per timed-out
         * exchange (at most two per invocation: one retry).
         */
        *failure = RV_HOOK_FAIL_TIMEOUT;
        *retryable = 1;
        return NULL;
    }
    reply = wait->reply;
    dispatch_release(wait->sem);
    free(wait);
    if (reply == NULL) {
        return NULL;
    }
    if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
        /* Not registered / launchd refused (INVALID) or rvd exited
         * mid-exchange (INTERRUPTED, e.g. an idle-exit race). */
        *retryable = reply == XPC_ERROR_CONNECTION_INVALID
            || reply == XPC_ERROR_CONNECTION_INTERRUPTED;
        if (discovery && reply == XPC_ERROR_CONNECTION_INVALID) {
            *failure = RV_HOOK_FAIL_UNREACHABLE;
        }
        xpc_release(reply);
        return NULL;
    }
    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        *failure = RV_HOOK_FAIL_PROTOCOL;
        xpc_release(reply);
        return NULL;
    }
    /* A Mach service name is not server identity. Do not consume
     * authority-bearing results from an unverified daemon. */
    if (!rv_verify_daemon_reply(reply)) {
        *failure = RV_HOOK_FAIL_UNTRUSTED;
        /* A stale rvd (binary replaced by an upgrade) answers once and then
         * exits; launchd starts the new binary on the next connect. Callers
         * zero this after the hookEvaluate exchange, so it only retries
         * Hellos. */
        *retryable = 1;
        xpc_release(reply);
        return NULL;
    }
    return reply;
}

/* Strict HelloAck-ok scan: `"ok":true` outside strings, and no
 * `"skewReason"` outside strings. Anything else fails closed. */
static int hello_ack_ok(const char *p, size_t n) {
    size_t i = 0;
    int saw_ok_true = 0;
    while (i < n) {
        char c = p[i];
        if (c == '"') {
            size_t start = i + 1;
            size_t j = start;
            while (j < n && p[j] != '"') {
                if (p[j] == '\\' && j + 1 < n) {
                    j += 2;
                } else {
                    j++;
                }
            }
            if (j >= n) {
                return 0;
            }
            if (j - start == 10 && memcmp(p + start, "skewReason", 10) == 0) {
                return 0;
            }
            if (j - start == 2 && memcmp(p + start, "ok", 2) == 0) {
                size_t k = j + 1;
                while (k < n && (p[k] == ' ' || p[k] == '\t'
                                 || p[k] == '\n' || p[k] == '\r'))
                {
                    k++;
                }
                if (k < n && p[k] == ':') {
                    k++;
                    while (k < n && (p[k] == ' ' || p[k] == '\t'
                                     || p[k] == '\n' || p[k] == '\r'))
                    {
                        k++;
                    }
                    if (k + 4 <= n && memcmp(p + k, "true", 4) == 0) {
                        saw_ok_true = 1;
                    }
                }
            }
            i = j + 1;
        } else {
            i++;
        }
    }
    return saw_ok_true;
}

#define RV_ACTION_ENDPOINT_KEY "rv.action-endpoint"
static const char kHelloJson[] =
    "{\"protocol\":\"rv.ipc.v1\",\"clientSemver\":\"1.0.0\"}";

/* Mach-service discovery, then action-endpoint evaluation. Mirrors
 * XPCEvaluateClient.perform: Hello on the Mach service, Hello again on
 * the pinned endpoint, then the hook request. The Mach service answers
 * discovery only; anything else there is authorizationDenied.
 *
 * Every reply's sender is verified in xpc_exchange (daemon_trust.h)
 * before any field is consumed, exactly like the Swift client.
 *
 * Returns 0, or the failure class. *retryable is set only for transient
 * failures that happen before the hookEvaluate request is sent: once it
 * is sent the daemon may have acted on it, so it is never resent. */
static int xpc_hook_evaluate(
    const void *json,
    size_t json_len,
    const void *stdin_bytes,
    size_t stdin_len,
    char **reply_json,
    size_t *reply_len,
    int *retryable
) {
    xpc_connection_t discovery = NULL;
    xpc_connection_t actions = NULL;
    xpc_object_t reply = NULL;
    xpc_object_t endpoint_obj = NULL;
    const void *data;
    size_t n = 0;
    char *copy;
    enum RvHookFailure failure = RV_HOOK_FAIL_CONNECTION;
    int ok = 0;

    *retryable = 0;
    discovery = xpc_connection_create_mach_service(RV_MACH_SERVICE, NULL, 0);
    if (discovery == NULL) {
        return RV_HOOK_FAIL_CONNECTION;
    }
    xpc_connection_set_event_handler(discovery, ^(xpc_object_t event) {
        (void)event;
    });
    xpc_connection_resume(discovery);

    reply = xpc_exchange(
        discovery, kHelloJson, sizeof kHelloJson - 1, NULL, 0,
        RV_HELLO_TIMEOUT_MS, 1, &failure, retryable);
    if (reply == NULL) {
        goto out;
    }
    data = xpc_dictionary_get_data(reply, RV_IPC_KEY, &n);
    if (data == NULL || n == 0) {
        failure = RV_HOOK_FAIL_PROTOCOL;
        goto out;
    }
    if (!hello_ack_ok((const char *)data, n)) {
        failure = RV_HOOK_FAIL_UNTRUSTED;
        *retryable = 1;
        goto out;
    }
    endpoint_obj = xpc_dictionary_get_value(reply, RV_ACTION_ENDPOINT_KEY);
    if (endpoint_obj == NULL
        || xpc_get_type(endpoint_obj) != XPC_TYPE_ENDPOINT)
    {
        failure = RV_HOOK_FAIL_PROTOCOL;
        goto out;
    }
    actions = xpc_connection_create_from_endpoint(endpoint_obj);
    xpc_release(reply);
    reply = NULL;
    if (actions == NULL) {
        failure = RV_HOOK_FAIL_CONNECTION;
        goto out;
    }
    xpc_connection_set_event_handler(actions, ^(xpc_object_t event) {
        (void)event;
    });
    xpc_connection_resume(actions);

    reply = xpc_exchange(
        actions, kHelloJson, sizeof kHelloJson - 1, NULL, 0,
        RV_HELLO_TIMEOUT_MS, 0, &failure, retryable);
    if (reply == NULL) {
        goto out;
    }
    data = xpc_dictionary_get_data(reply, RV_IPC_KEY, &n);
    if (data == NULL || n == 0) {
        failure = RV_HOOK_FAIL_PROTOCOL;
        goto out;
    }
    if (!hello_ack_ok((const char *)data, n)) {
        failure = RV_HOOK_FAIL_UNTRUSTED;
        *retryable = 1;
        goto out;
    }
    xpc_release(reply);
    reply = NULL;

    if (past_evaluate_send_cutoff()) {
        /* Too late for rvd to finish before the host gives up. */
        failure = RV_HOOK_FAIL_TIMEOUT;
        *retryable = 0;
        goto out;
    }
    /* Point of no return: from here on nothing is retried. */
    reply = xpc_exchange(actions, json, json_len, stdin_bytes, stdin_len,
                         RV_EVALUATE_TIMEOUT_MS, 0, &failure, retryable);
    *retryable = 0;
    if (reply == NULL) {
        goto out;
    }
    data = xpc_dictionary_get_data(reply, RV_IPC_KEY, &n);
    if (data == NULL || n == 0) {
        failure = RV_HOOK_FAIL_PROTOCOL;
        goto out;
    }
    copy = (char *)malloc(n + 1);
    if (copy == NULL) {
        failure = RV_HOOK_FAIL_PROTOCOL;
        goto out;
    }
    memcpy(copy, data, n);
    copy[n] = '\0';
    *reply_json = copy;
    *reply_len = n;
    ok = 1;

out:
    if (reply != NULL) {
        xpc_release(reply);
    }
    if (actions != NULL) {
        xpc_connection_cancel(actions);
        xpc_release(actions);
    }
    if (discovery != NULL) {
        xpc_connection_cancel(discovery);
        xpc_release(discovery);
    }
    return ok ? 0 : (int)failure;
}
#else

#define RV_UNIX_PATH_MAX 108
#define RV_FRAME_MAX 1048576

/* Milliseconds left before the send cutoff, at least 1 (0 would mean
 * "no timeout" to SO_SNDTIMEO). */
static long remaining_send_ms(void) {
    long long left;
    if (rv_started_ms < 0) {
        return RV_EVALUATE_TIMEOUT_MS;
    }
    left = RV_EVALUATE_SEND_CUTOFF_MS - (monotonic_ms() - rv_started_ms);
    if (left < 1) {
        return 1;
    }
    return left > RV_EVALUATE_TIMEOUT_MS ? RV_EVALUATE_TIMEOUT_MS : (long)left;
}

/* Sends all of `p`, or fails with EAGAIN once the send cutoff passes: the
 * cutoff bounds when the whole request has arrived, not just when sending
 * began. A frame cut short is never evaluated by rvd. */
static int send_nosig(int fd, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    while (n > 0) {
        if (past_evaluate_send_cutoff()) {
            errno = EAGAIN;
            return -1;
        }
        ssize_t w = send(fd, b, n, MSG_NOSIGNAL);
        if (w < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (w == 0) {
            errno = ECONNRESET;
            return -1;
        }
        b += (size_t)w;
        n -= (size_t)w;
    }
    return 0;
}

static int recv_exact(int fd, void *p, size_t n) {
    unsigned char *b = (unsigned char *)p;
    while (n > 0) {
        ssize_t r = recv(fd, b, n, 0);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (r == 0) {
            /* EOF: the peer closed. recv leaves errno untouched here, so set
             * it, or io_failure would classify a stale value. */
            errno = ECONNRESET;
            return -1;
        }
        b += (size_t)r;
        n -= (size_t)r;
    }
    return 0;
}

static void write_be32(unsigned char out[4], uint32_t v) {
    out[0] = (unsigned char)(v >> 24);
    out[1] = (unsigned char)(v >> 16);
    out[2] = (unsigned char)(v >> 8);
    out[3] = (unsigned char)v;
}

static uint32_t read_be32(const unsigned char in[4]) {
    return ((uint32_t)in[0] << 24) | ((uint32_t)in[1] << 16)
        | ((uint32_t)in[2] << 8) | (uint32_t)in[3];
}

/* rvd's socket: $XDG_RUNTIME_DIR/rv/evaluate.sock, or the uid-derived
 * RV_HOOK_USER_RUNTIME_ROOT/<uid>/rv/evaluate.sock when XDG_RUNTIME_DIR is
 * unset. *owner_derived is 1 only when the directory is the uid-derived
 * one (XDG unset, or exactly equal to it): only a miss there may count as
 * an absent daemon. An agent can set XDG_RUNTIME_DIR through
 * project-scoped host config, so a miss under any other directory proves
 * nothing about rvd. Returns -1 (fail closed) when XDG is set but empty,
 * or the path does not fit sockaddr_un. */
static int unix_socket_path(char *out, size_t cap, int *owner_derived) {
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    char owner_dir[RV_UNIX_PATH_MAX];
    const char *dir;
    int n;
    *owner_derived = 0;
    n = snprintf(owner_dir, sizeof owner_dir, "%s/%lu",
                 RV_HOOK_USER_RUNTIME_ROOT, (unsigned long)getuid());
    if (n <= 0 || (size_t)n >= sizeof owner_dir) {
        return -1;
    }
    if (xdg == NULL) {
        dir = owner_dir;
    } else if (xdg[0] == '\0') {
        return -1;
    } else {
        dir = xdg;
    }
    n = snprintf(out, cap, "%s/rv/evaluate.sock", dir);
    if (n <= 0 || (size_t)n >= cap || (size_t)n + 1 > RV_UNIX_PATH_MAX) {
        return -1;
    }
    *owner_derived = strcmp(dir, owner_dir) == 0;
    return 0;
}

static void set_socket_timeouts(int fd, long ms) {
    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

/* errno after a failed send/recv on a verified daemon: a socket timeout is
 * TIMEOUT, anything else (reset, EOF, broken pipe) is CONNECTION. Never
 * UNREACHABLE: the daemon was there, and rvd deliberately drops in-flight
 * requests while draining, which an agent can trigger. */
static int io_failure(void) {
    return (errno == EAGAIN || errno == EWOULDBLOCK)
        ? RV_HOOK_FAIL_TIMEOUT
        : RV_HOOK_FAIL_CONNECTION;
}

/* Returns 0, or the failure class. *retryable is set only for transient
 * failures before any request byte is sent (missing socket, refused,
 * connect timeout); once sent the request is never resent. UNREACHABLE
 * only for ENOENT / ECONNREFUSED on the uid-derived socket; every other
 * failure keeps the ask/deny fallback (CONNECTION, TIMEOUT, UNTRUSTED,
 * PROTOCOL). */
static int unix_hook_evaluate(
    const void *json,
    size_t json_len,
    char **reply_json,
    size_t *reply_len,
    int *retryable
) {
    char path[RV_UNIX_PATH_MAX];
    int fd;
    struct sockaddr_un addr;
    unsigned char header[4];
    uint32_t n;
    char *copy;
    int failure;
    int owner_derived;

    *retryable = 0;
    if (json_len == 0 || json_len > RV_FRAME_MAX) {
        return RV_HOOK_FAIL_INPUT;
    }
    if (unix_socket_path(path, sizeof path, &owner_derived) != 0) {
        return RV_HOOK_FAIL_CONNECTION;
    }

    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return RV_HOOK_FAIL_CONNECTION;
    }
    set_socket_timeouts(fd, RV_HELLO_TIMEOUT_MS);

    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, strlen(path) + 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        int err = errno;
        close(fd);
        if (err == ENOENT || err == ECONNREFUSED) {
            *retryable = 1;
            return owner_derived ? RV_HOOK_FAIL_UNREACHABLE : RV_HOOK_FAIL_CONNECTION;
        }
        if (err == EAGAIN || err == EWOULDBLOCK || err == ETIMEDOUT || err == EINPROGRESS) {
            *retryable = 1;
            return RV_HOOK_FAIL_TIMEOUT;
        }
        return RV_HOOK_FAIL_CONNECTION;
    }
    /* A socket path is not server identity. Verify the connected peer
     * is the sibling rvd before sending any action bytes. */
    if (!rv_verify_unix_daemon(fd)) {
        close(fd);
        /* Nothing sent yet; a stale rvd drains and exits on its own. */
        *retryable = 1;
        return RV_HOOK_FAIL_UNTRUSTED;
    }

    if (past_evaluate_send_cutoff()) {
        /* Too late for rvd to finish before the host gives up. */
        close(fd);
        *retryable = 0;
        return RV_HOOK_FAIL_TIMEOUT;
    }
    /* Point of no return: from here on nothing is retried. Each blocking
     * send waits at most until the cutoff (send_nosig also checks it
     * between partial sends); the reply then gets the full budget. */
    set_socket_timeouts(fd, remaining_send_ms());
    write_be32(header, (uint32_t)json_len);
    if (send_nosig(fd, header, 4) != 0 || send_nosig(fd, json, json_len) != 0) {
        failure = io_failure();
        close(fd);
        return failure;
    }
    set_socket_timeouts(fd, RV_EVALUATE_TIMEOUT_MS);
    if (recv_exact(fd, header, 4) != 0) {
        failure = io_failure();
        close(fd);
        return failure;
    }
    n = read_be32(header);
    if (n == 0 || n > RV_FRAME_MAX) {
        close(fd);
        return RV_HOOK_FAIL_PROTOCOL;
    }
    copy = (char *)malloc((size_t)n + 1);
    if (copy == NULL) {
        close(fd);
        return RV_HOOK_FAIL_PROTOCOL;
    }
    if (recv_exact(fd, copy, (size_t)n) != 0) {
        failure = io_failure();
        free(copy);
        close(fd);
        return failure;
    }
    close(fd);
    copy[n] = '\0';
    *reply_json = copy;
    *reply_len = (size_t)n;
    return 0;
}
#endif

/* One retry, only for transient failures before the hookEvaluate request
 * left this process (cold launchd spawn, idle-exit race). A daemon that
 * answered the first attempt in any way (untrusted, interrupted, slow) was
 * live, so a retry that then finds none is not proof of absence: the first
 * such failure is reported instead of UNREACHABLE. */
static int hook_evaluate(
    const char *request,
    size_t request_len,
    const struct ByteBuf *stdin_buf,
    char **reply_json,
    size_t *reply_len
) {
    int attempt;
    int failure = RV_HOOK_FAIL_CONNECTION;
    int seen_live = 0;
    for (attempt = 0; attempt < 2; attempt++) {
        int retryable = 0;
#ifdef __APPLE__
        failure = xpc_hook_evaluate(
            request, request_len, stdin_buf->p, stdin_buf->len,
            reply_json, reply_len, &retryable);
#else
        (void)stdin_buf;
        failure = unix_hook_evaluate(
            request, request_len, reply_json, reply_len, &retryable);
#endif
        if (failure == RV_HOOK_FAIL_UNREACHABLE && seen_live != 0) {
            failure = seen_live;
        } else if (failure != 0 && failure != RV_HOOK_FAIL_UNREACHABLE && seen_live == 0) {
            seen_live = failure;
        }
        if (failure == 0 || !retryable) {
            break;
        }
        if (attempt == 0) {
            sleep_ms(RV_HOOK_RETRY_DELAY_MS);
        }
    }
    return failure;
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
    int failure;

    rv_started_ms = monotonic_ms();
    /* Broken output pipes must not terminate RV before its denial path. */
    signal(SIGPIPE, SIG_IGN);

    if (parse_hook_argv(argc, argv, &host) != 0) {
        exec_same_argv(argv);
    }

    /* Action bytes go only to a verified daemon: Darwin verifies every
     * reply's sender in xpc_exchange, Linux verifies the connected peer
     * in unix_hook_evaluate (daemon_trust.h). Every failure below exits
     * through fail_hook with its class: malformed input always denies;
     * an unavailable, slow, untrusted or skewed daemon renders per
     * RV_HOOK_WHEN_DOWN (hook_fallback.h). Nothing replays to rv-cli. */

    memset(&stdin_buf, 0, sizeof stdin_buf);
    int stdin_read = buf_read_fd_limited(&stdin_buf, STDIN_FILENO, RV_STDIN_XPC_MAX);
    if (stdin_read == BUF_READ_ERROR) {
        buf_free(&stdin_buf);
        fail_hook(host, RV_HOOK_FAIL_INPUT);
    }

    if (stdin_read == BUF_READ_LIMIT) {
        fail_hook(host, RV_HOOK_FAIL_INPUT);
    }

    if (stdin_buf.has_nul
        || stdin_buf.len > RV_STDIN_XPC_MAX
        || !rv_utf8_is_valid(stdin_buf.p, stdin_buf.len))
    {
        fail_hook(host, RV_HOOK_FAIL_INPUT);
    }

    request = build_request(host, stdin_buf.p, stdin_buf.len, &request_len, request_id);
    if (request == NULL) {
        fail_hook(host, RV_HOOK_FAIL_INPUT);
    }

    failure = hook_evaluate(request, request_len, &stdin_buf, &reply_json, &reply_len);
    free(request);
    if (failure != 0) {
        fail_hook(host, (enum RvHookFailure)failure);
    }

    memset(&reply, 0, sizeof reply);
    if (rv_parse_hook_reply(reply_json, reply_len, &reply) != RV_HOOK_REPLY_OK) {
        free(reply_json);
        fail_hook(host, RV_HOOK_FAIL_PROTOCOL);
    }
    free(reply_json);

    if (!reply.has_id || strcasecmp(reply.id, request_id) != 0) {
        rv_hook_reply_free(&reply);
        fail_hook(host, RV_HOOK_FAIL_PROTOCOL);
    }

    if (rv_should_miss_replay(
            RV_CLIENT_SEMVER,
            reply.has_service_semver ? reply.service_semver : NULL))
    {
        rv_hook_reply_free(&reply);
        fail_hook(host, RV_HOOK_FAIL_PROTOCOL);
    }

    if (write_all(STDOUT_FILENO, reply.stdout_bytes, reply.stdout_len) != 0) {
        rv_hook_reply_free(&reply);
        buf_free(&stdin_buf);
        /* A verdict the host could not receive must never degrade to
         * allow-mode silence: the always-deny class keeps the deny exit. */
        fail_hook(host, RV_HOOK_FAIL_INPUT);
    }
    {
        int32_t code = reply.exit_code;
        rv_hook_reply_free(&reply);
        buf_free(&stdin_buf);
        return (int)code;
    }
}
