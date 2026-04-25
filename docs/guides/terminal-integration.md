# Terminal Integration

Using ZigZag for terminal emulators.

## PTY Management

ZigZag includes PTY (pseudo-terminal) support for terminal emulators.

```zig
const zigzag = @import("zigzag");
const terminal = zigzag.terminal;

var pty = try terminal.Pty.create();
defer pty.close();

// Set terminal size
try pty.setSize(24, 80);

// Get current size
const size = try pty.getSize();
```

## Signal Handling

Handle terminal signals like SIGWINCH (window resize) and SIGCHLD (child exit).

```zig
const zigzag = @import("zigzag");
const terminal = zigzag.terminal;

var signal_handler = try terminal.SignalHandler.init(&loop);
defer signal_handler.deinit();

if (try signal_handler.poll()) |event| {
    _ = event;
}
```

## Event Coalescing

Terminal resize events can fire rapidly. Event coalescing batches them:

```zig
var loop = try zigzag.EventLoop.init(allocator, .{
    .coalescing = .{
        .coalesce_resize = true,
        .max_coalesce_time_ms = 16, // 60fps
    },
});
```

## Platform Notes

Terminal features require Unix-like systems (Linux, macOS, BSD).

Windows terminal support requires different APIs and is not yet implemented.
