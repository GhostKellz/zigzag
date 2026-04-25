# Quick Start

Get up and running with ZigZag.

## Installation

```bash
zig fetch --save https://github.com/ghostkellz/zigzag/archive/refs/tags/v0.1.6.tar.gz
```

Add to `build.zig`:

```zig
const zigzag = b.dependency("zigzag", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
```

## Basic Event Loop

```zig
const std = @import("std");
const zigzag = @import("zigzag");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    std.debug.print("Backend: {}\n", .{loop.backend});
}
```

## Timer Example

```zig
const std = @import("std");
const zigzag = @import("zigzag");

fn timerCallback(user_data: ?*anyopaque) void {
    _ = user_data;
    std.debug.print("Timer fired!\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    _ = try loop.addRecurringTimer(1000, timerCallback);

    try loop.run();
}
```

## File Descriptor Watching

```zig
fn handleEvent(watch: *const zigzag.Watch, event: zigzag.Event) void {
    _ = watch;
    switch (event.type) {
        .read_ready => std.debug.print("Data available\n", .{}),
        else => {},
    }
}

pub fn main() !void {
    // ... allocator setup ...

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    const watch = try loop.addFd(socket_fd, .{ .read = true });
    loop.setCallback(watch, handleEvent);

    try loop.run();
}
```

## Non-blocking Poll

```zig
var events: [64]zigzag.Event = undefined;
const count = try loop.poll(&events, 100); // 100ms timeout

for (events[0..count]) |event| {
    // Process events
}
```
