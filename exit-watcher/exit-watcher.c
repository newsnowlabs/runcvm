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
// It subscribes to the connector, then forks: the parent creates the ready file and exits once the
// child holds the subscribed socket. So a workload started after the parent exits cannot exit
// unseen; busybox init starts the workload only after its 'sysinit' actions, of which this is one.
// The child waits for the exit of the process whose ID the pid file holds (written by
// runcvm-vm-start just before it execs the workload, whose ID it keeps). It then creates the exit
// code file, unless it exists already (as where the workload saved its own exit code), writing the
// exit status as a container's would be (the exit code, or 128 plus the number of the signal that
// ended it); creates the done file, which runcvm-vm-start waits for, where the ready file exists,
// before powering the VM off; and exits.
//
// When the VM stops, runcvm-vm-shutdown sends SIGTERM to every process at once, this one included,
// then waits for them all to exit. So that it still records the workload's exit, which the same
// SIGTERM usually causes, SIGTERM leaves it running for up to TERM_GRACE seconds more, after which
// SIGALRM ends it, so that a VM stopped before its workload starts is not held up.

#include <errno.h>
#include <fcntl.h>
#include <linux/cn_proc.h>
#include <linux/connector.h>
#include <linux/netlink.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define PROGRAM "runcvm-exit-watcher"

// Seconds this process outlives SIGTERM, to record the workload's exit
#define TERM_GRACE 5

// The size of a netlink message carrying a connector message with a payload of n bytes
#define NL_CN_SIZE(n) (NLMSG_LENGTH(sizeof(struct cn_msg) + (n)))

static void on_term(int signum) {
    (void)signum;
    alarm(TERM_GRACE);
}

static void die(const char *what) {
    fprintf(stderr, PROGRAM ": %s: %s\n", what, strerror(errno));
    exit(1);
}

// Returns the process ID in the pid file, or -1 where there is none yet
static pid_t read_pid(const char *path) {
    char buf[32];
    ssize_t n;
    int fd = open(path, O_RDONLY | O_CLOEXEC);

    if (fd < 0)
        return -1;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0)
        return -1;
    buf[n] = '\0';
    return (pid_t)atoi(buf);
}

// Creates the file holding text, unless it exists
static void create_file(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);

    if (fd < 0)
        return;
    if (write(fd, text, strlen(text)) < 0)
        fprintf(stderr, PROGRAM ": writing %s: %s\n", path, strerror(errno));
    close(fd);
}

int main(int argc, char **argv) {
    const char *pid_file, *exit_code_file, *ready_file, *done_file;
    struct sockaddr_nl addr = { .nl_family = AF_NETLINK, .nl_groups = CN_IDX_PROC };
    // Netlink messages are 4-byte aligned; the buffer is aligned for the headers read in place.
    union { struct nlmsghdr nl; char buf[4096]; } msg;
    struct cn_msg cn;
    enum proc_cn_mcast_op op = PROC_CN_MCAST_LISTEN;
    int sock, ready[2];
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
    cn.len = sizeof(op);
    memcpy(NLMSG_DATA(&msg.nl), &cn, sizeof(cn));
    memcpy((char *)NLMSG_DATA(&msg.nl) + sizeof(cn), &op, sizeof(op));
    if (send(sock, &msg, msg.nl.nlmsg_len, 0) < 0)
        die("subscribing to process events");

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
        create_file(ready_file, "");
        return 0;
    }
    close(ready[0]);
    setsid();
    {
        // Without SA_RESTART, so that recv returns (EINTR) and the loop reads on
        struct sigaction sa;

        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_term;
        sigaction(SIGTERM, &sa, NULL);
    }
    if (write(ready[1], &c, 1) != 1)
        die("signalling readiness");
    close(ready[1]);

    for (;;) {
        ssize_t n = recv(sock, &msg, sizeof(msg), 0);
        struct proc_event ev;
        int status, code;
        pid_t pid;
        char text[16];

        if (n < 0) {
            // ENOBUFS: events were lost while this process was not scheduled. Read on: the
            // workload's exit, if among them, is lost, and its exit status not recorded.
            if (errno == EINTR || errno == ENOBUFS)
                continue;
            die("recv");
        }
        if ((size_t)n < NL_CN_SIZE(sizeof(ev)))
            continue;
        memcpy(&ev, (char *)NLMSG_DATA(&msg.nl) + sizeof(struct cn_msg), sizeof(ev));
        if (ev.what != PROC_EVENT_EXIT)
            continue;
        // A whole process's exit, not one of its other threads'
        if (ev.event_data.exit.process_pid != ev.event_data.exit.process_tgid)
            continue;
        pid = read_pid(pid_file);
        if (pid <= 0 || ev.event_data.exit.process_pid != pid)
            continue;

        // exit_code is a wait status
        status = (int)ev.event_data.exit.exit_code;
        code = (status & 0x7f) ? 128 + (status & 0x7f) : (status >> 8) & 0xff;
        snprintf(text, sizeof(text), "%d\n", code);
        create_file(exit_code_file, text);
        create_file(done_file, "");
        return 0;
    }
}
