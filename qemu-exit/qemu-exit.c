#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#ifdef __x86_64__

#include <sys/io.h>

#define SHUTDOWN_PORT 0x604
#define EXIT_PORT     0x501

static void clean_exit(void) {
    ioperm(SHUTDOWN_PORT, 16, 1);
    outw(0x2000, SHUTDOWN_PORT);
}

static void exit_with_code(int status) {
    ioperm(EXIT_PORT, 8, 1);
    // status returned is 1+(2*orig_status)
    outb(status-1, EXIT_PORT);
    // Didn't exit. Perhaps QEMU was not launched with -device isa-debug-exit
    exit(255);
}

#else

#include <sys/reboot.h>

static void clean_exit(void) {
    reboot(RB_POWER_OFF);
    exit(255);
}

static void exit_with_code(int status) {
    // Write exit code to file for runcvm-ctr-exit to pick up.
    // The isa-debug-exit device is x86-only; on other architectures we trigger
    // an ACPI poweroff and rely on /.runcvm/exitcode being read by runcvm-ctr-exit.
    FILE *f = fopen("/.runcvm/exitcode", "w");
    if (f) {
        fprintf(f, "%d\n", status);
        fclose(f);
    }
    reboot(RB_POWER_OFF);
    exit(255);
}

#endif

int main(int argc, char **argv) {
    int status;

    if (argc != 2) {
        clean_exit();
        return 255;
    }

    status = atoi(argv[1]);
    if (!status) {
        clean_exit();
        return 255;
    }

    exit_with_code(status);
    return 255;
}
