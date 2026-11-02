#include <stdio.h>
#include <stdlib.h>
#include <sys/io.h>
#include <unistd.h>

#define SHUTDOWN_PORT 0x604
#define EXIT_PORT     0x501

// Seconds to wait for QEMU to act on an ACPI power-off request
#define POWEROFF_WAIT 30

// Request an ACPI power-off, which ends QEMU with status 0, and wait for it. QEMU may act on the
// request after this process has continued (e.g. under KVM), so this must not return: execution
// reaching the isa-debug-exit write in main() would end QEMU with a non-zero status instead.
static void clean_exit(void) {
    int i;

    ioperm(SHUTDOWN_PORT, 16, 1);
    outw(0x2000, SHUTDOWN_PORT);

    for (i = 0; i < POWEROFF_WAIT; i++) {
        sleep(1);
    }

    fprintf(stderr, "qemu-exit: the VM did not power off within %ds\n", POWEROFF_WAIT);
    exit(255);
}

int main(int argc, char **argv) {
    int status;

    if (argc != 2) {
        clean_exit();
    }

    status = atoi(argv[1]);
    if (!status) {
        clean_exit();
    }

    ioperm(EXIT_PORT, 8, 1);

    // status returned is 1+(2*orig_status)
    outb(status-1, EXIT_PORT);

    // Didn't exit. Perhaps QEMU was not launched with -device isa-debug-exit
    exit(255);
}
