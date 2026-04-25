# Linux

Linux platform support for ZigZag.

## Backends

### io_uring (Linux 5.1+)

Primary backend for modern Linux systems.

**Features:**
- Zero-copy I/O operations
- Batched syscalls
- Recurring timers use multishot timeouts on Linux 6.1+ and fall back to epoll-backed recurring timers on older kernels

**Requirements:**
- Linux kernel 5.1 or later
- io_uring support enabled

**Check availability:**
```bash
cat /proc/version
# Linux version 5.x or higher
```

### epoll (Linux 2.6+)

Fallback backend for older Linux systems.

**Features:**
- Reliable event notification
- Wide kernel compatibility
- Uses timerfd for timers

**Requirements:**
- Linux kernel 2.6.27 or later

## Backend Selection

io_uring is preferred when available, with automatic fallback to epoll:

```zig
// Auto-detect (io_uring if available, else epoll)
var loop = try EventLoop.init(allocator, .{});

// Force epoll
var loop = try EventLoop.init(allocator, .{ .backend = .epoll });

// Force io_uring (fails if unavailable)
var loop = try EventLoop.init(allocator, .{ .backend = .io_uring });
```

## Build Options

```bash
# Disable io_uring
zig build -Dio_uring=false

# Disable epoll
zig build -Depoll=false
```

## Terminal Features

Full terminal support on Linux:
- PTY management via /dev/ptmx
- Signal handling (SIGWINCH, SIGCHLD, etc.)
- Event coalescing for resize events
