/* RunCVM non-terminal stdio transport. SPDX-License-Identifier: Apache-2.0 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CHUNK 4096
#define CAP 65536
#define FAILURE 125
/* Frames: one type byte, big-endian uint32 length, then payload.
 * R: version; 0/1/2: stream data; I/O/E: stream EOF;
 * S: signal; X: application status; A: drained-output acknowledgement. */
static volatile sig_atomic_t pending_signal;
static char *status_path;
static int finish(int code) {
    /* The outer patched init normally decodes QEMU's isa-debug-exit status.
     * Bridge results are already application codes: save them so the existing
     * runcvm-ctr-exit path does not decode them a second time. */
    if (status_path) {
        FILE *f = fopen(status_path, "w");
        if (!f) {
            perror("runcvm-stdio: save status");
            return FAILURE;
        }
        bool failed = fprintf(f, "%d\n", code) < 0;
        if (fclose(f)) failed = true;
        if (failed) return FAILURE;
    }
    return code;
}
static void on_signal(int sig) { pending_signal = sig; }
static long long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void die(const char *what) {
    fprintf(stderr, "runcvm-stdio: %s: %s\n", what, strerror(errno));
    exit(finish(FAILURE));
}
static void nonblock(int fd) {
    int f = fcntl(fd, F_GETFL);
    if (f < 0 || fcntl(fd, F_SETFL, f | O_NONBLOCK) < 0) die("nonblock");
}
static void closefd(int *fd) { if (*fd >= 0) close(*fd); *fd = -1; }
static bool retry(void) { return errno == EINTR || errno == EAGAIN; }
static int transport(bool host, const char *path) {
    long long deadline = now_ms() + 30000;
    do {
        if (host) {
            int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
            struct sockaddr_un a = {.sun_family = AF_UNIX};
            if (strlen(path) >= sizeof a.sun_path) { errno = ENAMETOOLONG; die("socket path"); }
            strcpy(a.sun_path, path);
            if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) return fd;
            int e = errno;
            close(fd);
            if (e != ENOENT && e != ECONNREFUSED) { errno = e; die("connect"); }
        } else {
            int fd = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
            if (fd >= 0) return fd;
            if (errno != ENOENT && errno != ENXIO && errno != EAGAIN) die("open transport");
        }
        if (pending_signal) { errno = EINTR; die("transport startup interrupted"); }
        poll(NULL, 0, 20);
    } while (now_ms() < deadline);
    errno = ETIMEDOUT;
    die("transport startup");
    return -1;
}

/* Initramfs need not run udev. Find the named port in sysfs and create its
 * device node only in RunCVM's private tmpfs, never in the image's /dev. */
static const char *guest_port(void) {
    static const char *node = "/.runcvm/stdio-port";
    glob_t ports;
    if (glob("/sys/class/virtio-ports/*", 0, NULL, &ports)) die("find virtio port");
    for (size_t i = 0; i < ports.gl_pathc; ++i) {
        char path[512], name[128];
        unsigned maj, min;
        snprintf(path, sizeof path, "%s/name", ports.gl_pathv[i]);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        bool match = fgets(name, sizeof name, f) && !strcmp(name, "org.runcvm.stdio\n");
        fclose(f);
        if (!match) continue;
        snprintf(path, sizeof path, "%s/dev", ports.gl_pathv[i]);
        f = fopen(path, "r");
        if (!f) die("port device number");
        int n = fscanf(f, "%u:%u", &maj, &min);
        fclose(f);
        if (n != 2) { errno = EINVAL; die("port device number"); }
        if (mknod(node, S_IFCHR | 0600, makedev(maj, min)) < 0) die("port device node");
        globfree(&ports);
        return node;
    }
    globfree(&ports);
    errno = ENODEV;
    die("named virtio port");
    return NULL;
}

struct queue { unsigned char data[CAP]; size_t start, end; };
static void frame(struct queue *q, unsigned char type, const void *data, uint32_t len) {
    if (q->end + 5 + len > CAP) abort();
    uint32_t net = htonl(len);
    q->data[q->end++] = type;
    memcpy(q->data + q->end, &net, 4); q->end += 4;
    if (len) memcpy(q->data + q->end, data, len);
    q->end += len;
}
static int status_code(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
static void reset_signals(void) {
    int sigs[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGCHLD};
    for (size_t i = 0; i < sizeof sigs / sizeof *sigs; ++i) signal(sigs[i], SIG_DFL);
    sigset_t empty; sigemptyset(&empty); sigprocmask(SIG_SETMASK, &empty, NULL);
}

static int relay(bool host, int wire, pid_t child, int source[3], int sink[3]) {
    struct queue tx = {0};
    unsigned char rx[CHUNK + 5];
    size_t have = 0, need = 5, delivered = 0;
    bool ready = false, exited = false, sent_exit = false, acknowledged = false;
    bool eof[3] = {false, false, false};
    int code = FAILURE;
    long long start = now_ms(), drain_deadline = 0;
    nonblock(wire);
    for (int i = 0; i < 3; ++i) {
        if (source[i] >= 0) nonblock(source[i]);
        if (sink[i] >= 0) nonblock(sink[i]);
    }
    frame(&tx, 'R', "RCS1", 4);
    for (;;) {
        if (child > 0 && !exited) {
            int st;
            pid_t p = waitpid(child, &st, WNOHANG);
            if (p == child) {
                exited = true;
                if (host) {
                    if (sent_exit && acknowledged) return code;
                    goto failed;
                }
                code = status_code(st);
                drain_deadline = now_ms() + 5000;
                closefd(&sink[0]);
            } else if (p < 0 && errno != EINTR) goto failed;
        }
        if (!ready && now_ms() - start > 30000) goto failed;
        if (drain_deadline && now_ms() > drain_deadline) goto failed;
        if (tx.start) {
            memmove(tx.data, tx.data + tx.start, tx.end - tx.start);
            tx.end -= tx.start; tx.start = 0;
        }
        if (pending_signal && tx.end + 6 <= CAP) {
            unsigned char sig = pending_signal; pending_signal = 0;
            if (host) frame(&tx, 'S', &sig, 1);
            else if (child > 0 && !exited) kill(-child, sig);
        }
        if (!host && exited && source[1] < 0 && source[2] < 0 && !sent_exit && tx.end + 6 <= CAP) {
            unsigned char c = code;
            frame(&tx, 'X', &c, 1); sent_exit = true;
        }
        if (host && child < 0 && acknowledged && tx.end == 0) return code;

        /* A complete input frame may be partially delivered to a local pipe.
         * Continue transmitting concurrently to avoid bidirectional deadlock. */
        bool complete = have == need && need > 5;
        if (have == 5 && need == 5) {
            uint32_t len; memcpy(&len, rx + 1, 4); len = ntohl(len);
            if (len > CHUNK) goto failed;
            need = 5 + len;
            complete = have == need;
        }
        int output = -1;
        if (complete) {
            unsigned char t = rx[0]; size_t len = need - 5;
            if (!ready) {
                if (t != 'R' || len != 4 || memcmp(rx + 5, "RCS1", 4)) goto failed;
                ready = true;
            } else if (t >= '0' && t <= '2') {
                int ch = t - '0';
                if (!len || (host ? ch == 0 : ch != 0) || eof[ch]) goto failed;
                output = sink[ch];
                if (output >= 0) {
                    ssize_t n = write(output, rx + 5 + delivered, len - delivered);
                    if (n > 0) delivered += n;
                    else if (n < 0 && !retry()) {
                        if (!host && errno == EPIPE) closefd(&sink[0]);
                        else goto failed;
                    }
                    if (sink[ch] >= 0 && delivered < len) goto polling;
                }
            } else if (t == 'I' || t == 'O' || t == 'E') {
                int ch = t == 'I' ? 0 : t == 'O' ? 1 : 2;
                if (len || (host ? ch == 0 : ch != 0) || eof[ch]) goto failed;
                eof[ch] = true;
                if (!host) closefd(&sink[0]);
            } else if (t == 'S' && !host) {
                if (len != 1 || !rx[5] || rx[5] >= NSIG || rx[5] == SIGCHLD) goto failed;
                if (!exited && kill(-child, rx[5]) < 0 && errno == ESRCH) kill(child, rx[5]);
            } else if (t == 'X' && host) {
                if (len != 1 || sent_exit || !eof[1] || !eof[2]) goto failed;
                code = rx[5]; sent_exit = true;
                drain_deadline = now_ms() + 10000;
                closefd(&source[0]);
                /* Flush already queued stdin before the acknowledgement. */
                if (tx.end + 5 > CAP) goto failed;
                frame(&tx, 'A', NULL, 0); acknowledged = true;
            } else if (t == 'A' && !host && sent_exit && !len) {
                return code;
            } else goto failed;
            have = 0; need = 5; delivered = 0; output = -1;
        }
polling:;
        struct pollfd fds[5] = {{wire, 0, 0}, {-1, 0, 0}, {-1, 0, 0}, {-1, 0, 0}, {output, POLLOUT, 0}};
        if (have < need) fds[0].events |= POLLIN;
        if (tx.end > tx.start) fds[0].events |= POLLOUT;
        for (int ch = 0; ch < 3; ++ch) {
            fds[ch + 1].fd = source[ch];
            if (ready && !sent_exit && tx.end + CHUNK + 10 <= CAP) fds[ch + 1].events = POLLIN;
        }
        int p = poll(fds, 5, 50);
        if (p < 0) { if (errno == EINTR) continue; goto failed; }
        if (fds[0].revents & POLLOUT) {
            ssize_t n = write(wire, tx.data + tx.start, tx.end - tx.start);
            if (n > 0) tx.start += n;
            else if (n < 0 && !retry()) goto failed;
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            if (have < need) {
                ssize_t n = read(wire, rx + have, need - have);
                if (n > 0) have += n;
                else if (!n) {
                    if (host && acknowledged && tx.start == tx.end) {
                        /* Guest has acknowledged delivery by powering off. */
                        if (child < 0) return code;
                        int st;
                        /* QEMU should exit after guest shutdown; never wait forever. */
                        long long deadline = now_ms() + 10000;
                        while (now_ms() < deadline) {
                            pid_t p = waitpid(child, &st, WNOHANG);
                            if (p == child) return code;
                            if (p < 0 && errno != EINTR) goto failed;
                            poll(NULL, 0, 20);
                        }
                    }
                    goto failed;
                } else if (!retry()) goto failed;
            }
        }
        for (int ch = 0; ch < 3; ++ch) {
            if (tx.end + CHUNK + 5 > CAP) break;
            if (!fds[ch + 1].events || !(fds[ch + 1].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            unsigned char buf[CHUNK];
            ssize_t n = read(source[ch], buf, sizeof buf);
            if (n > 0) frame(&tx, '0' + ch, buf, n);
            else if (!n) {
                closefd(&source[ch]);
                frame(&tx, ch == 0 ? 'I' : ch == 1 ? 'O' : 'E', NULL, 0);
            } else if (!retry()) goto failed;
        }
    }
failed:
    fprintf(stderr, "runcvm-stdio: transport, protocol, or drain failure\n");
    if (child > 0 && !exited) {
        if (kill(host ? child : -child, SIGKILL) < 0) kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    return FAILURE;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: runcvm-stdio --host SOCKET -- QEMU... | --guest PORT -- COMMAND...\n"
                        "       --host-fd FD | --guest-fd FD -- COMMAND... (local tests)\n");
        return FAILURE;
    }
    bool host = !strcmp(argv[1], "--host") || !strcmp(argv[1], "--host-fd");
    bool fdmode = !strcmp(argv[1], "--host-fd") || !strcmp(argv[1], "--guest-fd");
    if (!host && strcmp(argv[1], "--guest") && strcmp(argv[1], "--guest-fd")) return FAILURE;
    int cmd = 3;
    if (cmd < argc && !strcmp(argv[cmd], "--")) ++cmd;
    if ((!host || !fdmode) && cmd == argc) return FAILURE;
    if (host && !fdmode) {
        char *dir = strdup(argv[2]);
        if (!dir) die("status path");
        char *slash = strrchr(dir, '/');
        if (slash) slash[1] = '\0'; else dir[0] = '\0';
        if (asprintf(&status_path, "%sexitcode", dir) < 0) die("status path");
        free(dir);
    }
    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal); signal(SIGQUIT, on_signal);
    int source[3] = {-1, -1, -1}, sink[3] = {-1, -1, -1};
    pid_t child = -1;
    int wire = -1;
    if (!host) wire = fdmode ? atoi(argv[2]) : transport(false, !strcmp(argv[2], "auto") ? guest_port() : argv[2]);
    if (cmd < argc) {
        int pipes[3][2];
        if (!host) for (int i = 0; i < 3; ++i) if (pipe2(pipes[i], O_CLOEXEC)) die("pipe");
        pid_t parent = getpid();
        child = fork();
        if (child < 0) die("fork");
        if (!child) {
            reset_signals();
            if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent) _exit(FAILURE);
            if (!host) {
                /* BusyBox's launcher has a controlling console. A pipe-mode
                 * workload must not inherit it through /dev/tty. */
                if (setsid() < 0) die("application session");
                for (int i = 0; i < 3; ++i) if (dup2(pipes[i][i ? 1 : 0], i) < 0) die("dup2");
                for (int i = 0; i < 3; ++i) { close(pipes[i][0]); close(pipes[i][1]); }
                close(wire);
            } else {
                int null = open("/dev/null", O_RDONLY);
                char *logpath = strdup(argv[2]);
                if (!logpath) die("QEMU log path");
                char *slash = strrchr(logpath, '/');
                if (slash) slash[1] = '\0'; else logpath[0] = '\0';
                char *filename;
                if (asprintf(&filename, "%sqemu.log", logpath) < 0) die("QEMU log path");
                int log = open(filename, O_WRONLY | O_CREAT | O_APPEND, 0600);
                free(filename); free(logpath);
                if (null < 0 || log < 0 || dup2(null, 0) < 0 || dup2(log, 1) < 0 || dup2(log, 2) < 0) die("QEMU log");
                close(null); close(log);
            }
            execvp(argv[cmd], argv + cmd);
            int e = errno;
            perror("runcvm-stdio: exec");
            _exit(e == ENOENT ? 127 : 126);
        }
        if (!host) {
            for (int i = 0; i < 3; ++i) {
                close(pipes[i][i ? 1 : 0]);
                if (i) source[i] = pipes[i][0]; else sink[i] = pipes[i][1];
            }
        }
    }
    if (host) {
        wire = fdmode ? atoi(argv[2]) : transport(true, argv[2]);
        source[0] = 0; sink[1] = 1; sink[2] = 2;
    }
    fcntl(wire, F_SETFD, FD_CLOEXEC);
    return finish(relay(host, wire, child, source, sink));
}
