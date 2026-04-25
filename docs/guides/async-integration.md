# Async Integration

Integrating ZigZag with the experimental zsync async helpers.

## Overview

ZigZag includes experimental helpers for pairing the event loop with zsync-style async flows.

## Build Configuration

Enable zsync integration:

```bash
zig build -Dzsync=true
```

Disable if not needed:

```bash
zig build -Dzsync=false
```

## Usage

```zig
const zigzag = @import("zigzag");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Use with zsync runtime
    // See zsync documentation for async patterns
}
```

## Status

This surface is still experimental in `v0.1.6`.

- `AsyncRuntime`, `AsyncFile`, `AsyncTimer`, and `AsyncUtils` are exported when `-Dzsync=true`.
- Read, write, and timer operations now keep operation state alive until completion.
- The API shape may still change as the runtime is validated against real applications.

See [zsync documentation](https://github.com/ghostkellz/zsync) for details.
