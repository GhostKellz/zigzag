//! Stress tests for zigzag event loop
//! Test high-load scenarios and edge cases

const std = @import("std");
const zigzag = @import("zigzag");

test "EventLoop stress test - many file descriptors" {
    var gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{ .max_events = 2048 });
    defer loop.deinit();

    const max_fds = 100; // Keep reasonable for CI
    var pipes: [max_fds][2]std.posix.fd_t = undefined;
    var watches: [max_fds]*const zigzag.Watch = undefined;

    // Create many file descriptors and watch them
    for (pipes, 0..) |*pipe, i| {
        const pipe_result = try std.posix.pipe();
        pipe[0] = pipe_result[0];
        pipe[1] = pipe_result[1];

        watches[i] = try loop.addFd(pipe[0], .{ .read = true });
    }

    // Poll multiple times to test handling
    var events: [1024]zigzag.Event = undefined;
    for (0..10) |_| {
        const count = try loop.poll(&events, 10);
        _ = count;
    }

    // Write to some pipes and check for events
    for (pipes[0..5]) |pipe| {
        _ = try std.posix.write(pipe[1], "test");
    }

    const count = try loop.poll(&events, 100);
    try std.testing.expect(count >= 5);

    // Cleanup
    for (pipes, 0..) |pipe, i| {
        loop.removeFd(watches[i]);
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
    }
}

test "EventLoop stress test - many timers" {
    var gpa = std.testing.allocator;

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
    for (timers, 0..) |*timer, i| {
        timer.* = try loop.addTimer(100 + i, callback);
    }

    // Poll and let some timers fire
    var events: [512]zigzag.Event = undefined;
    for (0..20) |_| {
        const count = try loop.poll(&events, 50);
        _ = count;
    }

    // Cancel all timers
    for (timers) |timer| {
        loop.cancelTimer(&timer);
    }
}

test "EventLoop stress test - high frequency polling" {
    var gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    // Create a self-pipe for testing
    const pipe_result = try std.posix.pipe();
    const pipe_fds = pipe_result;
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    const watch = try loop.addFd(pipe_fds[0], .{ .read = true });

    var events: [64]zigzag.Event = undefined;

    // High-frequency polling
    for (0..1000) |i| {
        if (i % 100 == 0) {
            // Write data occasionally
            _ = try std.posix.write(pipe_fds[1], "x");
        }

        const count = try loop.poll(&events, 1);

        if (count > 0) {
            // Consume data
            var buf: [1024]u8 = undefined;
            _ = std.posix.read(pipe_fds[0], &buf) catch {};
        }
    }

    loop.removeFd(watch);
}

test "EventLoop stress test - mixed operations under load" {
    var gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.timerCallback;

    // Create some pipes
    const pipe_result1 = try std.posix.pipe();
    const pipe_result2 = try std.posix.pipe();
    const pipe_fds1 = pipe_result1;
    const pipe_fds2 = pipe_result2;

    defer std.posix.close(pipe_fds1[0]);
    defer std.posix.close(pipe_fds1[1]);
    defer std.posix.close(pipe_fds2[0]);
    defer std.posix.close(pipe_fds2[1]);

    const watch1 = try loop.addFd(pipe_fds1[0], .{ .read = true });
    const watch2 = try loop.addFd(pipe_fds2[0], .{ .read = true, .write = true });

    // Add timers
    const timer1 = try loop.addTimer(50, callback);
    const timer2 = try loop.addRecurringTimer(25, callback);

    var events: [128]zigzag.Event = undefined;

    // Run mixed operations
    for (0..200) |i| {
        // Write data occasionally
        if (i % 10 == 0) {
            _ = try std.posix.write(pipe_fds1[1], "data1");
        }
        if (i % 15 == 0) {
            _ = try std.posix.write(pipe_fds2[1], "data2");
        }

        // Poll for events
        const count = try loop.poll(&events, 5);

        // Process events
        for (events[0..count]) |event| {
            if (event.type == .read_ready and event.fd >= 0) {
                var buf: [1024]u8 = undefined;
                _ = std.posix.read(event.fd, &buf) catch {};
            }
        }

        // Occasionally modify watches
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

test "Terminal stress test - rapid PTY operations" {
    var gpa = std.testing.allocator;
    _ = gpa;

    const terminal = @import("../src/terminal.zig");

    // Rapidly create and destroy PTYs
    for (0..10) |_| {
        var pty = terminal.Pty.create() catch |err| switch (err) {
            error.AccessDenied, error.DeviceNotFound => return error.SkipZigTest,
            else => return err,
        };

        // Test size operations
        try pty.setSize(24, 80);
        const size = try pty.getSize();
        try std.testing.expectEqual(@as(u16, 24), size.ws_row);
        try std.testing.expectEqual(@as(u16, 80), size.ws_col);

        // Test different sizes
        try pty.setSize(50, 120);
        const size2 = try pty.getSize();
        try std.testing.expectEqual(@as(u16, 50), size2.ws_row);
        try std.testing.expectEqual(@as(u16, 120), size2.ws_col);

        pty.close();
    }
}

test "Terminal stress test - event coalescing under load" {
    var gpa = std.testing.allocator;

    const terminal = @import("../src/terminal.zig");

    var coalescer = try terminal.EventCoalescer.init(gpa);
    defer coalescer.deinit();

    // Simulate rapid window resize events
    for (0..1000) |i| {
        const event = zigzag.Event{
            .fd = -1,
            .type = .window_resize,
            .data = .{ .size = i },
        };
        try coalescer.addEvent(event);

        // Occasionally add other events
        if (i % 100 == 0) {
            const other_event = zigzag.Event{
                .fd = @intCast(i),
                .type = .read_ready,
                .data = .{ .size = i },
            };
            try coalescer.addEvent(other_event);
        }
    }

    const events = try coalescer.drainEvents();
    defer gpa.free(events);

    // Should have coalesced window resize events
    var resize_count: usize = 0;
    var other_count: usize = 0;

    for (events) |event| {
        if (event.type == .window_resize) {
            resize_count += 1;
        } else {
            other_count += 1;
        }
    }

    // Should have far fewer resize events than we added
    try std.testing.expect(resize_count < 100);
    try std.testing.expect(other_count == 10); // Should have all non-resize events
}

test "Backend stress test - rapid timer operations" {
    var gpa = std.testing.allocator;

    const build_options = @import("build_options");
    if (!build_options.enable_epoll) return error.SkipZigTest;

    const EpollBackend = @import("../src/backend/epoll.zig").EpollBackend;

    var backend = EpollBackend.init(gpa) catch |err| switch (err) {
        error.SystemOutdated, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer backend.deinit();

    // Rapidly add and cancel timers
    for (0..100) |i| {
        const timer_id = @as(u32, @intCast(i + 1));

        // Add timer
        try backend.addTimer(timer_id, 10 + i);

        // Poll briefly
        var events: [32]zigzag.Event = undefined;
        _ = try backend.poll(&events, 1);

        // Cancel timer
        try backend.cancelTimer(timer_id);
    }

    // Test with recurring timers too
    for (0..50) |i| {
        const timer_id = @as(u32, @intCast(i + 1000));

        try backend.addRecurringTimer(timer_id, 5);

        // Let it fire a few times
        var events: [32]zigzag.Event = undefined;
        for (0..3) |_| {
            _ = try backend.poll(&events, 20);
        }

        try backend.cancelTimer(timer_id);
    }
}