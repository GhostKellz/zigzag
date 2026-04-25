//! Comprehensive test suite for zigzag event loop
//! RC1 Polish & Testing Phase

const std = @import("std");
const testing = std.testing;
const zigzag = @import("zigzag");
const test_utils = @import("test_utils.zig");

test "Backend auto-detection" {
    const backend = zigzag.Backend.autoDetect();

    // Verify we got a valid backend
    switch (@import("builtin").os.tag) {
        .linux => {
            try testing.expect(backend == .io_uring or backend == .epoll);
        },
        .macos, .freebsd, .openbsd, .netbsd => {
            try testing.expectEqual(zigzag.Backend.kqueue, backend);
        },
        .windows => {
            try testing.expectEqual(zigzag.Backend.iocp, backend);
        },
        else => {},
    }
}

test "EventLoop initialization and cleanup" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with auto-detected backend
    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    try testing.expect(!loop.should_stop);
    try testing.expectEqual(@as(u32, 0), loop.next_watch_id);
}

test "EventLoop stop and reset" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Test stop mechanism
    try testing.expect(!loop.should_stop);
    loop.stop();
    try testing.expect(loop.should_stop);

    // Test reset
    loop.reset();
    try testing.expect(!loop.should_stop);
}

test "File descriptor watching" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Create pipe for testing
    const pipe = test_utils.createPipe() catch return error.SkipZigTest;
    defer test_utils.closePipe(pipe);

    // Add watch for read end
    const watch = try loop.addFd(pipe[0], .{ .read = true });
    try testing.expectEqual(pipe[0], watch.fd);
    try testing.expect(watch.events.read);

    // Verify watch is stored
    try testing.expect(loop.watches.contains(pipe[0]));

    // Write some data
    const test_data = "test";
    _ = try test_utils.writeToFd(pipe[1], test_data);

    // Poll for events (should detect readable data)
    var events: [10]zigzag.Event = undefined;
    const count = try loop.poll(&events, 100);

    // Should have at least one event
    try testing.expect(count > 0);

    // Remove watch
    loop.removeFd(watch);
    try testing.expect(!loop.watches.contains(pipe[0]));
}

test "Timer functionality" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    var timer_fired = false;

    const callback = struct {
        fn timerCallback(user_data: ?*anyopaque) void {
            const fired = @as(*bool, @ptrCast(@alignCast(user_data.?)));
            fired.* = true;
        }
    }.timerCallback;

    // Add short timer
    var timer = try loop.addTimer(50, callback);
    timer.user_data = @ptrCast(&timer_fired);

    // Update timer in storage with user_data
    if (loop.timers.getPtr(timer.id)) |stored_timer| {
        stored_timer.user_data = timer.user_data;
    }

    try testing.expect(loop.timers.contains(timer.id));

    // Run event loop briefly
    const start = test_utils.getMonotonicMs();
    while (test_utils.getMonotonicMs() - start < 200) {
        _ = try loop.tick();
        if (timer_fired) break;
        test_utils.sleepNs(10_000_000); // 10ms
    }

    // Timer should have fired
    try testing.expect(timer_fired);
}

test "Event coalescing" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = zigzag.CoalescingConfig{
        .coalesce_resize = true,
        .max_coalesce_time_ms = 50,
    };

    var loop = try zigzag.EventLoop.init(allocator, .{ .coalescing = config });
    defer loop.deinit();

    try testing.expect(loop.coalescer != null);
}

test "EventMask operations" {
    const mask1 = zigzag.EventMask{ .read = true, .write = false };
    try testing.expect(mask1.any());
    try testing.expect(mask1.read);
    try testing.expect(!mask1.write);

    const mask2 = zigzag.EventMask{};
    try testing.expect(!mask2.any());
}

test "Multiple file descriptors" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Create multiple pipes
    const pipe1 = test_utils.createPipe() catch return error.SkipZigTest;
    defer test_utils.closePipe(pipe1);

    const pipe2 = test_utils.createPipe() catch return error.SkipZigTest;
    defer test_utils.closePipe(pipe2);

    // Add watches
    const watch1 = try loop.addFd(pipe1[0], .{ .read = true });
    const watch2 = try loop.addFd(pipe2[0], .{ .read = true });

    try testing.expectEqual(pipe1[0], watch1.fd);
    try testing.expectEqual(pipe2[0], watch2.fd);

    // Verify both are tracked
    try testing.expectEqual(@as(usize, 2), loop.watches.count());

    // Cleanup
    loop.removeFd(watch1);
    loop.removeFd(watch2);
    try testing.expectEqual(@as(usize, 0), loop.watches.count());
}

test "Recurring timer" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    var fire_count: u32 = 0;

    const callback = struct {
        fn timerCallback(user_data: ?*anyopaque) void {
            const count = @as(*u32, @ptrCast(@alignCast(user_data.?)));
            count.* += 1;
        }
    }.timerCallback;

    // Add recurring timer (50ms interval)
    var timer = try loop.addRecurringTimer(50, callback);
    timer.user_data = @ptrCast(&fire_count);

    // Update in storage
    if (loop.timers.getPtr(timer.id)) |stored_timer| {
        stored_timer.user_data = timer.user_data;
    }

    // Run for ~200ms, should fire multiple times
    const start = test_utils.getMonotonicMs();
    while (test_utils.getMonotonicMs() - start < 200) {
        _ = try loop.tick();
        test_utils.sleepNs(10_000_000); // 10ms
    }

    // Cancel timer
    loop.cancelTimer(&timer);

    // Should have fired at least 2-3 times
    try testing.expect(fire_count >= 2);
}

test "Watch callback mechanism" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    const pipe = test_utils.createPipe() catch return error.SkipZigTest;
    defer test_utils.closePipe(pipe);

    const testCallback = struct {
        fn callback(watch: *const zigzag.Watch, event: zigzag.Event) void {
            _ = watch;
            _ = event;
            // Callback would be triggered here
        }
    }.callback;

    const watch = try loop.addFd(pipe[0], .{ .read = true });
    loop.setCallback(watch, testCallback);

    // Verify callback is set
    if (loop.watches.get(pipe[0])) |stored_watch| {
        try testing.expect(stored_watch.callback != null);
    }

    loop.removeFd(watch);
}

test "Memory leak detection" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        std.testing.expect(leaked == .ok) catch @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    // Create and destroy event loop multiple times
    for (0..10) |_| {
        var loop = try zigzag.EventLoop.init(allocator, .{});

        // Add some watches and timers
        const pipe = test_utils.createPipe() catch return error.SkipZigTest;
        const watch = try loop.addFd(pipe[0], .{ .read = true });

        const callback = struct {
            fn cb(_: ?*anyopaque) void {}
        }.cb;
        _ = try loop.addTimer(1000, callback);

        // Cleanup
        loop.removeFd(watch);
        test_utils.closePipe(pipe);
        loop.deinit();
    }
}

test "Stress test - many file descriptors" {
    if (comptime !test_utils.supportsPosixPipe()) return error.SkipZigTest;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    const num_pipes = 10;
    var pipes: [num_pipes][2]test_utils.Fd = undefined;

    // Create multiple pipes and watch them
    for (0..num_pipes) |i| {
        pipes[i] = test_utils.createPipe() catch return error.SkipZigTest;
        _ = try loop.addFd(pipes[i][0], .{ .read = true });
    }

    // Verify all are tracked
    try testing.expectEqual(num_pipes, loop.watches.count());

    // Write to all pipes
    for (0..num_pipes) |i| {
        _ = try test_utils.writeToFd(pipes[i][1], "x");
    }

    // Poll should detect events
    var events: [num_pipes * 2]zigzag.Event = undefined;
    const count = try loop.poll(&events, 100);
    try testing.expect(count > 0);

    // Cleanup - look up fresh watch pointers
    for (0..num_pipes) |i| {
        if (loop.watches.get(pipes[i][0])) |watch| {
            loop.removeFd(watch);
        }
        test_utils.closePipe(pipes[i]);
    }

    try testing.expectEqual(@as(usize, 0), loop.watches.count());
}

test "Performance - event loop overhead" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    const iterations = 1000;
    const start = test_utils.getMonotonicNs();

    for (0..iterations) |_| {
        _ = try loop.tick();
    }

    const end = test_utils.getMonotonicNs();
    const elapsed = end - start;
    const avg_ns = @divTrunc(elapsed, iterations);

    // Average tick should be under 10 microseconds
    try testing.expect(avg_ns < 10_000);

}
