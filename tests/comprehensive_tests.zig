//! Comprehensive test suite for zigzag event loop
//! RC1 Polish & Testing Phase

const std = @import("std");
const testing = std.testing;
const zigzag = @import("zigzag");

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with auto-detected backend
    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    try testing.expect(!loop.should_stop);
    try testing.expectEqual(@as(u32, 0), loop.next_watch_id);
}

test "EventLoop stop and reset" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Create pipe for testing
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);

    // Add watch for read end
    const watch = try loop.addFd(pipe[0], .{ .read = true });
    try testing.expectEqual(pipe[0], watch.fd);
    try testing.expect(watch.events.read);

    // Verify watch is stored
    try testing.expect(loop.watches.contains(pipe[0]));

    // Write some data
    const test_data = "test";
    _ = try std.posix.write(pipe[1], test_data);

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 200) {
        _ = try loop.tick();
        if (timer_fired) break;
        std.time.sleep(10_000_000); // 10ms
    }

    // Timer should have fired
    try testing.expect(timer_fired);
}

test "Event coalescing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = zigzag.CoalescingConfig{
        .enable_resize_coalescing = true,
        .resize_debounce_ms = 50,
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    // Create multiple pipes
    const pipe1 = try std.posix.pipe();
    defer std.posix.close(pipe1[0]);
    defer std.posix.close(pipe1[1]);

    const pipe2 = try std.posix.pipe();
    defer std.posix.close(pipe2[0]);
    defer std.posix.close(pipe2[1]);

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 200) {
        _ = try loop.tick();
        std.time.sleep(10_000_000); // 10ms
    }

    // Cancel timer
    loop.cancelTimer(&timer);

    // Should have fired at least 2-3 times
    try testing.expect(fire_count >= 2);
}

test "Watch callback mechanism" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);

    var callback_fired = false;

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        std.testing.expect(leaked == .ok) catch @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    // Create and destroy event loop multiple times
    for (0..10) |_| {
        var loop = try zigzag.EventLoop.init(allocator, .{});

        // Add some watches and timers
        const pipe = try std.posix.pipe();
        const watch = try loop.addFd(pipe[0], .{ .read = true });

        const callback = struct {
            fn cb(_: ?*anyopaque) void {}
        }.cb;
        _ = try loop.addTimer(1000, callback);

        // Cleanup
        loop.removeFd(watch);
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
        loop.deinit();
    }
}

test "Stress test - many file descriptors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    const num_pipes = 10;
    var pipes: [num_pipes][2]std.posix.fd_t = undefined;
    var watches: [num_pipes]*const zigzag.Watch = undefined;

    // Create multiple pipes and watch them
    for (0..num_pipes) |i| {
        pipes[i] = try std.posix.pipe();
        watches[i] = try loop.addFd(pipes[i][0], .{ .read = true });
    }

    // Verify all are tracked
    try testing.expectEqual(num_pipes, loop.watches.count());

    // Write to all pipes
    for (0..num_pipes) |i| {
        _ = try std.posix.write(pipes[i][1], "x");
    }

    // Poll should detect events
    var events: [num_pipes * 2]zigzag.Event = undefined;
    const count = try loop.poll(&events, 100);
    try testing.expect(count > 0);

    // Cleanup
    for (0..num_pipes) |i| {
        loop.removeFd(watches[i]);
        std.posix.close(pipes[i][0]);
        std.posix.close(pipes[i][1]);
    }

    try testing.expectEqual(@as(usize, 0), loop.watches.count());
}

test "Performance - event loop overhead" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    const iterations = 1000;
    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        _ = try loop.tick();
    }

    const elapsed = std.time.nanoTimestamp() - start;
    const avg_ns = @divTrunc(elapsed, iterations);

    // Average tick should be under 10 microseconds
    try testing.expect(avg_ns < 10_000);

    std.debug.print("Average tick time: {}ns\n", .{avg_ns});
}
