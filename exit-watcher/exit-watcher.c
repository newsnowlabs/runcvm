// runcvm-exit-watcher: records the exit status of a Container/VM's workload, run with --init.
//
// With --init, busybox init is the VM's PID 1 and the workload is its child, so the workload's exit
// status reaches busybox init, which discards it. This program, started before the workload,
// receives every process's exit from the kernel's process events connector (CONFIG_PROC_EVENTS),
// and when the workload exits, saves its exit status for runcvm-ctr-exit, leaving the process tree
// as it is: busybox init's child is the workload itself, as a container's would be.
//
// Usage: runcvm-exit-watcher <pid file> <exit code file> <ready file> <done file>
//
// It subscribes to the connector, waits for the kernel to acknowledge the subscription, then forks:
// the parent creates the ready file and exits once the child holds the subscribed socket. So a
// workload started after the parent exits cannot exit unseen; busybox init starts the workload
// only after its 'sysinit' actions, of which this is one. Where the subscription fails, no ready
// file is created, and runcvm-vm-start does not wait for this program.
//
// The child waits for the exit of the process whose ID the pid file holds (written by
// runcvm-vm-start just before it execs the workload, whose ID it keeps). A process's threads each
// report their exit, and the main thread may exit first, so the child records the exit of the
// process's last thread to exit, whose status is the process's where one thread ended the whole
// process (exit_group(), or a signal). It then creates the exit code file, unless it exists already
// (as where the workload saved its own exit code), writing the exit status as a container's would
// be (the exit code, or 128 plus the number of the signal that ended it), complete or not at all;
// creates the done file, which runcvm-vm-start waits for, where the ready file exists, before
// powering the VM off; and exits.
//
// When the VM stops, runcvm-vm-shutdown sends SIGTERM to every process at once, this one included,
// then waits for them all to exit. So that it still records the workload's exit, which the same
// SIGTERM usually causes however long the workload takes to exit, SIGTERM ends this program only
// once no workload is present (none has started, or the one that did has been reaped) and no
// events are left to read.

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/cn_proc.h>
#include <linux/connector.h>
#include <linux/netlink.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define PROGRAM "runcvm-exit-watcher"

// Seconds to wait for the kernel to acknowledge the subscription
#define SUBSCRIBE_TIMEOUT 5

// The socket's receive buffer, in bytes: room for the events of many processes exiting at once
#define RCVBUF (4 << 20)

// The size of a netlink message carrying a connector message with a payload of n bytes
#define NL_CN_SIZE(n) (NLMSG_LENGTH(sizeof(struct cn_msg) + (n)))

static volatile sig_atomic_t terminating;

static void on_term(int signum) {
    (void)signum;
    terminating = 1;
}

static void warn(const char *what) {
    fprintf(stderr, PROGRAM ": %s: %s\n", what, strerror(errno));
}

static void die(const char *what) {
    warn(what);
    exit(1);
}

// Returns the process ID in the pid file, or -1 where there is no valid one yet
static pid_t read_pid(const char *path) {
    char buf[32], *end;
    ssize_t n;
    long pid;
    int fd = open(path, O_RDONLY | O_CLOEXEC);

    if (fd < 0)
        return -1;
    do
        n = read(fd, buf, sizeof(buf) - 1);
    while (n < 0 && errno == EINTR);
    close(fd);
    if (n <= 0)
        return -1;
    buf[n] = '\0';
    errno = 0;
    pid = strtol(buf, &end, 10);
    if (errno || end == buf || (*end && *end != '\n') || pid <= 0 || pid > INT_MAX)
        return -1;
    return (pid_t)pid;
}

// Whether the workload, as the pid file names it, has started and not yet been reaped
static int workload_present(const char *pid_file) {
    pid_t pid = read_pid(pid_file);

    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

// Whether any thread of process pid, other than tid, has yet to exit
static int other_threads_running(pid_t pid, pid_t tid) {
    char path[64], stat[512];
    struct dirent *e;
    DIR *dir;
    int running = 0;

    snprintf(path, sizeof(path), "/proc/%d/task", (int)pid);
    dir = opendir(path);
    if (!dir)
        return 0;
    while (!running && (e = readdir(dir))) {
        char *state;
        ssize_t n;
        int fd, task = atoi(e->d_name);

        if (task <= 0 || task == tid)
            continue;
        snprintf(path, sizeof(path), "/proc/%d/task/%d/stat", (int)pid, task);
        fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        n = read(fd, stat, sizeof(stat) - 1);
        close(fd);
        if (n <= 0)
            continue;
        stat[n] = '\0';
        // The state follows the last ')', which ends the thread's name
        state = strrchr(stat, ')');
        if (state && state[1] == ' ' && state[2] != 'Z' && state[2] != 'X' && state[2] != 'x')
            running = 1;
    }
    closedir(dir);
    return running;
}

// Writes all of text to fd
static int write_all(int fd, const char *text) {
    size_t left = strlen(text);

    while (left) {
        ssize_t n = write(fd, text, left);

        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return -1;
        text += n;
        left -= (size_t)n;
    }
    return 0;
}

// Creates the file at path holding text, complete, unless the file exists: writes a temporary
// file, then links it into place, which fails where the file exists. Returns 0 where the file
// exists afterwards, however it got there.
static int publish(const char *path, const char *text) {
    char tmp[PATH_MAX];
    int fd, err = 0;

    if (snprintf(tmp, sizeof(tmp), "%s.%d", path, (int)getpid()) >= (int)sizeof(tmp)) {
        errno = ENAMETOOLONG;
        warn(path);
        return -1;
    }
    fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) {
        warn(tmp);
        return -1;
    }
    if (write_all(fd, text) < 0)
        err = errno ? errno : EIO;
    if (close(fd) < 0 && !err)
        err = errno;
    if (!err && link(tmp, path) < 0 && errno != EEXIST)
        err = errno;
    unlink(tmp);
    if (err) {
        errno = err;
        warn(path);
        return -1;
    }
    return 0;
}

// Reads the process event in the first netlink message of the datagram in buf, n bytes long (as
// recv reports it with MSG_TRUNC, so that n exceeds size where the datagram was truncated to fit
// buf, of size bytes), into ev. Returns 0 where it holds one, with every length consistent: the
// process connector sends each event in a datagram of its own, and anything else is ignored.
static int read_event(const void *buf, ssize_t n, size_t size, struct proc_event *ev) {
    const struct nlmsghdr *nl = buf;
    struct cn_msg cn;

    if (n < (ssize_t)NL_CN_SIZE(sizeof(*ev)) || (size_t)n > size || nl->nlmsg_len > (size_t)n ||
        nl->nlmsg_len < NL_CN_SIZE(sizeof(*ev)))
        return -1;
    memcpy(&cn, NLMSG_DATA(nl), sizeof(cn));
    if (cn.id.idx != CN_IDX_PROC || cn.id.val != CN_VAL_PROC || cn.len < sizeof(*ev) ||
        NL_CN_SIZE(cn.len) > nl->nlmsg_len)
        return -1;
    memcpy(ev, (const char *)NLMSG_DATA(nl) + sizeof(cn), sizeof(*ev));
    return 0;
}

int main(int argc, char **argv) {
    const char *pid_file, *exit_code_file, *ready_file, *done_file;
    struct sockaddr_nl addr = { .nl_family = AF_NETLINK, .nl_groups = CN_IDX_PROC };
    // Netlink messages are 4-byte aligned; the buffer is aligned for the headers read in place.
    union { struct nlmsghdr nl; char buf[4096]; } msg;
    struct timeval tick = { .tv_sec = 1 };
    struct proc_event ev;
    struct sigaction sa;
    struct cn_msg cn;
    enum proc_cn_mcast_op op = PROC_CN_MCAST_LISTEN;
    int sock, ready[2], rcvbuf = RCVBUF;
    sigset_t set;
    time_t deadline;
    char c = 0;
    pid_t child;

    if (argc != 5) {
        fprintf(stderr, "Usage: " PROGRAM " <pid file> <exit code file> <ready file> <done file>\n");
        return 2;
    }
    pid_file = argv[1];
    exit_code_file = argv[2];
    ready_file = argv[3];
    done_file = argv[4];

    sock = socket(PF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_CONNECTOR);
    if (sock < 0)
        die("socket");
    // The larger buffer, which only root may have, makes events lost to a full buffer less likely
    if (setsockopt(sock, SOL_SOCKET, SO_RCVBUFFORCE, &rcvbuf, sizeof(rcvbuf)) < 0 &&
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) < 0)
        warn("setting the receive buffer size");
    // recv returns at least once a second, so that the loops below can check their conditions
    if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tick, sizeof(tick)) < 0)
        die("setting the receive timeout");
    addr.nl_pid = getpid();
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        die("bind");

    memset(&msg, 0, sizeof(msg));
    msg.nl.nlmsg_len = NL_CN_SIZE(sizeof(op));
    msg.nl.nlmsg_type = NLMSG_DONE;
    msg.nl.nlmsg_pid = getpid();
    memset(&cn, 0, sizeof(cn));
    cn.id.idx = CN_IDX_PROC;
    cn.id.val = CN_VAL_PROC;
    cn.ack = (unsigned int)getpid();
    cn.len = sizeof(op);
    memcpy(NLMSG_DATA(&msg.nl), &cn, sizeof(cn));
    memcpy((char *)NLMSG_DATA(&msg.nl) + sizeof(cn), &op, sizeof(op));
    if (send(sock, &msg, msg.nl.nlmsg_len, 0) < 0)
        die("subscribing to process events");

    // The kernel acknowledges the subscription with a PROC_EVENT_NONE event carrying its error, if
    // any, whose acknowledgement number is one more than the subscription's. Other events received
    // meanwhile are of processes other than the workload, which has yet to start.
    deadline = time(NULL) + SUBSCRIBE_TIMEOUT;
    for (;;) {
        ssize_t n;

        if (time(NULL) > deadline) {
            fprintf(stderr, PROGRAM ": the kernel did not acknowledge the subscription\n");
            return 1;
        }
        n = recv(sock, &msg, sizeof(msg), MSG_TRUNC);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)
                continue;
            die("recv");
        }
        if (read_event(&msg, n, sizeof(msg), &ev) < 0 || ev.what != PROC_EVENT_NONE)
            continue;
        memcpy(&cn, NLMSG_DATA(&msg.nl), sizeof(cn));
        if (cn.ack != (unsigned int)getpid() + 1)
            continue;
        if (ev.event_data.ack.err) {
            errno = (int)ev.event_data.ack.err;
            die("subscribing to process events");
        }
        break;
    }

    // The parent returns once the child holds the subscribed socket.
    if (pipe(ready) < 0)
        die("pipe");
    child = fork();
    if (child < 0)
        die("fork");
    if (child > 0) {
        close(ready[1]);
        if (read(ready[0], &c, 1) != 1)
            return 1;
        return publish(ready_file, "") < 0;
    }
    close(ready[0]);
    setsid();

    // SIGTERM only sets a flag, which the loop checks whenever a second passes with no events
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_term;
    if (sigemptyset(&set) < 0 || sigaddset(&set, SIGTERM) < 0 || sigaction(SIGTERM, &sa, NULL) < 0 ||
        sigprocmask(SIG_UNBLOCK, &set, NULL) < 0)
        die("handling SIGTERM");
    if (write(ready[1], &c, 1) != 1)
        die("signalling readiness");
    close(ready[1]);

    for (;;) {
        ssize_t n;
        int status, code;
        pid_t pid;
        char text[16];

        n = recv(sock, &msg, sizeof(msg), MSG_TRUNC);
        if (n < 0) {
            // A second with no events: after SIGTERM, end once no workload is present. The kernel
            // queues a process's exit event before the process can be reaped, so where the
            // workload is gone, its exit would already have been read.
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (terminating && !workload_present(pid_file))
                    return 0;
                continue;
            }
            // ENOBUFS: events were lost while this process was not scheduled. Read on: the
            // workload's exit, if among them, is lost, and its exit status not recorded.
            if (errno == EINTR || errno == ENOBUFS)
                continue;
            die("recv");
        }
        if (read_event(&msg, n, sizeof(msg), &ev) < 0 || ev.what != PROC_EVENT_EXIT)
            continue;
        pid = read_pid(pid_file);
        if (pid <= 0 || ev.event_data.exit.process_tgid != pid)
            continue;
        // The process has exited once its last thread has; that thread's status is the process's.
        if (other_threads_running(pid, ev.event_data.exit.process_pid))
            continue;

        // exit_code is a wait status
        status = (int)ev.event_data.exit.exit_code;
        code = (status & 0x7f) ? 128 + (status & 0x7f) : (status >> 8) & 0xff;
        snprintf(text, sizeof(text), "%d\n", code);
        if (publish(exit_code_file, text) < 0)
            return 1;
        return publish(done_file, "") < 0;
    }
}
