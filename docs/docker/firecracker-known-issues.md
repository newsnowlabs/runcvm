# Firecracker Hypervisor - Known Issues and Workarounds

This document describes known issues and limitations when using RunCVM with the Firecracker hypervisor.

## Interactive Command Signal Handling (Ctrl-C)

### Issue

When running interactive commands like `watch` inside a Firecracker VM, pressing Ctrl-C may not stop the command as expected.

**Affected commands:**
- `watch` (when using Alpine's busybox version)
- Other curses/ncurses-based programs that put the terminal in raw mode

**Symptoms:**
- Pressing Ctrl-C shows `^C` but the command continues running
- Ctrl-Z (suspend) works correctly
- After suspending with Ctrl-Z, you can kill the job with `kill %1`

### Root Cause

Alpine Linux uses busybox's implementation of `watch`, which puts the terminal in raw mode (disabling signal generation) but doesn't properly handle the Ctrl-C character (ASCII 0x03) to exit.

When `watch` runs:
1. It puts the terminal in raw mode (disables ISIG)
2. In raw mode, Ctrl-C becomes just the 0x03 character, not a SIGINT signal
3. Busybox `watch` doesn't check for this character and exit

### Workarounds

#### Option 1: Install procps package (Recommended)

The `procps` package provides a proper `watch` implementation that correctly handles Ctrl-C:

```bash
# Inside the container
apk add procps

# Now watch will respond to Ctrl-C
watch date
# Press Ctrl-C - works!
```

#### Option 2: Use kill command

After suspending with Ctrl-Z, kill the background job:

```bash
# While watch is running...
# Press Ctrl-Z to suspend
kill %1
```

#### Option 3: Use a shell loop instead

Replace `watch` with a shell loop that properly handles signals:

```bash
# Instead of: watch date
# Use:
while true; do clear; date; sleep 2; done
# Press Ctrl-C - works because shell handles the loop
```

#### Option 4: Use fg and Ctrl-Z combo

```bash
# While watch is running...
# Press Ctrl-Z to suspend
fg    # Bring back to foreground
# Press Ctrl-Z again, then:
kill %1
```

## Stopping the Container

To stop a Firecracker container, use:

```bash
docker stop <container_name>
```

Note: Ctrl-C at an idle shell prompt will show `^C` but won't exit the container. Use `exit` command or `docker stop` from another terminal.

## Related Links

- [Firecracker Documentation](https://github.com/firecracker-microvm/firecracker/blob/main/docs/)
- [RunCVM GitHub Issues](https://github.com/newsnowlabs/runcvm/issues)
