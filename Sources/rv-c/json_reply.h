#ifndef RV_JSON_REPLY_H
#define RV_JSON_REPLY_H

#include <stddef.h>
#include <stdint.h>

enum RvHookReplyKind {
    RV_HOOK_REPLY_OK = 0,
    RV_HOOK_REPLY_MISS = 1
};

struct RvHookReply {
    int has_id;
    char id[37];
    char *stdout_bytes;
    size_t stdout_len;
    int32_t exit_code;
    int has_service_semver;
    char service_semver[64];
};

void rv_hook_reply_free(struct RvHookReply *reply);

/* Decode an IPCResponse JSON body. Unexpected shape, result.error,
 * missing via, or via != "xpc" is MISS. Caller frees stdout_bytes on OK.
 */
enum RvHookReplyKind rv_parse_hook_reply(
    const char *json,
    size_t n,
    struct RvHookReply *out
);

#endif
