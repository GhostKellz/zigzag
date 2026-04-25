# Performance

Performance characteristics of ZigZag.

## Backend Performance

| Backend | Latency | Throughput | Notes |
|---------|---------|------------|-------|
| io_uring | ~500ns | 2M+ events/sec | Zero-copy, batched |
| epoll | ~1μs | 1M+ events/sec | Reliable |
| kqueue | ~800ns | 1.5M+ events/sec | Native timers |

## Contents

- [Tuning Guide](tuning.md) - Configuration tuning

## Key Optimizations

- **Syscall batching** - io_uring batches operations
- **Timer coalescing** - Reduces timer overhead
- **Event coalescing** - Batches rapid events
- **Minimal allocations** - Hot paths avoid allocation

## Monitoring

Create an event loop with explicit tuning and run the benchmark harness:

```zig
var loop = try zigzag.EventLoop.init(allocator, .{ .max_events = 2048 });
defer loop.deinit();
```

Run `zig build bench` for detailed benchmarks.
