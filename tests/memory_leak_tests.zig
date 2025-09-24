//! Memory leak detection tests for zigzag
//! Uses std.testing.allocator to detect memory leaks

const std = @import("std");
const zigzag = @import("zigzag");

test "EventLoop memory leak test - basic lifecycle" {
    var gpa = std.testing.allocator;

    // Test basic initialization and deinitialization
    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    // Should not leak memory
}

test "EventLoop memory leak test - file descriptor watching" {
    var gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    // Create pipes for testing
    const pipe_result = try std.posix.pipe();
    const pipe_fds = pipe_result;
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    // Add and remove watch multiple times
    const watch = try loop.addFd(pipe_fds[0], .{ .read = true });
    loop.removeFd(watch);

    const watch2 = try loop.addFd(pipe_fds[0], .{ .read = true, .write = true });
    loop.removeFd(watch2);

    // Should not leak memory
}

test "EventLoop memory leak test - timer management" {
    var gpa = std.testing.allocator;

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
    var gpa = std.testing.allocator;

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
    var gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.timerCallback;

    // Create multiple pipes
    var pipes: [10][2]std.posix.fd_t = undefined;
    for (pipes, 0..) |*pipe, i| {
        const pipe_result = try std.posix.pipe();
        pipe[0] = pipe_result[0];
        pipe[1] = pipe_result[1];

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
    for (pipes) |pipe| {
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
    }

    // Should not leak memory
}

test "Terminal memory leak test - PTY operations" {
    var gpa = std.testing.allocator;

    const terminal = @import("../src/terminal.zig");

    // Test PTY creation and cleanup multiple times
    for (0..5) |_| {
        var pty = terminal.Pty.create() catch |err| switch (err) {
            error.AccessDenied, error.DeviceNotFound => return error.SkipZigTest,
            else => return err,
        };
        pty.close();
    }

    // Should not leak memory
}

test "Terminal memory leak test - EventCoalescer" {
    var gpa = std.testing.allocator;

    const terminal = @import("../src/terminal.zig");

    var coalescer = try terminal.EventCoalescer.init(gpa);
    defer coalescer.deinit();

    // Add many events
    for (0..100) |i| {
        const event = zigzag.Event{
            .fd = @intCast(i),
            .type = if (i % 2 == 0) .read_ready else .window_resize,
            .data = .{ .size = i },
        };
        try coalescer.addEvent(event);
    }

    // Drain events multiple times
    for (0..3) |_| {
        const events = try coalescer.drainEvents();
        gpa.free(events);
    }

    // Should not leak memory
}

test "Backend memory leak test - epoll" {
    var gpa = std.testing.allocator;

    const build_options = @import("build_options");
    if (!build_options.enable_epoll) return error.SkipZigTest;

    const EpollBackend = @import("../src/backend/epoll.zig").EpollBackend;

    var backend = EpollBackend.init(gpa) catch |err| switch (err) {
        error.SystemOutdated, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer backend.deinit();

    // Test timer operations
    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.timerCallback;

    for (0..10) |i| {
        const timer_id = @as(u32, @intCast(i + 1));
        try backend.addTimer(timer_id, 100);
        try backend.cancelTimer(timer_id);
    }

    // Should not leak memory
}

test "Backend memory leak test - io_uring" {
    var gpa = std.testing.allocator;

    const build_options = @import("build_options");
    if (!build_options.enable_io_uring) return error.SkipZigTest;

    const IoUringBackend = @import("../src/backend/io_uring.zig").IoUringBackend;

    var backend = IoUringBackend.init(gpa, 256) catch |err| switch (err) {
        error.SystemOutdated, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer backend.deinit();

    // Test basic operations
    for (0..10) |i| {
        const timer_id = @as(u32, @intCast(i + 1));
        try backend.addTimer(timer_id, 100);
        try backend.cancelTimer(timer_id);
    }

    // Should not leak memory
}