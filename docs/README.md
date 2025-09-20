# Zigzag Event Loop

A high-performance event loop library for Zig, optimized for terminal emulators with seamless zsync async runtime integration.

## Overview

Zigzag provides a cross-platform event loop with multiple backend implementations:

- **io_uring** (Linux 5.1+): Maximum performance with zero-copy operations
- **epoll** (Linux): Reliable fallback with excellent performance
- **kqueue** (macOS/BSD): Native macOS/BSD event handling
- **IOCP** (Windows): Windows async I/O (future implementation)

## Features

### Core Event Loop
- File descriptor watching (read/write/error events)
- Timer management (one-shot and recurring)
- Automatic backend selection
- Cross-platform compatibility

### Terminal Optimizations
- PTY (Pseudo Terminal) management
- Signal handling (SIGWINCH, SIGCHLD, etc.)
- Event coalescing for terminal resize events
- Optimized for terminal emulator workloads

### zsync Integration
- Seamless integration with zsync async runtime
- Cooperative task scheduling
- Shared event sources

## Usage

### Basic Event Loop

```zig
const std = @import("std");
const zigzag = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create event loop with auto-detected backend
    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Add a timer
    const timer = try loop.addTimer(1000, true, timerCallback, null);
    defer loop.cancelTimer(timer);

    // Run the event loop
    try loop.run();
}

fn timerCallback(timer: *const zigzag.Timer) void {
    std.debug.print("Timer fired!\n", .{});
}
```

### File Descriptor Watching

```zig
// Watch a file descriptor for read events
try loop.addFd(fd, .{ .read = true }, fdCallback, user_data);

// Callback function
fn fdCallback(watch: *const zigzag.Watch, event: zigzag.Event) void {
    switch (event.type) {
        .read_ready => {
            // Handle readable data
            var buffer: [1024]u8 = undefined;
            const bytes_read = std.posix.read(event.fd, &buffer) catch 0;
            // Process data...
        },
        .io_error => {
            // Handle I/O error
        },
        else => {},
    }
}
```

### Terminal Features

```zig
const terminal = @import("terminal.zig");

// Signal handling
var signal_handler = try terminal.SignalHandler.init(&loop);
defer signal_handler.close();
try signal_handler.register();

// Event coalescing
var coalescer = try terminal.EventCoalescer.init(allocator);
defer coalescer.deinit();

// Add events (resize events will be coalesced)
try coalescer.addEvent(zigzag.Event{ .type = .window_resize, .fd = -1 });
try coalescer.addEvent(zigzag.Event{ .type = .window_resize, .fd = -1 });

// Process coalesced events
const events = try coalescer.drainEvents();
defer allocator.free(events);
```

## Architecture

### Backend Abstraction

Zigzag uses a backend abstraction layer that automatically selects the best available I/O multiplexing mechanism:

```
EventLoop
├── Backend (enum)
│   ├── io_uring (Linux 5.1+)
│   ├── epoll (Linux)
│   ├── kqueue (macOS/BSD)
│   └── IOCP (Windows)
└── Platform-specific implementation
```

### Event Types

- `read_ready`: File descriptor is readable
- `write_ready`: File descriptor is writable
- `io_error`: I/O error occurred
- `hangup`: Connection hung up
- `timer_expired`: Timer fired
- `window_resize`: Terminal window resized
- `child_exit`: Child process exited
- `user_event`: Custom user event

### Performance Characteristics

- **io_uring**: Zero-copy, batched I/O operations
- **epoll**: O(1) event notification
- **Event coalescing**: Reduces redundant terminal resize events
- **Timer wheel**: Efficient timer management

## Building

```bash
# Build the library
zig build

# Run tests
zig test src/root.zig

# Run terminal tests
zig test src/terminal.zig
```

## Requirements

- Zig 0.16.0-dev or later
- Linux 5.1+ for io_uring backend
- macOS 10.12+ or BSD for kqueue backend

## License

See LICENSE file for details.