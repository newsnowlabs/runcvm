# RunCVM Logging System

## Overview

All RunCVM scripts use a standardized severity-based logging system. **By default, logging is disabled (OFF)** to minimize overhead in production. You can enable logging by setting the `RUNCVM_LOG_LEVEL` environment variable.

Available log levels:
- **DEBUG**: Detailed diagnostic information for troubleshooting
- **INFO**: General informational messages
- **ERROR**: Error messages only
- **OFF**: No logging (default)

## Log Levels Explained

| Level | What You See | Use Case |
|-------|--------------|----------|
| **DEBUG** | Everything (DEBUG + INFO + ERROR) | Troubleshooting, development |
| **INFO** | Normal operations (INFO + ERROR) | Production monitoring when needed |
| **ERROR** | Only errors | Production, minimal output |
| **OFF** | Nothing (default) | Normal operation, no logging overhead |

## Environment Variable Control

Set the `RUNCVM_LOG_LEVEL` environment variable to control logging verbosity:

```bash
# Enable debug logging (show everything)
docker run --runtime=runcvm -e RUNCVM_LOG_LEVEL=DEBUG nginx

# Enable info logging (show info and errors)
docker run --runtime=runcvm -e RUNCVM_LOG_LEVEL=INFO nginx

# Show only errors
docker run --runtime=runcvm -e RUNCVM_LOG_LEVEL=ERROR nginx

# Disable all logging (default - no need to specify)
docker run --runtime=runcvm nginx
```

## Log Format

All log messages follow a consistent format:

```
[TIMESTAMP] [COMPONENT] [SEVERITY] MESSAGE
```

Example:
```
[2025-12-09 07:30:15] [RunCVM-FC] [INFO] Starting Firecracker microVM launcher...
[2025-12-09 07:30:16] [RunCVM-FC] [DEBUG] MOUNT_CONFIG=/run/.firecracker-9p-mounts
[2025-12-09 07:30:17] [RunCVM-FC] [ERROR] Failed to create sparse file
```

## Components

All RunCVM scripts respect the `RUNCVM_LOG_LEVEL` environment variable:

### runcvm-runtime
- **Component Name**: `RunCVM-Runtime`
- **Log Location**: `/tmp/runcvm-$$.log` (where $$ is the process ID)
- **stderr**: ERROR messages are also sent to stderr
- **Legacy Support**: `RUNCVM_RUNTIME_DEBUG=1` now sets `RUNCVM_LOG_LEVEL=DEBUG`

### runcvm-ctr-entrypoint
- **Component Name**: `RunCVM-Entrypoint`
- **Log Location**: stderr
- **Usage**: Container-side entrypoint script

### runcvm-ctr-firecracker
- **Component Name**: `RunCVM-FC`
- **Log Location**: stderr
- **Usage**: Container-side script for launching Firecracker VMs

### runcvm-vm-init-firecracker (Embedded Init Script)
- **Component Name**: `RunCVM-FC-Init`
- **Log Location**: stdout/stderr (visible in container logs)
- **Usage**: VM-side initialization script (runs inside the Firecracker VM)
- **Note**: Reads `RUNCVM_LOG_LEVEL` from `/.runcvm/config` file passed into the VM

## Functions Available

All scripts provide the following logging functions:

```bash
# Debug messages (only shown when RUNCVM_LOG_LEVEL=DEBUG)
log_debug "Detailed diagnostic information"

# Info messages (shown when RUNCVM_LOG_LEVEL=INFO or DEBUG)
log_info "General information"
log "General information"  # Alias for log_info

# Error messages (shown when RUNCVM_LOG_LEVEL=ERROR, INFO, or DEBUG)
log_error "Error occurred"
error "Critical error - exits with code 1"  # Logs error and exits
```

## Usage Examples

### In Shell Scripts

```bash
# Debug information
log_debug "Checking configuration at $CONFIG_PATH"
log_debug "Found $(wc -l < $FILE) entries"

# Normal operations
log_info "Starting service initialization..."
log "Service started successfully"

# Errors
log_error "Failed to connect to server"
error "Critical: Cannot proceed without configuration"  # Exits
```

### Troubleshooting

When debugging issues, enable DEBUG logging:

```bash
# For Docker
docker run --runtime=runcvm -e RUNCVM_LOG_LEVEL=DEBUG your-image

# For Firecracker specifically
docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_LOG_LEVEL=DEBUG \
  your-image

# Check runtime logs
tail -f /tmp/runcvm-*.log
```

### Production Use

By default, logging is disabled (OFF) for minimal overhead:

```bash
# Default - no logging (OFF)
docker run --runtime=runcvm your-image

# Or explicitly enable error-only logging if needed
docker run --runtime=runcvm -e RUNCVM_LOG_LEVEL=ERROR your-image
```

## Migration Notes

### From Old System

The old logging system used:
- `log()` for all messages
- `error()` for errors
- `debug && log` for conditional debug messages
- `RUNCVM_DEBUG=1` to enable debug mode

### New System

- `log()` still works (maps to INFO level)
- `error()` still works (logs ERROR and exits)
- `debug && log` replaced with `log_debug()`
- `RUNCVM_DEBUG=1` replaced with `RUNCVM_LOG_LEVEL=DEBUG`
- `RUNCVM_RUNTIME_DEBUG=1` now sets `RUNCVM_LOG_LEVEL=DEBUG`

## Benefits

1. **Consistent Format**: All logs have timestamps and severity levels
2. **Filterable**: Control verbosity without code changes
3. **Maintainable**: Easy to add new log statements with appropriate severity
4. **Debugging**: Enable DEBUG level to troubleshoot issues
5. **Production-Ready**: Reduce noise in production with ERROR-only logging
6. **Backward Compatible**: Existing `log()` calls still work
