/* Linux test double for run.sh, installed as the sibling `rvd` so the
 * hook's peer check (SO_PEERCRED + /proc/<pid>/exe) accepts it.
 *
 *   fake_rvd drop  <socket> <record>  accept one connection, unlink the
 *       socket (so a retry finds no daemon), read the whole request frame,
 *       write its byte count to <record>, then close without replying: a
 *       verified daemon dropping an in-flight request (rvd does this while
 *       draining). Run from a non-sibling path, the hook refuses the peer and
 *       sends nothing; the record is then never written.
 *   fake_rvd stale <socket>           bind and exit without listening: the
 *       socket file stays and connect gets ECONNREFUSED.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int bind_at(const char *path) {
    struct sockaddr_un addr;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || strlen(path) >= sizeof addr.sun_path) {
        return -1;
    }
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, strlen(path) + 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int read_exact(int fd, unsigned char *p, size_t n) {
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        if (r <= 0) {
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

int main(int argc, char **argv) {
    unsigned char header[4];
    unsigned char *body;
    uint32_t len;
    int server;
    int conn;
    FILE *record;

    if (argc == 3 && strcmp(argv[1], "stale") == 0) {
        return bind_at(argv[2]) < 0 ? 1 : 0;
    }
    if (argc != 4 || strcmp(argv[1], "drop") != 0) {
        fprintf(stderr, "usage: fake_rvd drop <socket> <record> | stale <socket>\n");
        return 2;
    }
    alarm(20); /* never hang the suite */
    server = bind_at(argv[2]);
    if (server < 0 || listen(server, 1) != 0) {
        return 1;
    }
    conn = accept(server, NULL, NULL);
    unlink(argv[2]);
    if (conn < 0 || read_exact(conn, header, 4) != 0) {
        return 1;
    }
    len = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16)
        | ((uint32_t)header[2] << 8) | (uint32_t)header[3];
    body = malloc(len == 0 ? 1 : len);
    if (body == NULL || read_exact(conn, body, len) != 0) {
        return 1;
    }
    record = fopen(argv[3], "w");
    if (record == NULL) {
        return 1;
    }
    fprintf(record, "%lu\n", (unsigned long)len + 4);
    fclose(record);
    close(conn);
    close(server);
    free(body);
    return 0;
}
