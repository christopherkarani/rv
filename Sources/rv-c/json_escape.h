#ifndef RV_JSON_ESCAPE_H
#define RV_JSON_ESCAPE_H

#include <stddef.h>

/*
 * JSON string contents (no surrounding quotes).
 * Quotes, backslashes, and controls are escaped. Valid UTF-8 is copied through.
 * Invalid UTF-8 is an error: do not emit a truncated or ill-formed JSON string.
 */

int rv_utf8_is_valid(const unsigned char *src, size_t n);

/* SIZE_MAX if src is not valid UTF-8. */
size_t rv_json_escaped_len(const unsigned char *src, size_t n);

/* Writes escaped bytes to dst (NUL-terminated). out_len excludes the NUL.
 * dst may be NULL to compute length only (still validates UTF-8).
 * Returns 0 on success, -1 on invalid UTF-8 or a short destination.
 */
int rv_json_escape(
    const unsigned char *src,
    size_t n,
    char *dst,
    size_t dst_cap,
    size_t *out_len
);

/* Unescape JSON string contents (no surrounding quotes).
 * Allocates *out (NUL-terminated); *out_len is the byte count excluding NUL.
 * Returns 0 on success, -1 on a malformed escape. Caller frees *out.
 */
int rv_json_unescape(const char *src, size_t n, char **out, size_t *out_len);

#endif
