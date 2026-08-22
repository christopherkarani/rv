#include "json_escape.h"

#include <stdlib.h>
#include <string.h>

static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return 10 + (c - 'a');
    }
    if (c >= 'A' && c <= 'F') {
        return 10 + (c - 'A');
    }
    return -1;
}

int rv_utf8_is_valid(const unsigned char *src, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char c = src[i];
        if (c <= 0x7F) {
            i += 1;
            continue;
        }
        unsigned int cp;
        int extra;
        if ((c & 0xE0) == 0xC0) {
            extra = 1;
            cp = (unsigned int)(c & 0x1F);
            if (c < 0xC2) {
                return 0;
            }
        } else if ((c & 0xF0) == 0xE0) {
            extra = 2;
            cp = (unsigned int)(c & 0x0F);
        } else if ((c & 0xF8) == 0xF0) {
            extra = 3;
            cp = (unsigned int)(c & 0x07);
            if (c > 0xF4) {
                return 0;
            }
        } else {
            return 0;
        }
        if (i + 1 + (size_t)extra > n) {
            return 0;
        }
        for (int k = 0; k < extra; k++) {
            unsigned char cc = src[i + 1 + (size_t)k];
            if ((cc & 0xC0) != 0x80) {
                return 0;
            }
            cp = (cp << 6) | (unsigned int)(cc & 0x3F);
        }
        if (extra == 2 && cp < 0x800) {
            return 0;
        }
        if (extra == 3 && cp < 0x10000) {
            return 0;
        }
        if (cp >= 0xD800 && cp <= 0xDFFF) {
            return 0;
        }
        if (cp > 0x10FFFF) {
            return 0;
        }
        i += 1 + (size_t)extra;
    }
    return 1;
}

static size_t escaped_len_valid(const unsigned char *src, size_t n) {
    size_t out = 0;
    size_t i;
    for (i = 0; i < n; i++) {
        unsigned char c = src[i];
        switch (c) {
        case '"':
        case '\\':
        case '\b':
        case '\f':
        case '\n':
        case '\r':
        case '\t':
            out += 2;
            break;
        default:
            if (c < 0x20) {
                out += 6;
            } else {
                out += 1;
            }
            break;
        }
    }
    return out;
}

size_t rv_json_escaped_len(const unsigned char *src, size_t n) {
    if (n > 0 && src == NULL) {
        return (size_t)-1;
    }
    if (!rv_utf8_is_valid(src, n)) {
        return (size_t)-1;
    }
    return escaped_len_valid(src, n);
}

static char hex_lc(unsigned int v) {
    return (char)(v < 10 ? ('0' + v) : ('a' + (v - 10)));
}

int rv_json_escape(
    const unsigned char *src,
    size_t n,
    char *dst,
    size_t dst_cap,
    size_t *out_len
) {
    size_t need = rv_json_escaped_len(src, n);
    if (need == (size_t)-1) {
        return -1;
    }
    if (out_len != NULL) {
        *out_len = need;
    }
    if (dst == NULL) {
        return 0;
    }
    if (dst_cap < need + 1) {
        return -1;
    }
    size_t o = 0;
    size_t i;
    for (i = 0; i < n; i++) {
        unsigned char c = src[i];
        switch (c) {
        case '"':
            dst[o++] = '\\';
            dst[o++] = '"';
            break;
        case '\\':
            dst[o++] = '\\';
            dst[o++] = '\\';
            break;
        case '\b':
            dst[o++] = '\\';
            dst[o++] = 'b';
            break;
        case '\f':
            dst[o++] = '\\';
            dst[o++] = 'f';
            break;
        case '\n':
            dst[o++] = '\\';
            dst[o++] = 'n';
            break;
        case '\r':
            dst[o++] = '\\';
            dst[o++] = 'r';
            break;
        case '\t':
            dst[o++] = '\\';
            dst[o++] = 't';
            break;
        default:
            if (c < 0x20) {
                dst[o++] = '\\';
                dst[o++] = 'u';
                dst[o++] = '0';
                dst[o++] = '0';
                dst[o++] = hex_lc((unsigned int)c >> 4);
                dst[o++] = hex_lc((unsigned int)c & 0xF);
            } else {
                dst[o++] = (char)c;
            }
            break;
        }
    }
    dst[o] = '\0';
    return 0;
}

static int utf8_append(char *dst, size_t *o, size_t cap, unsigned int cp) {
    if (cp <= 0x7F) {
        if (*o + 1 > cap) {
            return -1;
        }
        dst[(*o)++] = (char)cp;
        return 0;
    }
    if (cp <= 0x7FF) {
        if (*o + 2 > cap) {
            return -1;
        }
        dst[(*o)++] = (char)(0xC0 | (cp >> 6));
        dst[(*o)++] = (char)(0x80 | (cp & 0x3F));
        return 0;
    }
    if (cp <= 0xFFFF) {
        if (*o + 3 > cap) {
            return -1;
        }
        dst[(*o)++] = (char)(0xE0 | (cp >> 12));
        dst[(*o)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        dst[(*o)++] = (char)(0x80 | (cp & 0x3F));
        return 0;
    }
    if (cp <= 0x10FFFF) {
        if (*o + 4 > cap) {
            return -1;
        }
        dst[(*o)++] = (char)(0xF0 | (cp >> 18));
        dst[(*o)++] = (char)(0x80 | ((cp >> 12) & 0x3F));
        dst[(*o)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        dst[(*o)++] = (char)(0x80 | (cp & 0x3F));
        return 0;
    }
    return -1;
}

static int read_u4(const char *src, size_t n, size_t i, unsigned int *out) {
    if (i + 4 > n) {
        return -1;
    }
    unsigned int v = 0;
    int k;
    for (k = 0; k < 4; k++) {
        int d = hex_digit((unsigned char)src[i + (size_t)k]);
        if (d < 0) {
            return -1;
        }
        v = (v << 4) | (unsigned int)d;
    }
    *out = v;
    return 0;
}

int rv_json_unescape(const char *src, size_t n, char **out, size_t *out_len) {
    char *dst;
    size_t o = 0;
    size_t i = 0;
    unsigned int pending_hi = 0;
    int has_hi = 0;

    if (n > 0 && src == NULL) {
        return -1;
    }
    dst = (char *)malloc(n + 1);
    if (dst == NULL) {
        return -1;
    }

    while (i < n) {
        unsigned char c = (unsigned char)src[i];
        if (c != '\\') {
            if (has_hi) {
                free(dst);
                return -1;
            }
            dst[o++] = (char)c;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= n) {
            free(dst);
            return -1;
        }
        c = (unsigned char)src[i];
        i += 1;
        if (c != 'u' && has_hi) {
            free(dst);
            return -1;
        }
        switch (c) {
        case '"':
        case '\\':
        case '/':
            dst[o++] = (char)c;
            break;
        case 'b':
            dst[o++] = '\b';
            break;
        case 'f':
            dst[o++] = '\f';
            break;
        case 'n':
            dst[o++] = '\n';
            break;
        case 'r':
            dst[o++] = '\r';
            break;
        case 't':
            dst[o++] = '\t';
            break;
        case 'u': {
            unsigned int cp;
            if (read_u4(src, n, i, &cp) != 0) {
                free(dst);
                return -1;
            }
            i += 4;
            if (has_hi) {
                if (cp < 0xDC00 || cp > 0xDFFF) {
                    free(dst);
                    return -1;
                }
                unsigned int full = 0x10000 + ((pending_hi - 0xD800) << 10) + (cp - 0xDC00);
                if (utf8_append(dst, &o, n + 1, full) != 0) {
                    free(dst);
                    return -1;
                }
                has_hi = 0;
                pending_hi = 0;
            } else if (cp >= 0xD800 && cp <= 0xDBFF) {
                pending_hi = cp;
                has_hi = 1;
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                free(dst);
                return -1;
            } else {
                if (utf8_append(dst, &o, n + 1, cp) != 0) {
                    free(dst);
                    return -1;
                }
            }
            break;
        }
        default:
            free(dst);
            return -1;
        }
    }
    if (has_hi) {
        free(dst);
        return -1;
    }
    dst[o] = '\0';
    *out = dst;
    if (out_len != NULL) {
        *out_len = o;
    }
    return 0;
}
