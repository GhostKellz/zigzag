# ZigZag API Reference

Complete API documentation for the ZigZag event loop library.

## Core Types

| Type | Description |
|------|-------------|
| [EventLoop](event-loop.md) | Main event loop structure |
| [Event](events.md) | Event data structure |
| [EventType](events.md#eventtype) | Event type enumeration |
| [EventMask](events.md#eventmask) | File descriptor event mask |
| [Timer](timers.md) | Timer handle |
| [Watch](watches.md) | File descriptor watch |
| [Backend](backends.md) | Backend enumeration |
| [Options](options.md) | Event loop configuration |

## Import

```zig
const zigzag = @import("zigzag");

// Core types
const EventLoop = zigzag.EventLoop;
const Event = zigzag.Event;
const EventType = zigzag.EventType;
const EventMask = zigzag.EventMask;
const Timer = zigzag.Timer;
const Watch = zigzag.Watch;
const Backend = zigzag.Backend;
const Options = zigzag.Options;
```

## Basic Usage

```zig
const std = @import("std");
const zigzag = @import("zigzag");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create event loop
    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Add file descriptor watch
    const watch = try loop.addFd(fd, .{ .read = true });
    loop.setCallback(watch, myCallback);

    // Add timer
    const timer = try loop.addTimer(1000, timerCallback);

    // Run loop
    try loop.run();
}
```

## Thread Safety

EventLoop is **not thread-safe**. All operations must be performed from the thread that created the EventLoop.
