//! Memory leak detection tests for zigzag
//! Uses std.testing.allocator to detect memory leaks

const std = @import("std");
const builtin = @import("builtin");
const zigzag = @import("zigzag");
const test_utils = @import("test_utils.zig");

test "EventLoop memory leak test - basic lifecycle" {
    const gpa = std.testing.allocator;

    // Test basic initialization and deinitialization
    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    // Should not leak memory
}

test "EventLoop memory leak test - file descriptor watching" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    const gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    // Create pipes for testing
    const pipe_fds = test_utils.createPipe() catch return error.SkipZigTest;
    defer test_utils.closePipe(pipe_fds);

    // Add and remove watch multiple times
    const watch = try loop.addFd(pipe_fds[0], .{ .read = true });
    loop.removeFd(watch);

    const watch2 = try loop.addFd(pipe_fds[0], .{ .read = true, .write = true });
    loop.removeFd(watch2);

    // Should not leak memory
}

test "EventLoop memory leak test - timer management" {
    const gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.timerCallback;

    // Add and cancel multiple timers
    const timer1 = try loop.addTimer(100, callback);
    loop.cancelTimer(&timer1);

    const timer2 = try loop.addRecurringTimer(50, callback);
    loop.cancelTimer(&timer2);

    // Should not leak memory
}

test "EventLoop memory leak test - poll operations" {
    const gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    var events: [64]zigzag.Event = undefined;

    // Poll multiple times
    for (0..10) |_| {
        const count = try loop.poll(&events, 10);
        _ = count;
    }

    // Should not leak memory
}

test "EventLoop memory leak test - stress test with many operations" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    const gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.timerCallback;

    // Create multiple pipes
    var pipes: [10][2]test_utils.Fd = undefined;
    for (&pipes, 0..) |*pipe, i| {
        pipe.* = test_utils.createPipe() catch return error.SkipZigTest;

        // Add watches
        const watch = try loop.addFd(pipe[0], .{ .read = true });

        // Add timer
        const timer = try loop.addTimer(100 + i * 10, callback);

        // Poll a few times
        var events: [32]zigzag.Event = undefined;
        _ = try loop.poll(&events, 1);

        // Remove everything
        loop.removeFd(watch);
        loop.cancelTimer(&timer);
    }

    // Clean up pipes
    for (&pipes) |*pipe| {
        test_utils.closePipe(pipe.*);
    }

    // Should not leak memory
}

// Terminal memory leak tests are in src/terminal.zig internal tests
// They require libc linkage which is handled by the main module build

// Backend-specific memory leak tests are tested via internal module tests
// (src/root.zig tests) since they require direct backend imports.
