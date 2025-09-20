# Zigzag Quick Start

Get up and running with zigzag event loop in minutes.

## Installation

Clone the repository:

```bash
git clone https://github.com/ghostkellz/zigzag.git
cd zigzag
```

## Hello World

Create a simple timer example:

```zig
const std = @import("std");
const zigzag = @import("root.zig");

pub fn main() !void {
    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create event loop
    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Add a timer that fires every second
    const timer = try loop.addTimer(1000, true, timerCallback, null);
    defer loop.cancelTimer(timer);

    std.debug.print("Starting event loop... (Ctrl+C to exit)\n", .{});

    // Run the event loop
    try loop.run();
}

fn timerCallback(timer: *const zigzag.Timer) void {
    std.debug.print("Timer fired at {}\n", .{std.time.timestamp()});
}
```

Save as `hello.zig` and run:

```bash
zig run hello.zig
```

## File Watching Example

Watch a file for changes:

```zig
const std = @import("std");
const zigzag = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Open a file to watch
    const file = try std.fs.cwd().openFile("watch_me.txt", .{ .read = true });
    defer file.close();

    // Watch for read events (file becomes readable when data is available)
    try loop.addFd(file.handle, .{ .read = true }, fileCallback, null);

    std.debug.print("Watching file... (modify watch_me.txt to see events)\n", .{});
    try loop.run();
}

fn fileCallback(watch: *const zigzag.Watch, event: zigzag.Event) void {
    switch (event.type) {
        .read_ready => {
            std.debug.print("File is readable!\n", .{});
        },
        .io_error => {
            std.debug.print("I/O error on file\n", .{});
        },
        else => {
            std.debug.print("Other event: {}\n", .{event.type});
        },
    }
}
```

## Terminal Integration Example

Basic terminal signal handling:

```zig
const std = @import("std");
const zigzag = @import("root.zig");
const terminal = @import("terminal.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Setup signal handling
    var signal_handler = try terminal.SignalHandler.init(&loop);
    defer signal_handler.close();
    try signal_handler.register();

    std.debug.print("Terminal signal handler active. Try resizing your terminal.\n", .{});
    try loop.run();
}
```

## Building Your Application

### As a Library

Add to your `build.zig`:

```zig
// In build.zig
exe.addPackagePath("zigzag", "path/to/zigzag/src/root.zig");
```

Then import in your code:

```zig
const zigzag = @import("zigzag");
```

### Standalone Build

```bash
# Build library
zig build-lib src/root.zig

# Build examples
zig build-exe hello.zig -I. -I./src
```

## Performance Tips

1. **Use io_uring backend** when available (Linux 5.1+)
2. **Enable event coalescing** for terminal resize events
3. **Batch operations** when possible
4. **Reuse timers** instead of creating new ones

## Troubleshooting

### Backend Selection Issues

Check which backend is selected:

```zig
var loop = try zigzag.EventLoop.init(allocator, .{});
std.debug.print("Using backend: {}\n", .{loop.backend});
```

### Common Errors

- `BackendNotInitialized`: Check system requirements
- `PermissionDenied`: Run with appropriate permissions
- `SystemOutdated`: Upgrade kernel for io_uring

## Next Steps

- Read the [full API documentation](API.md)
- Explore [terminal-specific features](API.md#terminal-module)
- Check out the test files for more examples