/*
 * qemu-exit for ARM64 (AArch64)
 *
 * On ARM64, we use semihosting to exit QEMU with a specific exit code.
 * This requires QEMU to be started with -semihosting or -semihosting-config
 *
 * Semihosting SYS_EXIT (0x18) is used with ADP_Stopped_ApplicationExit (0x20026)
 * For AArch64, the parameter block contains the exit reason and exit code.
 */

#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>

/* ARM Semihosting operations */
#define SYS_EXIT        0x18
#define SYS_EXIT_EXTENDED 0x20

/* ADP_Stopped reason codes */
#define ADP_Stopped_ApplicationExit     0x20026
#define ADP_Stopped_RunTimeErrorUnknown 0x20023

/* Parameter block for SYS_EXIT on AArch64 */
struct exit_params {
    unsigned long reason;
    unsigned long exit_code;
};

/*
 * Perform ARM64 semihosting call
 * For AArch64, use HLT #0xF000
 */
static inline long semihosting_call(unsigned long operation, void *parameter)
{
    register unsigned long op asm("x0") = operation;
    register void *param asm("x1") = parameter;

    asm volatile (
        "hlt #0xf000"
        : "+r" (op)
        : "r" (param)
        : "memory"
    );

    return op;
}

/*
 * Exit QEMU with the specified exit code using semihosting
 */
static void qemu_exit(int exit_code)
{
    struct exit_params params;

    if (exit_code == 0) {
        params.reason = ADP_Stopped_ApplicationExit;
    } else {
        params.reason = ADP_Stopped_RunTimeErrorUnknown;
    }
    params.exit_code = exit_code;

    semihosting_call(SYS_EXIT, &params);

    /* If semihosting fails, try SYS_EXIT_EXTENDED */
    semihosting_call(SYS_EXIT_EXTENDED, &params);

    /* Should never reach here */
    _exit(exit_code);
}

static void clean_exit(int signum)
{
    (void)signum;
    qemu_exit(0);
}

int main(int argc, char *argv[])
{
    int status = 0;

    if (argc > 1) {
        status = atoi(argv[1]);
    }

    /* Handle common signals */
    signal(SIGINT, clean_exit);
    signal(SIGTERM, clean_exit);

    qemu_exit(status);

    /* Should never reach here */
    return status;
}