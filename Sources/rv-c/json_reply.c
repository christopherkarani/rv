#include "json_reply.h"
#include "json_escape.h"

#include <stdlib.h>
#include <string.h>

/*
 * Recursion cap for skipping unknown values: a hostile or broken reply must
 * fail (MISS -> deny) instead of overflowing the hook process stack.
 */
#define RV_JSON_MAX_DEPTH 64

struct Cur {
    const char *p;
    const char *end;
    int err;
};

static void skip_ws(struct Cur *c) {
    while (c->p < c->end) {
        char ch = *c->p;
        if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r') {
            break;
        }
        c->p += 1;
    }
}

static int peek(struct Cur *c) {
    skip_ws(c);
    if (c->p >= c->end) {
        return -1;
    }
    return (unsigned char)*c->p;
}

static int eat(struct Cur *c, char ch) {
    if (peek(c) != (unsigned char)ch) {
        c->err = 1;
        return -1;
    }
    c->p += 1;
    return 0;
}

static int skip_string_raw(struct Cur *c) {
    if (eat(c, '"') != 0) {
        return -1;
    }
    while (c->p < c->end) {
        char ch = *c->p;
        c->p += 1;
        if (ch == '"') {
            return 0;
        }
        if (ch == '\\') {
            if (c->p >= c->end) {
                c->err = 1;
                return -1;
            }
            c->p += 1;
        }
    }
    c->err = 1;
    return -1;
}

static int parse_string(struct Cur *c, char **out, size_t *out_len) {
    const char *start;
    size_t raw_len;
    if (eat(c, '"') != 0) {
        return -1;
    }
    start = c->p;
    while (c->p < c->end) {
        char ch = *c->p;
        if (ch == '"') {
            raw_len = (size_t)(c->p - start);
            c->p += 1;
            if (rv_json_unescape(start, raw_len, out, out_len) != 0) {
                c->err = 1;
                return -1;
            }
            return 0;
        }
        c->p += 1;
        if (ch == '\\') {
            if (c->p >= c->end) {
                c->err = 1;
                return -1;
            }
            c->p += 1;
        }
    }
    c->err = 1;
    return -1;
}

static int skip_value(struct Cur *c, int depth);

static int skip_object(struct Cur *c, int depth) {
    if (depth > RV_JSON_MAX_DEPTH || eat(c, '{') != 0) {
        return -1;
    }
    if (peek(c) == '}') {
        c->p += 1;
        return 0;
    }
    for (;;) {
        if (skip_string_raw(c) != 0) {
            return -1;
        }
        if (eat(c, ':') != 0) {
            return -1;
        }
        if (skip_value(c, depth + 1) != 0) {
            return -1;
        }
        skip_ws(c);
        if (peek(c) == ',') {
            c->p += 1;
            continue;
        }
        if (eat(c, '}') != 0) {
            return -1;
        }
        return 0;
    }
}

static int skip_array(struct Cur *c, int depth) {
    if (depth > RV_JSON_MAX_DEPTH || eat(c, '[') != 0) {
        return -1;
    }
    if (peek(c) == ']') {
        c->p += 1;
        return 0;
    }
    for (;;) {
        if (skip_value(c, depth + 1) != 0) {
            return -1;
        }
        skip_ws(c);
        if (peek(c) == ',') {
            c->p += 1;
            continue;
        }
        if (eat(c, ']') != 0) {
            return -1;
        }
        return 0;
    }
}

static int skip_number(struct Cur *c) {
    skip_ws(c);
    if (c->p < c->end && *c->p == '-') {
        c->p += 1;
    }
    int digits = 0;
    while (c->p < c->end && *c->p >= '0' && *c->p <= '9') {
        digits = 1;
        c->p += 1;
    }
    if (c->p < c->end && *c->p == '.') {
        c->p += 1;
        while (c->p < c->end && *c->p >= '0' && *c->p <= '9') {
            digits = 1;
            c->p += 1;
        }
    }
    if (c->p < c->end && (*c->p == 'e' || *c->p == 'E')) {
        c->p += 1;
        if (c->p < c->end && (*c->p == '+' || *c->p == '-')) {
            c->p += 1;
        }
        while (c->p < c->end && *c->p >= '0' && *c->p <= '9') {
            c->p += 1;
        }
    }
    if (!digits) {
        c->err = 1;
        return -1;
    }
    return 0;
}

static int skip_literal(struct Cur *c, const char *lit, size_t n) {
    skip_ws(c);
    if ((size_t)(c->end - c->p) < n || memcmp(c->p, lit, n) != 0) {
        c->err = 1;
        return -1;
    }
    c->p += n;
    return 0;
}

static int skip_value(struct Cur *c, int depth) {
    int ch = peek(c);
    if (ch < 0) {
        c->err = 1;
        return -1;
    }
    if (ch == '"') {
        return skip_string_raw(c);
    }
    if (ch == '{') {
        return skip_object(c, depth + 1);
    }
    if (ch == '[') {
        return skip_array(c, depth + 1);
    }
    if (ch == 't') {
        return skip_literal(c, "true", 4);
    }
    if (ch == 'f') {
        return skip_literal(c, "false", 5);
    }
    if (ch == 'n') {
        return skip_literal(c, "null", 4);
    }
    if (ch == '-' || (ch >= '0' && ch <= '9')) {
        return skip_number(c);
    }
    c->err = 1;
    return -1;
}

static int parse_int32(struct Cur *c, int32_t *out) {
    const char *start;
    char *endptr;
    long v;
    int neg = 0;
    skip_ws(c);
    start = c->p;
    if (c->p < c->end && *c->p == '-') {
        neg = 1;
        c->p += 1;
    }
    if (c->p >= c->end || *c->p < '0' || *c->p > '9') {
        c->err = 1;
        return -1;
    }
    while (c->p < c->end && *c->p >= '0' && *c->p <= '9') {
        c->p += 1;
    }
    if (c->p < c->end && (*c->p == '.' || *c->p == 'e' || *c->p == 'E')) {
        c->err = 1;
        return -1;
    }
    {
        size_t n = (size_t)(c->p - start);
        char buf[32];
        if (n == 0 || n >= sizeof buf) {
            c->err = 1;
            return -1;
        }
        memcpy(buf, start, n);
        buf[n] = '\0';
        v = strtol(buf, &endptr, 10);
        if (endptr == buf || *endptr != '\0') {
            c->err = 1;
            return -1;
        }
        if (neg == 0 && v < 0) {
            c->err = 1;
            return -1;
        }
        if (v < (long)INT32_MIN || v > (long)INT32_MAX) {
            c->err = 1;
            return -1;
        }
        *out = (int32_t)v;
        return 0;
    }
}

static int key_eq(const char *key, size_t n, const char *want) {
    size_t w = strlen(want);
    return n == w && memcmp(key, want, n) == 0;
}

static int next_object_key(struct Cur *c, int *first, char **key, size_t *key_len) {
    skip_ws(c);
    if (*first) {
        if (eat(c, '{') != 0) {
            return -1;
        }
        *first = 0;
        skip_ws(c);
        if (peek(c) == '}') {
            c->p += 1;
            return 1;
        }
    } else {
        skip_ws(c);
        if (peek(c) == ',') {
            c->p += 1;
            skip_ws(c);
        } else {
            if (eat(c, '}') != 0) {
                return -1;
            }
            return 1;
        }
    }
    if (parse_string(c, key, key_len) != 0) {
        return -1;
    }
    if (eat(c, ':') != 0) {
        free(*key);
        *key = NULL;
        return -1;
    }
    return 0;
}

static int parse_hook_evaluate(struct Cur *c, struct RvHookReply *out) {
    int first = 1;
    int saw_stdout = 0;
    int saw_exit = 0;
    int saw_via = 0;
    out->has_service_semver = 0;
    out->service_semver[0] = '\0';
    out->stdout_bytes = NULL;
    out->stdout_len = 0;
    out->exit_code = 0;

    for (;;) {
        char *key = NULL;
        size_t key_len = 0;
        int st = next_object_key(c, &first, &key, &key_len);
        if (st < 0) {
            return -1;
        }
        if (st == 1) {
            break;
        }
        if (key_eq(key, key_len, "stdout")) {
            free(key);
            if (saw_stdout) {
                c->err = 1;
                return -1;
            }
            if (parse_string(c, &out->stdout_bytes, &out->stdout_len) != 0) {
                return -1;
            }
            saw_stdout = 1;
        } else if (key_eq(key, key_len, "exitCode")) {
            free(key);
            if (saw_exit) {
                c->err = 1;
                return -1;
            }
            if (parse_int32(c, &out->exit_code) != 0) {
                return -1;
            }
            saw_exit = 1;
        } else if (key_eq(key, key_len, "via")) {
            char *via = NULL;
            size_t via_len = 0;
            free(key);
            if (saw_via) {
                c->err = 1;
                return -1;
            }
            if (parse_string(c, &via, &via_len) != 0) {
                return -1;
            }
            if (via_len != 3 || memcmp(via, "xpc", 3) != 0) {
                free(via);
                c->err = 1;
                return -1;
            }
            free(via);
            saw_via = 1;
        } else if (key_eq(key, key_len, "serviceSemver")) {
            char *sem = NULL;
            size_t sem_len = 0;
            int ch;
            free(key);
            ch = peek(c);
            if (ch == 'n') {
                if (skip_literal(c, "null", 4) != 0) {
                    return -1;
                }
            } else {
                if (parse_string(c, &sem, &sem_len) != 0) {
                    return -1;
                }
                if (sem_len >= sizeof out->service_semver) {
                    free(sem);
                    c->err = 1;
                    return -1;
                }
                memcpy(out->service_semver, sem, sem_len);
                out->service_semver[sem_len] = '\0';
                out->has_service_semver = 1;
                free(sem);
            }
        } else {
            free(key);
            if (skip_value(c, 0) != 0) {
                return -1;
            }
        }
    }
    if (!saw_stdout || !saw_exit || !saw_via) {
        c->err = 1;
        return -1;
    }
    return 0;
}

static int parse_result(struct Cur *c, struct RvHookReply *out) {
    int first = 1;
    int saw_hook = 0;
    int saw_error = 0;
    for (;;) {
        char *key = NULL;
        size_t key_len = 0;
        int st = next_object_key(c, &first, &key, &key_len);
        if (st < 0) {
            return -1;
        }
        if (st == 1) {
            break;
        }
        if (key_eq(key, key_len, "hookEvaluate")) {
            free(key);
            if (saw_hook) {
                c->err = 1;
                return -1;
            }
            if (parse_hook_evaluate(c, out) != 0) {
                return -1;
            }
            saw_hook = 1;
        } else if (key_eq(key, key_len, "error")) {
            free(key);
            saw_error = 1;
            if (skip_value(c, 0) != 0) {
                return -1;
            }
        } else {
            free(key);
            if (skip_value(c, 0) != 0) {
                return -1;
            }
        }
    }
    if (saw_error || !saw_hook) {
        c->err = 1;
        return -1;
    }
    return 0;
}

void rv_hook_reply_free(struct RvHookReply *reply) {
    if (reply == NULL) {
        return;
    }
    free(reply->stdout_bytes);
    reply->stdout_bytes = NULL;
    reply->stdout_len = 0;
}

enum RvHookReplyKind rv_parse_hook_reply(
    const char *json,
    size_t n,
    struct RvHookReply *out
) {
    struct Cur c;
    int first = 1;
    int saw_protocol = 0;
    int saw_result = 0;
    struct RvHookReply local;
    memset(&local, 0, sizeof local);
    memset(out, 0, sizeof *out);

    if (json == NULL && n > 0) {
        return RV_HOOK_REPLY_MISS;
    }
    c.p = json;
    c.end = json + n;
    c.err = 0;

    for (;;) {
        char *key = NULL;
        size_t key_len = 0;
        int st = next_object_key(&c, &first, &key, &key_len);
        if (st < 0) {
            rv_hook_reply_free(&local);
            return RV_HOOK_REPLY_MISS;
        }
        if (st == 1) {
            break;
        }
        if (key_eq(key, key_len, "protocol")) {
            char *proto = NULL;
            size_t proto_len = 0;
            free(key);
            if (parse_string(&c, &proto, &proto_len) != 0) {
                rv_hook_reply_free(&local);
                return RV_HOOK_REPLY_MISS;
            }
            if (proto_len != 9 || memcmp(proto, "rv.ipc.v1", 9) != 0) {
                free(proto);
                rv_hook_reply_free(&local);
                return RV_HOOK_REPLY_MISS;
            }
            free(proto);
            saw_protocol = 1;
        } else if (key_eq(key, key_len, "id")) {
            char *id = NULL;
            size_t id_len = 0;
            free(key);
            if (local.has_id || parse_string(&c, &id, &id_len) != 0) {
                free(id);
                rv_hook_reply_free(&local);
                return RV_HOOK_REPLY_MISS;
            }
            if (id_len != 36) {
                free(id);
                rv_hook_reply_free(&local);
                return RV_HOOK_REPLY_MISS;
            }
            memcpy(local.id, id, 36);
            local.id[36] = '\0';
            local.has_id = 1;
            free(id);
        } else if (key_eq(key, key_len, "result")) {
            free(key);
            if (parse_result(&c, &local) != 0) {
                rv_hook_reply_free(&local);
                return RV_HOOK_REPLY_MISS;
            }
            saw_result = 1;
        } else {
            free(key);
            if (skip_value(&c, 0) != 0) {
                rv_hook_reply_free(&local);
                return RV_HOOK_REPLY_MISS;
            }
        }
    }
    skip_ws(&c);
    if (c.p != c.end || c.err || !local.has_id || !saw_protocol || !saw_result) {
        rv_hook_reply_free(&local);
        return RV_HOOK_REPLY_MISS;
    }
    *out = local;
    return RV_HOOK_REPLY_OK;
}

/* Guard-mode resolution levels for rv_guard_config_observes. */
#define RV_GUARD_UNSET 0
#define RV_GUARD_ENFORCE 1
#define RV_GUARD_OBSERVE 2

/* ASCII case-insensitive exact match (rvd lowercases before matching). */
static int value_is(const char *v, size_t n, const char *want) {
    size_t i;
    if (n != strlen(want)) {
        return 0;
    }
    for (i = 0; i < n; i++) {
        unsigned char ch = (unsigned char)v[i];
        if (ch >= 'A' && ch <= 'Z') {
            ch = (unsigned char)(ch - 'A' + 'a');
        }
        if (ch != (unsigned char)want[i]) {
            return 0;
        }
    }
    return 1;
}

/* A string value is returned in *str (caller frees); any other value is
 * skipped and *str stays NULL. */
static int string_or_skip(struct Cur *c, int depth, char **str, size_t *len) {
    *str = NULL;
    *len = 0;
    if (peek(c) == '"') {
        return parse_string(c, str, len);
    }
    return skip_value(c, depth);
}

/* guard.mode, nested or flat: empty or non-string is unset; a non-empty
 * value is observe or enforce (unknown values do not fall through). */
static int read_mode_value(struct Cur *c, int depth, int *mode) {
    char *v;
    size_t n;
    if (string_or_skip(c, depth, &v, &n) != 0) {
        return -1;
    }
    if (v != NULL && n > 0) {
        *mode = value_is(v, n, "observe") ? RV_GUARD_OBSERVE : RV_GUARD_ENFORCE;
    }
    free(v);
    return 0;
}

static int read_guard_hosts(struct Cur *c, int depth, const char *host, int *mode) {
    int first = 1;
    int seen = 0;
    for (;;) {
        char *key = NULL;
        size_t key_len = 0;
        int r = next_object_key(c, &first, &key, &key_len);
        int bad = 0;
        if (r != 0) {
            return r < 0 ? -1 : 0;
        }
        if (key_eq(key, key_len, host)) {
            char *v;
            size_t n;
            bad = seen || string_or_skip(c, depth + 1, &v, &n) != 0;
            seen = 1;
            if (!bad && v != NULL) {
                if (value_is(v, n, "block")) {
                    *mode = RV_GUARD_ENFORCE;
                } else if (value_is(v, n, "observe") || value_is(v, n, "off")) {
                    *mode = RV_GUARD_OBSERVE;
                }
            }
            if (!bad) {
                free(v);
            }
        } else {
            bad = skip_value(c, depth + 1) != 0;
        }
        free(key);
        if (bad) {
            return -1;
        }
    }
}

static int read_guard_object(struct Cur *c, int depth, const char *host, int *host_mode, int *nested) {
    int first = 1;
    int seen_mode = 0;
    int seen_hosts = 0;
    for (;;) {
        char *key = NULL;
        size_t key_len = 0;
        int r = next_object_key(c, &first, &key, &key_len);
        int bad = 0;
        if (r != 0) {
            return r < 0 ? -1 : 0;
        }
        if (key_eq(key, key_len, "mode")) {
            bad = seen_mode || read_mode_value(c, depth + 1, nested) != 0;
            seen_mode = 1;
        } else if (key_eq(key, key_len, "hosts")) {
            bad = seen_hosts;
            seen_hosts = 1;
            if (!bad) {
                bad = peek(c) == '{' ? read_guard_hosts(c, depth + 1, host, host_mode) != 0
                                     : skip_value(c, depth + 1) != 0;
            }
        } else {
            bad = skip_value(c, depth + 1) != 0;
        }
        free(key);
        if (bad) {
            return -1;
        }
    }
}

int rv_guard_config_observes(const char *json, size_t n, const char *host) {
    struct Cur c;
    int first = 1;
    int seen_guard = 0;
    int seen_flat = 0;
    int host_mode = RV_GUARD_UNSET;
    int nested = RV_GUARD_UNSET;
    int flat = RV_GUARD_UNSET;
    if (json == NULL || host == NULL) {
        return 0;
    }
    c.p = json;
    c.end = json + n;
    c.err = 0;
    for (;;) {
        char *key = NULL;
        size_t key_len = 0;
        int r = next_object_key(&c, &first, &key, &key_len);
        int bad = 0;
        if (r < 0) {
            return 0;
        }
        if (r == 1) {
            break;
        }
        if (key_eq(key, key_len, "guard")) {
            bad = seen_guard;
            seen_guard = 1;
            if (!bad) {
                bad = peek(&c) == '{' ? read_guard_object(&c, 1, host, &host_mode, &nested) != 0
                                      : skip_value(&c, 1) != 0;
            }
        } else if (key_eq(key, key_len, "guard.mode")) {
            bad = seen_flat || read_mode_value(&c, 1, &flat) != 0;
            seen_flat = 1;
        } else {
            bad = skip_value(&c, 1) != 0;
        }
        free(key);
        if (bad) {
            return 0;
        }
    }
    skip_ws(&c);
    if (c.p != c.end) {
        return 0;
    }
    if (host_mode != RV_GUARD_UNSET) {
        return host_mode == RV_GUARD_OBSERVE;
    }
    if (nested != RV_GUARD_UNSET) {
        return nested == RV_GUARD_OBSERVE;
    }
    return flat == RV_GUARD_OBSERVE;
}
