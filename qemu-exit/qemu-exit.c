#include <stdio.h>
#include <stdlib.h>
#include <sys/io.h>
#include <unistd.h>

#define SHUTDOWN_PORT 0x604
#define EXIT_PORT     0x501

static void clean_exit(void) {
    ioperm(SHUTDOWN_PORT, 16, 1);
    outw(0x2000, SHUTDOWN_PORT);
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