/*
 * Darwin session-leader claim for a contained PTY.
 *
 * POSIX_SPAWN_SETSID makes this process the session leader and clears any
 * controlling terminal before the new image runs. A slave opened by a
 * posix_spawn file action is not the controlling terminal, and leaving that
 * descriptor open makes TIOCSCTTY fail. This image runs outside Seatbelt.
 * argv[1] is the slave path (/dev/ttysN). argv[2] is the absolute payload
 * (sandbox-exec, or a test program). This process closes the spawn-installed
 * stdio, reopens the slave, calls TIOCSCTTY, makes its own pid the foreground
 * group, then execs the payload. The pid does not change, so the recorded
 * process group stays the session leader.
 *
 * The temporary fd is closed before exec. Stdin, stdout, and stderr are
 * the slave. Nothing is written. A failed claim exits 127 and does not
 * exec. The signal mask is restored so the payload does not inherit a
 * blocked SIGTTIN or SIGTTOU.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int is_slave_path(const char *path) {
    return path != NULL
        && strncmp(path, "/dev/", 5) == 0
        && strstr(path, "..") == NULL;
}

static int claim_controlling_terminal(const char *slave) {
    pid_t self = getpid();
    int opened;
    pid_t foreground = -1;
    if (self <= 1 || is_slave_path(slave) == 0) {
        return -1;
    }
    /*
     * Drop the descriptor posix_spawn already opened. TIOCSCTTY on a second
     * fd fails while that first slave fd is still open, and the parent then
     * cannot observe this pid as the foreground group.
     */
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    opened = open(slave, O_RDWR);
    if (opened < 0) {
        return -1;
    }
    /* EPERM means this open already made the slave our controlling terminal.
     * A terminal owned by another session fails the foreground check below. */
    if (ioctl(opened, TIOCSCTTY, 0) != 0 && errno != EPERM) {
        close(opened);
        return -1;
    }
    if (dup2(opened, STDIN_FILENO) < 0 || dup2(opened, STDOUT_FILENO) < 0
        || dup2(opened, STDERR_FILENO) < 0) {
        close(opened);
        return -1;
    }
    if (opened > STDERR_FILENO && close(opened) != 0) {
        return -1;
    }
    if (tcsetpgrp(STDIN_FILENO, self) != 0 && ioctl(STDIN_FILENO, TIOCSPGRP, &self) != 0) {
        return -1;
    }
    if (ioctl(STDIN_FILENO, TIOCGPGRP, &foreground) != 0 || foreground != self) {
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    sigset_t blocked;
    sigset_t previous;
    int claimed;
    if (argc < 3 || argv[1] == NULL || argv[2] == NULL || argv[2][0] != '/') {
        return 127;
    }
    if (sigemptyset(&blocked) != 0 || sigaddset(&blocked, SIGTTIN) != 0
        || sigaddset(&blocked, SIGTTOU) != 0) {
        return 127;
    }
    if (sigprocmask(SIG_BLOCK, &blocked, &previous) != 0) {
        return 127;
    }
    claimed = claim_controlling_terminal(argv[1]);
    if (sigprocmask(SIG_SETMASK, &previous, NULL) != 0) {
        return 127;
    }
    if (claimed != 0) {
        return 127;
    }
    execv(argv[2], argv + 2);
    return 127;
}
