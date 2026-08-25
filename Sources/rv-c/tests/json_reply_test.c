#include "json_reply.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fails;

static void fail(const char *name, const char *detail) {
    fprintf(stderr, "FAIL %s: %s\n", name, detail);
    g_fails += 1;
}

static void expect_ok(
    const char *name,
    const char *json,
    const char *stdout_want,
    int32_t exit_want,
    int has_semver,
    const char *semver_want
) {
    struct RvHookReply r;
    memset(&r, 0, sizeof r);
    if (rv_parse_hook_reply(json, strlen(json), &r) != RV_HOOK_REPLY_OK) {
        fail(name, "expected OK");
        return;
    }
    if (r.stdout_len != strlen(stdout_want)
        || memcmp(r.stdout_bytes, stdout_want, r.stdout_len) != 0)
    {
        fail(name, "stdout mismatch");
    }
    if (r.exit_code != exit_want) {
        fail(name, "exitCode mismatch");
    }
    if (r.has_service_semver != has_semver) {
        fail(name, "serviceSemver presence mismatch");
    }
    if (has_semver && strcmp(r.service_semver, semver_want) != 0) {
        fail(name, "serviceSemver mismatch");
    }
    rv_hook_reply_free(&r);
}

static void expect_miss(const char *name, const char *json) {
    struct RvHookReply r;
    memset(&r, 0, sizeof r);
    if (rv_parse_hook_reply(json, strlen(json), &r) != RV_HOOK_REPLY_MISS) {
        fail(name, "expected MISS");
        rv_hook_reply_free(&r);
    }
}

int main(void) {
    const char *ok =
        "{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"protocol\":\"rv.ipc.v1\","
        "\"result\":{\"hookEvaluate\":{\"exitCode\":0,\"serviceSemver\":\"1.0.0\","
        "\"stdout\":\"{\\\"decision\\\":\\\"deny\\\"}\",\"via\":\"xpc\"}}}";
    const char *allow =
        "{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"protocol\":\"rv.ipc.v1\","
        "\"result\":{\"hookEvaluate\":{\"exitCode\":0,\"stdout\":\"\",\"via\":\"xpc\"}}}";
    const char *via_bad =
        "{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"protocol\":\"rv.ipc.v1\","
        "\"result\":{\"hookEvaluate\":{\"exitCode\":0,\"stdout\":\"\",\"via\":\"inProcess\"}}}";
    const char *err =
        "{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"protocol\":\"rv.ipc.v1\","
        "\"result\":{\"error\":{\"protocolSkew\":\"major version\"}}}";
    const char *proto_bad =
        "{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"protocol\":\"rv.ipc.v0\","
        "\"result\":{\"hookEvaluate\":{\"exitCode\":0,\"stdout\":\"\",\"via\":\"xpc\"}}}";
    const char *evaluate =
        "{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"protocol\":\"rv.ipc.v1\","
        "\"result\":{\"evaluate\":{\"via\":\"xpc\"}}}";
    const char *missing_id =
        "{\"protocol\":\"rv.ipc.v1\","
        "\"result\":{\"hookEvaluate\":{\"exitCode\":0,\"stdout\":\"\",\"via\":\"xpc\"}}}";

    expect_ok("deny_wire", ok, "{\"decision\":\"deny\"}", 0, 1, "1.0.0");
    expect_ok("empty_allow", allow, "", 0, 0, NULL);
    expect_miss("via_in_process", via_bad);
    expect_miss("result_error", err);
    expect_miss("protocol_skew", proto_bad);
    expect_miss("unexpected_evaluate", evaluate);
    expect_miss("missing_id", missing_id);
    expect_miss("truncated", "{\"protocol\":\"rv.ipc.v1\"");
    expect_miss("empty", "");

    /* Deeply nested unknown value must MISS (deny), not overflow the stack:
     * build {"id":"...","junk":[[[ ... ]]]} far past RV_JSON_MAX_DEPTH. */
    {
        size_t depth = 4096;
        char *deep = (char *)malloc(depth * 2 + 64);
        if (deep == NULL) {
            fail("deep_nesting", "alloc");
        } else {
            size_t n = 0;
            n += (size_t)snprintf(deep + n, depth * 2 + 64 - n,
                                  "{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"junk\":");
            for (size_t i = 0; i < depth; i++) {
                deep[n++] = '[';
            }
            for (size_t i = 0; i < depth; i++) {
                deep[n++] = ']';
            }
            memcpy(deep + n, "}", 2);
            n += 1;
            expect_miss("deep_nesting", deep);
            free(deep);
        }
    }

    if (g_fails != 0) {
        fprintf(stderr, "%d failure(s)\n", g_fails);
        return 1;
    }
    printf("json_reply tests ok\n");
    return 0;
}
