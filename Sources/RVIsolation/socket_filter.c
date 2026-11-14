/*
 * The socket filter of the MCP server cage
 * (docs/security/mcp-linux-sandbox.md). Compiled only into
 * rv-isolation-exec, which includes this file after landlock_confine.c.
 *
 * Landlock's network rules cover `bind` and `connect` on a TCP socket.
 * A caged process could still reach the network without either: a
 * socket of another kind (MPTCP, UDP, ICMP, raw, SCTP, any other
 * family), a connection opened by `sendto` with TCP fast open, a socket
 * that listens without being bound, or a socket made through io_uring,
 * which no filter on system calls sees. This seccomp filter closes
 * those, so that what Landlock allows is all there is:
 *
 *   socket    AF_INET and AF_INET6 only as a plain TCP stream socket
 *             (protocol 0 or IPPROTO_TCP), and only when the cage has a
 *             port to connect to; AF_UNIX only where Landlock confines
 *             it (ABI 9); every other family, type and protocol is
 *             refused with EACCES
 *   connect   where TCP sockets exist, handed to the connector outside
 *             the cage (proxy_connector.c), which makes the connection
 *             to the proxy itself or refuses it
 *   listen    refused while TCP sockets exist: one never bound would
 *             pick a port and accept connections
 *   send      `sendto`, `sendmsg` and `sendmmsg` with MSG_FASTOPEN are
 *             refused
 *   io_uring  `io_uring_setup`, `_enter` and `_register` answer ENOSYS,
 *             which programs take as "not supported" and fall back from
 *   socketpair  AF_UNIX only, and where Landlock does not confine Unix
 *             sockets only as a stream or sequenced-packet pair, which
 *             stays connected to itself: a datagram pair can be sent
 *             from to any address
 *   other     a system call of another architecture (32-bit on x86-64)
 *             kills the process, and the x32 ABI's answer ENOSYS: their
 *             numbers are not these
 *
 * The arguments tested are plain numbers, so there is nothing a second
 * thread could change after the test.
 *
 * The filter is installed after Landlock and NO_NEW_PRIVS, is inherited
 * by everything the server starts, and cannot be removed. If it cannot
 * be installed the caller exits 125 and nothing runs.
 */
#ifdef __linux__

#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <netinet/in.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>

#if defined(__x86_64__)
#define RV_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define RV_AUDIT_ARCH AUDIT_ARCH_AARCH64
#else
#error "rv-isolation-exec's socket filter knows x86-64 and arm64"
#endif

#ifndef MSG_FASTOPEN
#define MSG_FASTOPEN 0x20000000
#endif
#ifndef SECCOMP_GET_ACTION_AVAIL
#define SECCOMP_GET_ACTION_AVAIL 2
#endif
#ifndef SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV
#define SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV (1UL << 5)
#endif

#define RV_SECCOMP_ALLOW SECCOMP_RET_ALLOW
#define RV_SECCOMP_DENY (SECCOMP_RET_ERRNO | EACCES)
#define RV_SECCOMP_FOREIGN SECCOMP_RET_KILL_PROCESS
#define RV_SECCOMP_UNSUPPORTED (SECCOMP_RET_ERRNO | ENOSYS)

/* The low 32 bits of system call argument `n`: what the kernel reads of
 * an `int` or `unsigned int` argument. Both architectures are
 * little-endian. */
#define RV_SECCOMP_ARG(n) (offsetof(struct seccomp_data, args) + 8 * (n))

#define RV_LOAD(offset) BPF_STMT(BPF_LD | BPF_W | BPF_ABS, (offset))
#define RV_IF_EQUAL(value, then, otherwise) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (value), (then), (otherwise))
#define RV_RETURN(verdict) BPF_STMT(BPF_RET | BPF_K, (verdict))

/* Installs the filter on this process. `inet_allowed`: the cage has a
 * connector, so plain TCP sockets may exist; `*listener` is then the
 * descriptor the connector reads the cage's `connect` calls from, and -1
 * otherwise. `unix_allowed`: Landlock confines AF_UNIX sockets on this
 * kernel. 0, or -1 with errno set. */
static int rv_socket_filter_install(int inet_allowed, int unix_allowed, int *listener) {
    const unsigned int inet = inet_allowed ? RV_SECCOMP_ALLOW : RV_SECCOMP_DENY;
    const unsigned int local = unix_allowed ? RV_SECCOMP_ALLOW : RV_SECCOMP_DENY;
    const unsigned int listening = inet_allowed ? RV_SECCOMP_DENY : RV_SECCOMP_ALLOW;
    const unsigned int connecting = inet_allowed ? SECCOMP_RET_USER_NOTIF : RV_SECCOMP_ALLOW;
    int installed;
    /* Each jump is "skip this many instructions": (if equal, if not). */
    struct sock_filter program[] = {
        RV_LOAD(offsetof(struct seccomp_data, arch)),
        RV_IF_EQUAL(RV_AUDIT_ARCH, 1, 0),
        RV_RETURN(RV_SECCOMP_FOREIGN),
        RV_LOAD(offsetof(struct seccomp_data, nr)),
#if defined(__x86_64__)
        /* The x32 ABI shares this architecture value and offsets its numbers. */
        BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000u, 0, 1),
        RV_RETURN(RV_SECCOMP_UNSUPPORTED),
#endif
        RV_IF_EQUAL(SYS_io_uring_setup, 2, 0),
        RV_IF_EQUAL(SYS_io_uring_enter, 1, 0),
        RV_IF_EQUAL(SYS_io_uring_register, 0, 1),
        RV_RETURN(RV_SECCOMP_UNSUPPORTED),

        RV_IF_EQUAL(SYS_listen, 0, 1),
        RV_RETURN(listening),
        RV_IF_EQUAL(SYS_connect, 0, 1),
        RV_RETURN(connecting),

        /* The flags of each sending call, then one test of them. */
        RV_IF_EQUAL(SYS_sendto, 0, 2),
        RV_LOAD(RV_SECCOMP_ARG(3)),
        BPF_STMT(BPF_JMP | BPF_JA, 5),
        RV_IF_EQUAL(SYS_sendmmsg, 0, 2),
        RV_LOAD(RV_SECCOMP_ARG(3)),
        BPF_STMT(BPF_JMP | BPF_JA, 2),
        RV_IF_EQUAL(SYS_sendmsg, 0, 4),
        RV_LOAD(RV_SECCOMP_ARG(2)),
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, MSG_FASTOPEN, 0, 1),
        RV_RETURN(RV_SECCOMP_DENY),
        RV_RETURN(RV_SECCOMP_ALLOW),

        /* socketpair(family, type, protocol, pair) */
        RV_IF_EQUAL(SYS_socketpair, 0, 9),
        RV_LOAD(RV_SECCOMP_ARG(0)),
        RV_IF_EQUAL(AF_UNIX, 1, 0),
        RV_RETURN(RV_SECCOMP_DENY),
        RV_LOAD(RV_SECCOMP_ARG(1)),
        BPF_STMT(BPF_ALU | BPF_AND | BPF_K, ~(unsigned int)(SOCK_NONBLOCK | SOCK_CLOEXEC)),
        RV_IF_EQUAL(SOCK_STREAM, 2, 0),
        RV_IF_EQUAL(SOCK_SEQPACKET, 1, 0),
        RV_RETURN(local),
        RV_RETURN(RV_SECCOMP_ALLOW),

        RV_IF_EQUAL(SYS_socket, 1, 0),
        RV_RETURN(RV_SECCOMP_ALLOW),
        /* socket(family, type, protocol) */
        RV_LOAD(RV_SECCOMP_ARG(0)),
        RV_IF_EQUAL(AF_UNIX, 0, 1),
        RV_RETURN(local),
        RV_IF_EQUAL(AF_INET, 1, 0),
        RV_IF_EQUAL(AF_INET6, 0, 6),
        RV_LOAD(RV_SECCOMP_ARG(1)),
        BPF_STMT(BPF_ALU | BPF_AND | BPF_K, ~(unsigned int)(SOCK_NONBLOCK | SOCK_CLOEXEC)),
        RV_IF_EQUAL(SOCK_STREAM, 0, 3),
        RV_LOAD(RV_SECCOMP_ARG(2)),
        RV_IF_EQUAL(0, 2, 0),
        RV_IF_EQUAL(IPPROTO_TCP, 1, 0),
        RV_RETURN(RV_SECCOMP_DENY),
        RV_RETURN(inet),
    };
    struct sock_fprog filter = {
        .len = (unsigned short)(sizeof(program) / sizeof(program[0])),
        .filter = program,
    };
    *listener = -1;
    if (!inet_allowed) {
        return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &filter, 0, 0);
    }
    /* Once the connector has a call, only a fatal signal interrupts it: a
     * runtime that signals its own threads often (Go) would otherwise
     * restart every `connect` before it is answered. */
    installed = (int)syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER,
        SECCOMP_FILTER_FLAG_NEW_LISTENER | SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV, &filter);
    if (installed < 0) {
        return -1;
    }
    *listener = installed;
    return 0;
}

/* Whether this kernel can install such a filter (seccomp filters, with
 * the three actions it uses). */
static int rv_socket_filter_available(void) {
    unsigned int refuse = SECCOMP_RET_ERRNO;
    unsigned int kill = SECCOMP_RET_KILL_PROCESS;
    unsigned int notify = SECCOMP_RET_USER_NOTIF;
    return syscall(SYS_seccomp, SECCOMP_GET_ACTION_AVAIL, 0u, &refuse) == 0
        && syscall(SYS_seccomp, SECCOMP_GET_ACTION_AVAIL, 0u, &kill) == 0
        && syscall(SYS_seccomp, SECCOMP_GET_ACTION_AVAIL, 0u, &notify) == 0;
}

#else

static int rv_socket_filter_install(int inet_allowed, int unix_allowed, int *listener) {
    (void)inet_allowed;
    (void)unix_allowed;
    (void)listener;
    return -1;
}

static int rv_socket_filter_available(void) {
    return 0;
}

#endif
