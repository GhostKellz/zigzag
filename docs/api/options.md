# Options

Configuration options for the ZigZag event loop.

## Options

```zig
pub const Options = struct {
    max_events: u32 = 1024,
    backend: ?Backend = null,
    coalescing: ?CoalescingConfig = null,
};
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_events` | `u32` | 1024 | Maximum events per poll |
| `backend` | `?Backend` | `null` | Backend to use (null = auto-detect) |
| `coalescing` | `?CoalescingConfig` | `null` | Event coalescing config |

## CoalescingConfig

```zig
pub const CoalescingConfig = struct {
    coalesce_resize: bool = true,
    max_coalesce_time_ms: u32 = 16,
    max_batch_size: u32 = 32,
};
```

## Usage

```zig
// Default options (auto-detect backend)
var loop = try EventLoop.init(allocator, .{});

// Explicit backend
var loop = try EventLoop.init(allocator, .{
    .backend = .epoll,
});

// With coalescing for terminal
var loop = try EventLoop.init(allocator, .{
    .max_events = 64,
    .coalescing = .{
        .coalesce_resize = true,
        .max_coalesce_time_ms = 16,
    },
});
```
