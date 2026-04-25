//! Stress tests for zigzag event loop
//! Test high-load scenarios and edge cases

const std = @import("std");
const builtin = @import("builtin");
const zigzag = @import("zigzag");
const test_utils = @import("test_utils.zig");

test "EventLoop stress test - many file descriptors" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    const gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{ .max_events = 2048 });
    defer loop.deinit();

    const max_fds = 100;
    var pipes: [max_fds][2]test_utils.Fd = undefined;

    // Create many file descriptors and watch them
    for (&pipes) |*pipe| {
        pipe.* = test_utils.createPipe() catch return error.SkipZigTest;
        _ = try loop.addFd(pipe.*[0], .{ .read = true });
    }

    // Poll multiple times to test handling
    var events: [1024]zigzag.Event = undefined;
    for (0..10) |_| {
        _ = try loop.poll(&events, 10);
    }

    // Write to some pipes and check for events
    for (pipes[0..5]) |pipe| {
        _ = try test_utils.writeToFd(pipe[1], "test");
    }

    const count = try loop.poll(&events, 100);
    try std.testing.expect(count >= 5);

    // Cleanup - look up fresh watch pointers for each fd
    for (&pipes) |*pipe| {
        if (loop.watches.get(pipe.*[0])) |watch| {
            loop.removeFd(watch);
        }
        test_utils.closePipe(pipe.*);
    }
}

test "EventLoop stress test - many timers" {
    const gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.timerCallback;

    const max_timers = 100;
    var timers: [max_timers]zigzag.Timer = undefined;

    // Create many timers
    for (&timers, 0..) |*timer, i| {
        timer.* = try loop.addTimer(100 + i, callback);
    }

    // Poll and let some timers fire
    var events: [512]zigzag.Event = undefined;
    for (0..20) |_| {
        _ = try loop.poll(&events, 50);
    }

    // Cancel all timers
    for (&timers) |*timer| {
        loop.cancelTimer(timer);
    }
}

test "EventLoop stress test - high frequency polling" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    const gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    const pipe_fds = test_utils.createPipe() catch return error.SkipZigTest;
    defer test_utils.closePipe(pipe_fds);

    const watch = try loop.addFd(pipe_fds[0], .{ .read = true });

    var events: [64]zigzag.Event = undefined;

    // High-frequency polling
    for (0..1000) |i| {
        if (i % 100 == 0) {
            _ = try test_utils.writeToFd(pipe_fds[1], "x");
        }

        const count = try loop.poll(&events, 1);

        if (count > 0) {
            var buf: [1024]u8 = undefined;
            _ = test_utils.readFromFd(pipe_fds[0], &buf) catch {};
        }
    }

    loop.removeFd(watch);
}

test "EventLoop stress test - mixed operations under load" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    const gpa = std.testing.allocator;

    const options: zigzag.Options = switch (builtin.os.tag) {
        .linux => .{ .backend = .epoll },
        .macos => .{ .backend = .kqueue },
        else => .{},
    };

    var loop = try zigzag.EventLoop.init(gpa, options);
    defer loop.deinit();

    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.timerCallback;

    const pipe_fds1 = test_utils.createPipe() catch return error.SkipZigTest;
    const pipe_fds2 = test_utils.createPipe() catch return error.SkipZigTest;

    defer test_utils.closePipe(pipe_fds1);
    defer test_utils.closePipe(pipe_fds2);

    const watch1 = try loop.addFd(pipe_fds1[0], .{ .read = true });
    const watch2 = try loop.addFd(pipe_fds2[0], .{ .read = true, .write = true });

    // Add timers
    const timer1 = try loop.addTimer(50, callback);
    const timer2 = try loop.addRecurringTimer(25, callback);

    var events: [128]zigzag.Event = undefined;

    // Run mixed operations
    for (0..200) |i| {
        if (i % 10 == 0) {
            _ = try test_utils.writeToFd(pipe_fds1[1], "data1");
        }
        if (i % 15 == 0) {
            _ = try test_utils.writeToFd(pipe_fds2[1], "data2");
        }

        const count = try loop.poll(&events, 5);

        for (events[0..count]) |event| {
            if (event.type == .read_ready and event.fd >= 0) {
                var buf: [1024]u8 = undefined;
                _ = test_utils.readFromFd(event.fd, &buf) catch {};
            }
        }

        if (i % 50 == 0) {
            try loop.modifyFd(watch2, .{ .read = true });
        }
    }

    // Cleanup
    loop.removeFd(watch1);
    loop.removeFd(watch2);
    loop.cancelTimer(&timer1);
    loop.cancelTimer(&timer2);
}

// Terminal stress tests are in src/terminal.zig internal tests
// They require libc linkage which is handled by the main module build

// Backend-specific stress tests are tested via internal module tests
// (src/root.zig tests) since they require direct backend imports.
