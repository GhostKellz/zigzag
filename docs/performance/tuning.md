# Performance Tuning

Configuration tuning for ZigZag.

## Terminal Emulators

```zig
var loop = try EventLoop.init(allocator, .{
    .max_events = 64,
    .coalescing = .{
        .coalesce_resize = true,
        .max_coalesce_time_ms = 16, // 60fps
    },
});
```

## Network Servers

```zig
var loop = try EventLoop.init(allocator, .{
    .backend = .io_uring, // Linux preferred
    .max_events = 1024,
});
```

## Low-Latency Applications

```zig
var loop = try EventLoop.init(allocator, .{
    .max_events = 32,
    .coalescing = .{
        .coalesce_resize = false,
        .max_coalesce_time_ms = 1,
    },
});
```

## Backend Selection

| Use Case | Recommended Backend |
|----------|---------------------|
| General | Auto-detect |
| Maximum throughput | io_uring |
| Compatibility | epoll |
| Debugging | epoll |

## Memory

- Base overhead: ~1MB
- Per-watch: ~64 bytes
- Per-timer: ~64 bytes

## Idle Behavior

The event loop sleeps 1ms when no events are pending. For lower latency, use `poll()` directly with shorter timeouts.
