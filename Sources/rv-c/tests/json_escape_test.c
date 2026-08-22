#include "json_escape.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fails;

static void fail(const char *name, const char *detail) {
    fprintf(stderr, "FAIL %s: %s\n", name, detail);
    g_fails += 1;
}

static char *escape_dup(const unsigned char *src, size_t n, size_t *out_len) {
    size_t need = 0;
    char *dst;
    if (rv_json_escape(src, n, NULL, 0, &need) != 0) {
        return NULL;
    }
    dst = (char *)malloc(need + 1);
    if (dst == NULL) {
        return NULL;
    }
    if (rv_json_escape(src, n, dst, need + 1, out_len) != 0) {
        free(dst);
        return NULL;
    }
    return dst;
}

static void expect_escape(const char *name, const char *src, const char *want) {
    size_t n = strlen(src);
    size_t got_len = 0;
    char *got = escape_dup((const unsigned char *)src, n, &got_len);
    if (got == NULL) {
        fail(name, "escape returned error");
        return;
    }
    if (got_len != strlen(want) || memcmp(got, want, got_len) != 0) {
        fprintf(stderr, "FAIL %s:\n  got  %s\n  want %s\n", name, got, want);
        g_fails += 1;
    }
    if (rv_json_escaped_len((const unsigned char *)src, n) != got_len) {
        fail(name, "escaped_len mismatch");
    }
    free(got);
}

static void expect_roundtrip(const char *name, const unsigned char *src, size_t n) {
    size_t esc_len = 0;
    char *esc;
    char *raw = NULL;
    size_t raw_len = 0;
    esc = escape_dup(src, n, &esc_len);
    if (esc == NULL) {
        fail(name, "escape returned error");
        return;
    }
    if (rv_json_unescape(esc, esc_len, &raw, &raw_len) != 0) {
        fail(name, "unescape returned error");
        free(esc);
        return;
    }
    if (raw_len != n || memcmp(raw, src, n) != 0) {
        fail(name, "roundtrip mismatch");
    }
    free(esc);
    free(raw);
}

static void expect_unescape(const char *name, const char *esc, const char *want) {
    char *raw = NULL;
    size_t raw_len = 0;
    if (rv_json_unescape(esc, strlen(esc), &raw, &raw_len) != 0) {
        fail(name, "unescape returned error");
        return;
    }
    if (raw_len != strlen(want) || memcmp(raw, want, raw_len) != 0) {
        fprintf(stderr, "FAIL %s:\n  got  %s\n  want %s\n", name, raw, want);
        g_fails += 1;
    }
    free(raw);
}

int main(void) {
    unsigned char cafe[5];
    unsigned char grin[4];
    unsigned char controls[8];
    unsigned char mixed[11];
    unsigned char nulq[3];
    unsigned char bad_ff[1];
    unsigned char overlong[2];
    unsigned char trunc[2];
    int c;

    expect_escape("empty", "", "");
    expect_escape("ascii", "hello", "hello");
    expect_escape("quote", "say \"hi\"", "say \\\"hi\\\"");
    expect_escape("backslash", "a\\b", "a\\\\b");
    expect_escape("quote_and_backslash", "\\\"", "\\\\\\\"");
    expect_escape("newline", "a\nb", "a\\nb");
    expect_escape("tab", "a\tb", "a\\tb");
    expect_escape("cr", "a\rb", "a\\rb");
    expect_escape("backspace", "a\bb", "a\\bb");
    expect_escape("formfeed", "a\fb", "a\\fb");
    expect_escape("other_control_01", "\x01", "\\u0001");
    expect_escape("other_control_1f", "\x1f", "\\u001f");
    expect_escape("slash_passthrough", "a/b", "a/b");

    cafe[0] = 'c';
    cafe[1] = 'a';
    cafe[2] = 'f';
    cafe[3] = 0xC3;
    cafe[4] = 0xA9;
    {
        size_t n = 0;
        char *got = escape_dup(cafe, 5, &n);
        if (got == NULL || n != 5 || memcmp(got, cafe, 5) != 0) {
            fail("utf8_cafe", "UTF-8 must pass through");
        }
        free(got);
        expect_roundtrip("utf8_cafe_roundtrip", cafe, 5);
    }

    grin[0] = 0xF0;
    grin[1] = 0x9F;
    grin[2] = 0x98;
    grin[3] = 0x80;
    expect_roundtrip("utf8_emoji", grin, 4);
    {
        size_t n = 0;
        char *got = escape_dup(grin, 4, &n);
        if (got == NULL || n != 4 || memcmp(got, grin, 4) != 0) {
            fail("utf8_emoji_passthrough", "4-byte UTF-8 must pass through");
        }
        free(got);
    }

    controls[0] = '"';
    controls[1] = '\\';
    controls[2] = '\n';
    controls[3] = '\t';
    controls[4] = '\r';
    controls[5] = '\b';
    controls[6] = '\f';
    controls[7] = 0x01;
    expect_roundtrip("controls_roundtrip", controls, sizeof controls);

    mixed[0] = '{';
    mixed[1] = '"';
    mixed[2] = 'x';
    mixed[3] = '"';
    mixed[4] = ':';
    mixed[5] = '"';
    mixed[6] = '\\';
    mixed[7] = 0xC3;
    mixed[8] = 0xA9;
    mixed[9] = '"';
    mixed[10] = '}';
    expect_roundtrip("jsonish_utf8", mixed, sizeof mixed);

    nulq[0] = 'a';
    nulq[1] = 0;
    nulq[2] = 'b';
    {
        size_t n = 0;
        char *got = escape_dup(nulq, 3, &n);
        if (got == NULL || n != 8 || memcmp(got, "a\\u0000b", 8) != 0) {
            fail("nul_escape", "NUL must become \\\\u0000");
        }
        free(got);
    }

    expect_unescape("unescape_quote", "say \\\"hi\\\"", "say \"hi\"");
    expect_unescape("unescape_backslash", "a\\\\b", "a\\b");
    expect_unescape("unescape_slash", "a\\/b", "a/b");
    expect_unescape("unescape_u0022", "\\u0022", "\"");
    expect_unescape("unescape_u00e9", "\\u00e9", "\xC3\xA9");

    bad_ff[0] = 0xFF;
    if (rv_utf8_is_valid(bad_ff, 1) || rv_json_escaped_len(bad_ff, 1) != (size_t)-1) {
        fail("invalid_ff", "0xFF must be rejected");
    }
    overlong[0] = 0xC0;
    overlong[1] = 0x80;
    if (rv_utf8_is_valid(overlong, 2)) {
        fail("overlong", "overlong UTF-8 must be rejected");
    }
    trunc[0] = 0xC3;
    trunc[1] = 'a';
    if (rv_utf8_is_valid(trunc, 1)) {
        fail("truncated", "truncated UTF-8 must be rejected");
    }
    if (rv_json_escape(bad_ff, 1, NULL, 0, NULL) == 0) {
        fail("escape_invalid", "invalid UTF-8 must not escape");
    }

    for (c = 0; c < 0x20; c++) {
        unsigned char ch = (unsigned char)c;
        size_t n = 0;
        char *got;
        if (!rv_utf8_is_valid(&ch, 1)) {
            fail("ascii_control_utf8", "C0 controls are valid UTF-8");
            break;
        }
        got = escape_dup(&ch, 1, &n);
        if (got == NULL) {
            fail("ascii_control_escape", "C0 control failed to escape");
            break;
        }
        if (c == '"' || c == '\\') {
            /* not in this loop */
        } else if (c == '\b' || c == '\f' || c == '\n' || c == '\r' || c == '\t') {
            if (n != 2 || got[0] != '\\') {
                fail("ascii_control_short", "expected short escape");
            }
        } else {
            if (n != 6 || memcmp(got, "\\u00", 4) != 0) {
                fail("ascii_control_u", "expected \\u00XX");
            }
        }
        free(got);
    }

    if (g_fails != 0) {
        fprintf(stderr, "%d failure(s)\n", g_fails);
        return 1;
    }
    printf("json_escape tests ok\n");
    return 0;
}
