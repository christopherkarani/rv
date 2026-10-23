#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "daemon_trust.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <Security/SecCode.h>
#include <Security/SecRequirement.h>
#include <Security/SecStaticCode.h>
#include <mach-o/dyld.h>
#include <sys/acl.h>

#define RV_MANIFEST_PATH "/Library/Application Support/RV/peer-trust.json"
#define RV_MANIFEST_MAX 65536

/* Lexically canonical absolute path: no empty, "." or ".." components. */
static int path_is_canonical(const char *path) {
    size_t n;
    size_t i;
    if (path == NULL || path[0] != '/') {
        return 0;
    }
    n = strlen(path);
    if (n > 1 && path[n - 1] == '/') {
        return 0;
    }
    for (i = 0; i < n; i++) {
        if (path[i] == '/' && i + 1 < n) {
            char c = path[i + 1];
            if (c == '/') {
                return 0;
            }
            if (c == '.' && (i + 2 >= n || path[i + 2] == '/')) {
                return 0;
            }
            if (c == '.' && i + 2 < n && path[i + 2] == '.'
                && (i + 3 >= n || path[i + 3] == '/')) {
                return 0;
            }
        }
    }
    return 1;
}

static int acl_has_no_allow(acl_t acl) {
    acl_entry_t entry = NULL;
    int selector = ACL_FIRST_ENTRY;
    if (acl_valid(acl) != 0) {
        return 0;
    }
    for (;;) {
        acl_tag_t tag = ACL_UNDEFINED_TAG;
        errno = 0;
        if (acl_get_entry(acl, selector, &entry) != 0) {
            return errno == EINVAL;
        }
        if (entry == NULL || acl_get_tag_type(entry, &tag) != 0
            || tag != ACL_EXTENDED_DENY) {
            return 0;
        }
        selector = ACL_NEXT_ENTRY;
    }
}

static int path_has_no_allow_acl(const char *path) {
    struct stat info;
    acl_t acl;
    int ok;
    if (lstat(path, &info) != 0) {
        return 0;
    }
    errno = 0;
    acl = acl_get_file(path, ACL_TYPE_EXTENDED);
    if (acl == NULL) {
        return errno == ENOENT;
    }
    ok = acl_has_no_allow(acl);
    acl_free((void *)acl);
    return ok;
}

static int fd_has_no_allow_acl(int fd) {
    struct stat info;
    acl_t acl;
    int ok;
    if (fstat(fd, &info) != 0) {
        return 0;
    }
    errno = 0;
    acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (acl == NULL) {
        return errno == ENOENT;
    }
    ok = acl_has_no_allow(acl);
    acl_free((void *)acl);
    return ok;
}

static int stat_is_safe(const struct stat *info) {
    return info->st_uid == 0 && (info->st_mode & 0022) == 0;
}

/* Root-owned, non-writable, allow-ACL-free chain from `path` up to `/`. */
static int protected_path(const char *path, int is_file) {
    char current[PATH_MAX];
    int first = 1;
    if (!path_is_canonical(path) || strlen(path) >= sizeof current) {
        return 0;
    }
    memcpy(current, path, strlen(path) + 1);
    for (;;) {
        struct stat info;
        mode_t want = (first && is_file) ? S_IFREG : S_IFDIR;
        if (lstat(current, &info) != 0 || !stat_is_safe(&info)
            || !path_has_no_allow_acl(current)
            || (info.st_mode & S_IFMT) != want) {
            return 0;
        }
        if (strcmp(current, "/") == 0) {
            return 1;
        }
        {
            char *slash = strrchr(current, '/');
            if (slash == NULL) {
                return 0;
            }
            if (slash == current) {
                current[1] = '\0';
            } else {
                *slash = '\0';
            }
        }
        first = 0;
    }
}

/* ------------------------------------------------------------------ */
/* Strict manifest JSON: an array of flat string-valued objects.      */
/* Anything else (numbers, nesting, duplicate keys, trailing bytes)  */
/* fails closed. Mirrors the Swift Codable `[Entry]` shape.           */

struct ManifestEntry {
    char *role;
    char *requirement;
    char *required_identifier;
    char *required_team;
    char *dev_cdhash;
    char *dev_path;
};

#define RV_MANIFEST_MAX_ENTRIES 8

struct JsonCursor {
    const unsigned char *p;
    size_t left;
};

static void json_skip_ws(struct JsonCursor *c) {
    while (c->left > 0 && (c->p[0] == ' ' || c->p[0] == '\t'
        || c->p[0] == '\n' || c->p[0] == '\r')) {
        c->p++;
        c->left--;
    }
}

static int json_take(struct JsonCursor *c, char want) {
    json_skip_ws(c);
    if (c->left == 0 || c->p[0] != (unsigned char)want) {
        return 0;
    }
    c->p++;
    c->left--;
    return 1;
}

/* Parses one JSON string into a fresh NUL-terminated allocation. Only
 * ASCII output is accepted: `\u` must name a code point below 0x80.
 * Manifest fields are identifiers, hashes, paths and requirements. */
static char *json_string(struct JsonCursor *c) {
    size_t cap = 64;
    size_t len = 0;
    char *out;
    if (!json_take(c, '"')) {
        return NULL;
    }
    out = (char *)malloc(cap);
    if (out == NULL) {
        return NULL;
    }
    for (;;) {
        unsigned char ch;
        if (c->left == 0) {
            free(out);
            return NULL;
        }
        ch = c->p[0];
        c->p++;
        c->left--;
        if (ch == '"') {
            break;
        }
        if (ch == '\\') {
            if (c->left == 0) {
                free(out);
                return NULL;
            }
            ch = c->p[0];
            c->p++;
            c->left--;
            switch (ch) {
            case '"': break;
            case '\\': break;
            case '/': break;
            case 'b': ch = '\b'; break;
            case 'f': ch = '\f'; break;
            case 'n': ch = '\n'; break;
            case 'r': ch = '\r'; break;
            case 't': ch = '\t'; break;
            case 'u': {
                unsigned value = 0;
                int i;
                if (c->left < 4) {
                    free(out);
                    return NULL;
                }
                for (i = 0; i < 4; i++) {
                    unsigned char h = c->p[0];
                    c->p++;
                    c->left--;
                    value <<= 4;
                    if (h >= '0' && h <= '9') {
                        value += (unsigned)(h - '0');
                    } else if (h >= 'a' && h <= 'f') {
                        value += (unsigned)(h - 'a' + 10);
                    } else if (h >= 'A' && h <= 'F') {
                        value += (unsigned)(h - 'A' + 10);
                    } else {
                        free(out);
                        return NULL;
                    }
                }
                if (value == 0 || value >= 0x80) {
                    free(out);
                    return NULL;
                }
                ch = (unsigned char)value;
                break;
            }
            default:
                free(out);
                return NULL;
            }
        } else if (ch < 0x20 || ch >= 0x80) {
            free(out);
            return NULL;
        }
        if (len + 2 > cap) {
            char *grown;
            cap *= 2;
            grown = (char *)realloc(out, cap);
            if (grown == NULL) {
                free(out);
                return NULL;
            }
            out = grown;
        }
        out[len++] = (char)ch;
    }
    out[len] = '\0';
    return out;
}

static void entry_free(struct ManifestEntry *e) {
    free(e->role);
    free(e->requirement);
    free(e->required_identifier);
    free(e->required_team);
    free(e->dev_cdhash);
    free(e->dev_path);
    memset(e, 0, sizeof *e);
}

static int json_entry(struct JsonCursor *c, struct ManifestEntry *e) {
    memset(e, 0, sizeof *e);
    if (!json_take(c, '{')) {
        return 0;
    }
    if (json_take(c, '}')) {
        return 1;
    }
    for (;;) {
        char *key = json_string(c);
        char *value;
        char **slot = NULL;
        if (key == NULL || !json_take(c, ':')) {
            free(key);
            return 0;
        }
        value = json_string(c);
        if (value == NULL) {
            free(key);
            return 0;
        }
        if (strcmp(key, "role") == 0) {
            slot = &e->role;
        } else if (strcmp(key, "requirement") == 0) {
            slot = &e->requirement;
        } else if (strcmp(key, "requiredIdentifier") == 0) {
            slot = &e->required_identifier;
        } else if (strcmp(key, "requiredTeamIdentifier") == 0) {
            slot = &e->required_team;
        } else if (strcmp(key, "developmentCDHash") == 0) {
            slot = &e->dev_cdhash;
        } else if (strcmp(key, "developmentExecutablePath") == 0) {
            slot = &e->dev_path;
        }
        free(key);
        if (slot == NULL || *slot != NULL) {
            free(value);
            return 0;
        }
        *slot = value;
        if (json_take(c, ',')) {
            continue;
        }
        return json_take(c, '}');
    }
}

static int is_hex40(const char *s) {
    size_t i;
    if (strlen(s) != 40) {
        return 0;
    }
    for (i = 0; i < 40; i++) {
        char ch = s[i];
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
            || (ch >= 'A' && ch <= 'F'))) {
            return 0;
        }
    }
    return 1;
}

static int identifier_charset_ok(const char *s) {
    size_t i;
    if (s[0] == '\0') {
        return 0;
    }
    for (i = 0; s[i] != '\0'; i++) {
        unsigned char ch = (unsigned char)s[i];
        if (!(ch < 0x80 && ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')
            || (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-'))) {
            return 0;
        }
    }
    return 1;
}

static int team_charset_ok(const char *s) {
    size_t i;
    if (s[0] == '\0') {
        return 0;
    }
    for (i = 0; s[i] != '\0'; i++) {
        unsigned char ch = (unsigned char)s[i];
        if (!(ch < 0x80 && ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')
            || (ch >= '0' && ch <= '9')))) {
            return 0;
        }
    }
    return 1;
}

static int requirement_parses(const char *text) {
    CFStringRef cf = CFStringCreateWithCString(
        kCFAllocatorDefault, text, kCFStringEncodingUTF8);
    SecRequirementRef req = NULL;
    OSStatus st;
    if (cf == NULL) {
        return 0;
    }
    st = SecRequirementCreateWithString(cf, kSecCSDefaultFlags, &req);
    CFRelease(cf);
    if (req != NULL) {
        CFRelease(req);
    }
    return st == errSecSuccess && req != NULL;
}

/* Validates one entry exactly like the Swift loader. */
static int entry_valid(const struct ManifestEntry *e) {
    if (e->role == NULL || e->requirement == NULL) {
        return 0;
    }
    if (strcmp(e->role, "cli") != 0 && strcmp(e->role, "service") != 0
        && strcmp(e->role, "workspaceHost") != 0
        && strcmp(e->role, "operatorUI") != 0) {
        return 0;
    }
    if (!requirement_parses(e->requirement)) {
        return 0;
    }
    if (e->dev_cdhash != NULL) {
        char want[64];
        size_t i;
        if (!is_hex40(e->dev_cdhash) || e->dev_path == NULL
            || !protected_path(e->dev_path, 1)) {
            return 0;
        }
        strcpy(want, "cdhash H\"");
        for (i = 0; i < 40; i++) {
            char ch = e->dev_cdhash[i];
            if (ch >= 'A' && ch <= 'F') {
                ch = (char)(ch - 'A' + 'a');
            }
            want[9 + i] = ch;
        }
        want[49] = '"';
        want[50] = '\0';
        return strcmp(e->requirement, want) == 0;
    }
    return e->dev_path == NULL
        && e->required_identifier != NULL && e->required_team != NULL
        && identifier_charset_ok(e->required_identifier)
        && team_charset_ok(e->required_team);
}

enum TrustSource { TRUST_INVALID = 0, TRUST_MANIFEST = 1, TRUST_SIBLING = 2 };

static enum TrustSource g_source = TRUST_INVALID;
static int g_source_loaded = 0;
static struct ManifestEntry g_service;
static int g_has_service = 0;

/* Loads and validates the manifest; keeps the service entry. 1 on success. */
static int manifest_load(void) {
    int fd;
    struct stat info;
    unsigned char *bytes = NULL;
    size_t len = 0;
    struct JsonCursor cursor;
    struct ManifestEntry entries[RV_MANIFEST_MAX_ENTRIES];
    int count = 0;
    int i;
    int ok = 0;

    memset(entries, 0, sizeof entries);
    if (!protected_path(RV_MANIFEST_PATH, 1)) {
        return 0;
    }
    fd = open(RV_MANIFEST_PATH, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        return 0;
    }
    if (fstat(fd, &info) != 0 || !stat_is_safe(&info)
        || !fd_has_no_allow_acl(fd)
        || (info.st_mode & S_IFMT) != S_IFREG
        || info.st_size < 0 || info.st_size > RV_MANIFEST_MAX) {
        close(fd);
        return 0;
    }
    bytes = (unsigned char *)malloc(RV_MANIFEST_MAX + 1);
    if (bytes == NULL) {
        close(fd);
        return 0;
    }
    for (;;) {
        ssize_t n = read(fd, bytes + len, RV_MANIFEST_MAX + 1 - len);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            goto out;
        }
        if (n == 0) {
            break;
        }
        len += (size_t)n;
        if (len > RV_MANIFEST_MAX) {
            goto out;
        }
    }
    close(fd);
    fd = -1;

    cursor.p = bytes;
    cursor.left = len;
    if (!json_take(&cursor, '[')) {
        goto out;
    }
    if (!json_take(&cursor, ']')) {
        for (;;) {
            if (count >= RV_MANIFEST_MAX_ENTRIES) {
                goto out;
            }
            if (!json_entry(&cursor, &entries[count])) {
                entry_free(&entries[count]);
                goto out;
            }
            count++;
            if (json_take(&cursor, ',')) {
                continue;
            }
            if (!json_take(&cursor, ']')) {
                goto out;
            }
            break;
        }
    }
    json_skip_ws(&cursor);
    if (cursor.left != 0) {
        goto out;
    }
    for (i = 0; i < count; i++) {
        int j;
        if (!entry_valid(&entries[i])) {
            goto out;
        }
        for (j = i + 1; j < count; j++) {
            if (strcmp(entries[i].role, entries[j].role) == 0) {
                goto out;
            }
        }
        if (strcmp(entries[i].role, "service") == 0) {
            g_service = entries[i];
            memset(&entries[i], 0, sizeof entries[i]);
            g_has_service = 1;
        }
    }
    ok = 1;
out:
    if (fd >= 0) {
        close(fd);
    }
    free(bytes);
    for (i = 0; i < count; i++) {
        entry_free(&entries[i]);
    }
    if (!ok && g_has_service) {
        entry_free(&g_service);
        g_has_service = 0;
    }
    return ok;
}

static enum TrustSource trust_source(void) {
    struct stat info;
    if (g_source_loaded) {
        return g_source;
    }
    g_source_loaded = 1;
    if (lstat(RV_MANIFEST_PATH, &info) != 0) {
        g_source = (errno == ENOENT) ? TRUST_SIBLING : TRUST_INVALID;
        return g_source;
    }
    g_source = manifest_load() ? TRUST_MANIFEST : TRUST_INVALID;
    return g_source;
}

/* ------------------------------------------------------------------ */
/* Peer code identity (mirror of `MacOSPeerCodeVerifier`).             */

struct PeerIdentity {
    char identifier[256];
    char team[64];
    int has_team;
    unsigned char cdhash[32];
    size_t cdhash_len;
    char exe_path[PATH_MAX];
    int is_adhoc;
    int hardened;
    int has_injection;
};

static int cf_string_copy(CFStringRef s, char *out, size_t cap) {
    if (s == NULL || CFGetTypeID(s) != CFStringGetTypeID()) {
        return 0;
    }
    return CFStringGetCString(s, out, (CFIndex)cap, kCFStringEncodingUTF8) != 0;
}

static const char *const kInjectionKeys[] = {
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.get-task-allow",
    "get-task-allow",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-executable-page-protection",
};

/* Extracts identity from a static code object. 1 on success. */
static int identity_from_static(SecStaticCodeRef code, struct PeerIdentity *out) {
    CFDictionaryRef info = NULL;
    CFStringRef identifier;
    CFDataRef hash;
    CFURLRef exe;
    CFNumberRef flags;
    CFDictionaryRef entitlements;
    uint32_t flag_value = 0;
    size_t i;
    int ok = 0;

    memset(out, 0, sizeof *out);
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) != errSecSuccess
        || info == NULL || CFGetTypeID(info) != CFDictionaryGetTypeID()) {
        goto out;
    }
    identifier = (CFStringRef)CFDictionaryGetValue(info, kSecCodeInfoIdentifier);
    hash = (CFDataRef)CFDictionaryGetValue(info, kSecCodeInfoUnique);
    exe = (CFURLRef)CFDictionaryGetValue(info, kSecCodeInfoMainExecutable);
    flags = (CFNumberRef)CFDictionaryGetValue(info, kSecCodeInfoFlags);
    if (identifier == NULL || hash == NULL || exe == NULL || flags == NULL
        || CFGetTypeID(hash) != CFDataGetTypeID()
        || CFGetTypeID(exe) != CFURLGetTypeID()
        || CFGetTypeID(flags) != CFNumberGetTypeID()) {
        goto out;
    }
    if (!cf_string_copy(identifier, out->identifier, sizeof out->identifier)) {
        goto out;
    }
    out->cdhash_len = (size_t)CFDataGetLength(hash);
    if (out->cdhash_len == 0 || out->cdhash_len > sizeof out->cdhash) {
        goto out;
    }
    memcpy(out->cdhash, CFDataGetBytePtr(hash), out->cdhash_len);
    if (!CFURLGetFileSystemRepresentation(exe, true,
            (UInt8 *)out->exe_path, sizeof out->exe_path)) {
        goto out;
    }
    if (!CFNumberGetValue(flags, kCFNumberSInt32Type, &flag_value)) {
        int64_t wide = 0;
        if (!CFNumberGetValue(flags, kCFNumberSInt64Type, &wide)) {
            goto out;
        }
        flag_value = (uint32_t)wide;
    }
    out->is_adhoc = (flag_value & 0x0002) != 0;
    out->hardened = (flag_value & 0x10000) != 0;
    {
        CFStringRef team = (CFStringRef)CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
        out->has_team = cf_string_copy(team, out->team, sizeof out->team);
    }
    entitlements = (CFDictionaryRef)CFDictionaryGetValue(info, kSecCodeInfoEntitlementsDict);
    if (entitlements != NULL && CFGetTypeID(entitlements) == CFDictionaryGetTypeID()) {
        for (i = 0; i < sizeof kInjectionKeys / sizeof kInjectionKeys[0]; i++) {
            CFStringRef key = CFStringCreateWithCString(
                kCFAllocatorDefault, kInjectionKeys[i], kCFStringEncodingUTF8);
            CFTypeRef value;
            if (key == NULL) {
                goto out;
            }
            value = CFDictionaryGetValue(entitlements, key);
            CFRelease(key);
            if (value == NULL) {
                continue;
            }
            /* Missing/explicit false is acceptable; unknown types fail closed. */
            if (CFGetTypeID(value) != CFBooleanGetTypeID()
                || CFBooleanGetValue((CFBooleanRef)value)) {
                out->has_injection = 1;
            }
        }
    }
    ok = 1;
out:
    if (info != NULL) {
        CFRelease(info);
    }
    return ok;
}

/* Verifies `code` against `requirement_text`. */
static int code_satisfies(SecCodeRef code, const char *requirement_text) {
    CFStringRef cf = CFStringCreateWithCString(
        kCFAllocatorDefault, requirement_text, kCFStringEncodingUTF8);
    SecRequirementRef req = NULL;
    OSStatus st;
    if (cf == NULL) {
        return 0;
    }
    st = SecRequirementCreateWithString(cf, kSecCSDefaultFlags, &req);
    CFRelease(cf);
    if (st != errSecSuccess || req == NULL) {
        return 0;
    }
    st = SecCodeCheckValidity(code, kSecCSDefaultFlags, req);
    CFRelease(req);
    return st == errSecSuccess;
}

static void hex_encode(const unsigned char *bytes, size_t n, char *out) {
    static const char digits[] = "0123456789abcdef";
    size_t i;
    for (i = 0; i < n; i++) {
        out[2 * i] = digits[bytes[i] >> 4];
        out[2 * i + 1] = digits[bytes[i] & 0x0f];
    }
    out[2 * n] = '\0';
}

/* Captures the reply sender's identity, rebound to its live code. The
 * returned SecCodeRef is owned by the caller (release with CFRelease). */
static int capture_peer(xpc_object_t reply, SecCodeRef *code_out, struct PeerIdentity *out) {
    SecCodeRef code = NULL;
    SecStaticCodeRef static_code = NULL;
    char hash_text[65];
    char requirement[80];
    int ok = 0;

    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        return 0;
    }
    if (SecCodeCreateWithXPCMessage(reply, kSecCSDefaultFlags, &code) != errSecSuccess
        || code == NULL) {
        return 0;
    }
    if (SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL) != errSecSuccess) {
        goto out;
    }
    if (SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &static_code) != errSecSuccess
        || static_code == NULL) {
        goto out;
    }
    if (!identity_from_static(static_code, out)) {
        goto out;
    }
    hex_encode(out->cdhash, out->cdhash_len, hash_text);
    snprintf(requirement, sizeof requirement, "cdhash H\"%s\"", hash_text);
    if (!code_satisfies(code, requirement)) {
        goto out;
    }
    *code_out = code;
    code = NULL;
    ok = 1;
out:
    if (static_code != NULL) {
        CFRelease(static_code);
    }
    if (code != NULL) {
        CFRelease(code);
    }
    return ok;
}

/* Manifest `.service` role check (mirror of `role(code:identity:)`). */
static int has_service_role(SecCodeRef code, const struct PeerIdentity *id) {
    const struct ManifestEntry *e;
    if (!g_has_service || !id->hardened || id->has_injection) {
        return 0;
    }
    e = &g_service;
    if (e->dev_cdhash != NULL) {
        char peer_hash[65];
        hex_encode(id->cdhash, id->cdhash_len, peer_hash);
        if (strcasecmp(peer_hash, e->dev_cdhash) != 0
            || strcmp(id->exe_path, e->dev_path) != 0
            || !protected_path(id->exe_path, 1)) {
            return 0;
        }
    } else {
        char production[512];
        if (id->is_adhoc || !id->has_team
            || strcmp(id->identifier, e->required_identifier) != 0
            || strcmp(id->team, e->required_team) != 0) {
            return 0;
        }
        snprintf(production, sizeof production,
            "anchor apple generic and identifier \"%s\" and certificate leaf[subject.OU] = \"%s\"",
            id->identifier, id->team);
        if (!code_satisfies(code, production)) {
            return 0;
        }
    }
    return code_satisfies(code, e->requirement);
}

static int sibling_daemon_path(char *out, size_t cap) {
    char executable[PATH_MAX];
    char resolved[PATH_MAX];
    uint32_t capacity = sizeof executable;
    char *slash;
    int n;
    if (_NSGetExecutablePath(executable, &capacity) != 0) {
        return 0;
    }
    if (realpath(executable, resolved) == NULL) {
        return 0;
    }
    slash = strrchr(resolved, '/');
    if (slash == NULL) {
        return 0;
    }
    *slash = '\0';
    n = snprintf(out, cap, "%s/rvd", resolved);
    return n > 0 && (size_t)n < cap;
}

/* Sibling-pin check: live peer must be the exact on-disk sibling bytes. */
static int matches_sibling(const struct PeerIdentity *peer) {
    char sibling[PATH_MAX];
    char peer_real[PATH_MAX];
    char sibling_real[PATH_MAX];
    CFURLRef url;
    SecStaticCodeRef static_code = NULL;
    struct PeerIdentity on_disk;
    int ok = 0;

    if (peer->cdhash_len == 0 || !sibling_daemon_path(sibling, sizeof sibling)) {
        return 0;
    }
    if (realpath(peer->exe_path, peer_real) == NULL
        || realpath(sibling, sibling_real) == NULL
        || strcmp(peer_real, sibling_real) != 0) {
        return 0;
    }
    url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)sibling, (CFIndex)strlen(sibling), false);
    if (url == NULL) {
        return 0;
    }
    if (SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &static_code) == errSecSuccess
        && static_code != NULL
        && SecStaticCodeCheckValidity(static_code, kSecCSDefaultFlags, NULL) == errSecSuccess
        && identity_from_static(static_code, &on_disk)) {
        ok = peer->cdhash_len == on_disk.cdhash_len
            && memcmp(peer->cdhash, on_disk.cdhash, peer->cdhash_len) == 0;
    }
    if (static_code != NULL) {
        CFRelease(static_code);
    }
    CFRelease(url);
    return ok;
}

int rv_verify_daemon_reply(xpc_object_t reply) {
    SecCodeRef code = NULL;
    struct PeerIdentity identity;
    enum TrustSource source;
    int ok = 0;

    if (!capture_peer(reply, &code, &identity)) {
        return 0;
    }
    source = trust_source();
    if (source == TRUST_MANIFEST) {
        ok = has_service_role(code, &identity);
    } else if (source == TRUST_SIBLING) {
        xpc_connection_t remote = xpc_dictionary_get_remote_connection(reply);
        ok = remote != NULL
            && xpc_connection_get_euid(remote) == geteuid()
            && matches_sibling(&identity);
    }
    CFRelease(code);
    return ok;
}

#else /* Linux */

#include <sys/socket.h>

int rv_verify_unix_daemon(int fd) {
    struct ucred cred;
    socklen_t length = sizeof cred;
    char link_path[64];
    char peer_exe[PATH_MAX];
    char self_exe[PATH_MAX];
    char sibling[PATH_MAX];
    char peer_real[PATH_MAX];
    char sibling_real[PATH_MAX];
    char *slash;
    ssize_t n;
    int written;

    memset(&cred, 0, sizeof cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &length) != 0
        || length != sizeof cred || cred.pid <= 0 || cred.uid != geteuid()) {
        return 0;
    }
    written = snprintf(link_path, sizeof link_path, "/proc/%d/exe", (int)cred.pid);
    if (written <= 0 || (size_t)written >= sizeof link_path) {
        return 0;
    }
    n = readlink(link_path, peer_exe, sizeof peer_exe - 1);
    if (n < 0 || n >= (ssize_t)sizeof peer_exe - 1) {
        return 0;
    }
    peer_exe[n] = '\0';
    n = readlink("/proc/self/exe", self_exe, sizeof self_exe - 1);
    if (n < 0 || n >= (ssize_t)sizeof self_exe - 1) {
        return 0;
    }
    self_exe[n] = '\0';
    if (realpath(self_exe, sibling) == NULL) {
        return 0;
    }
    slash = strrchr(sibling, '/');
    if (slash == NULL) {
        return 0;
    }
    slash[1] = '\0';
    if (strlen(sibling) + 4 > sizeof sibling) {
        return 0;
    }
    strcat(sibling, "rvd");
    if (realpath(peer_exe, peer_real) == NULL
        || realpath(sibling, sibling_real) == NULL) {
        return 0;
    }
    return strcmp(peer_real, sibling_real) == 0;
}

#endif
