//! Performance benchmarks for zigzag
//! Compare against baseline implementations

const std = @import("std");
const zigzag = @import("zigzag");

// Simple benchmark framework
const BenchResult = struct {
    name: []const u8,
    operations: u64,
    duration_ns: u64,

    pub fn format(
        self: BenchResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const ops_per_sec = (@as(f64, @floatFromInt(self.operations)) * 1e9) / @as(f64, @floatFromInt(self.duration_ns));
        try writer.print("{s}: {d} ops in {d}ns ({d:.0} ops/sec)", .{ self.name, self.operations, self.duration_ns, ops_per_sec });
    }
};

fn benchmark(comptime name: []const u8, operations: u64, func: anytype) BenchResult {
    const start = std.time.nanoTimestamp();
    func();
    const end = std.time.nanoTimestamp();

    return BenchResult{
        .name = name,
        .operations = operations,
        .duration_ns = @intCast(end - start),
    };
}

// Mock "libxev-like" implementation for comparison
const MockEventLoop = struct {
    pipes: std.ArrayList([2]std.posix.fd_t),

    fn init(allocator: std.mem.Allocator) !MockEventLoop {
        return MockEventLoop{
            .pipes = std.ArrayList([2]std.posix.fd_t).init(allocator),
        };
    }

    fn deinit(self: *MockEventLoop) void {
        for (self.pipes.items) |pipe| {
            std.posix.close(pipe[0]);
            std.posix.close(pipe[1]);
        }
        self.pipes.deinit();
    }

    fn addFd(self: *MockEventLoop) !void {
        const pipe_result = try std.posix.pipe();
        try self.pipes.append(pipe_result);
    }

    fn poll(self: *MockEventLoop) !u32 {
        // Simple select-based polling simulation
        _ = self;
        std.time.sleep(1 * std.time.ns_per_ms); // Simulate syscall overhead
        return 0;
    }
};

test "Benchmark - EventLoop initialization" {
    var gpa = std.testing.allocator;

    const result = benchmark("EventLoop init/deinit", 10000, struct {
        fn run() void {
            for (0..10000) |_| {
                var loop = zigzag.EventLoop.init(gpa, .{}) catch return;
                loop.deinit();
            }
        }
    }.run);

    std.debug.print("\n{}\n", .{result});

    // Should be able to create/destroy at least 1000 loops per second
    const ops_per_sec = (@as(f64, @floatFromInt(result.operations)) * 1e9) / @as(f64, @floatFromInt(result.duration_ns));
    try std.testing.expect(ops_per_sec > 1000.0);
}

test "Benchmark - File descriptor operations" {
    var gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    // Benchmark adding file descriptors
    const add_result = benchmark("Add FDs", 1000, struct {
        fn run() void {
            var pipes: [1000][2]std.posix.fd_t = undefined;
            var watches: [1000]*const zigzag.Watch = undefined;

            for (pipes, 0..) |*pipe, i| {
                const pipe_result = std.posix.pipe() catch return;
                pipe[0] = pipe_result[0];
                pipe[1] = pipe_result[1];

                watches[i] = loop.addFd(pipe[0], .{ .read = true }) catch return;
            }

            // Cleanup
            for (pipes, 0..) |pipe, i| {
                loop.removeFd(watches[i]);
                std.posix.close(pipe[0]);
                std.posix.close(pipe[1]);
            }
        }
    }.run);

    std.debug.print("{}\n", .{add_result});

    // Should be able to add at least 10000 FDs per second
    const ops_per_sec = (@as(f64, @floatFromInt(add_result.operations)) * 1e9) / @as(f64, @floatFromInt(add_result.duration_ns));
    try std.testing.expect(ops_per_sec > 10000.0);
}

test "Benchmark - Timer operations" {
    var gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.timerCallback;

    const timer_result = benchmark("Timer add/cancel", 5000, struct {
        fn run() void {
            var timers: [5000]zigzag.Timer = undefined;

            // Add timers
            for (timers, 0..) |*timer, i| {
                timer.* = loop.addTimer(100 + i, callback) catch return;
            }

            // Cancel timers
            for (timers) |timer| {
                loop.cancelTimer(&timer);
            }
        }
    }.run);

    std.debug.print("{}\n", .{timer_result});

    // Should be able to handle at least 5000 timer ops per second
    const ops_per_sec = (@as(f64, @floatFromInt(timer_result.operations)) * 1e9) / @as(f64, @floatFromInt(timer_result.duration_ns));
    try std.testing.expect(ops_per_sec > 5000.0);
}

test "Benchmark - Polling performance" {
    var gpa = std.testing.allocator;

    var loop = try zigzag.EventLoop.init(gpa, .{});
    defer loop.deinit();

    // Setup some file descriptors
    const pipe_result = try std.posix.pipe();
    const pipe_fds = pipe_result;
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    const watch = try loop.addFd(pipe_fds[0], .{ .read = true });
    defer loop.removeFd(watch);

    var events: [64]zigzag.Event = undefined;

    const poll_result = benchmark("Empty polls", 10000, struct {
        fn run() void {
            for (0..10000) |_| {
                _ = loop.poll(&events, 0) catch return;
            }
        }
    }.run);

    std.debug.print("{}\n", .{poll_result});

    // Should be able to do at least 50000 empty polls per second
    const ops_per_sec = (@as(f64, @floatFromInt(poll_result.operations)) * 1e9) / @as(f64, @floatFromInt(poll_result.duration_ns));
    try std.testing.expect(ops_per_sec > 50000.0);
}

test "Benchmark - zigzag vs mock comparison" {
    var gpa = std.testing.allocator;

    // Benchmark zigzag
    const zigzag_result = benchmark("zigzag setup", 1000, struct {
        fn run() void {
            for (0..1000) |_| {
                var loop = zigzag.EventLoop.init(gpa, .{}) catch return;
                const pipe_result = std.posix.pipe() catch return;
                const pipe_fds = pipe_result;
                _ = loop.addFd(pipe_fds[0], .{ .read = true }) catch return;
                std.posix.close(pipe_fds[0]);
                std.posix.close(pipe_fds[1]);
                loop.deinit();
            }
        }
    }.run);

    // Benchmark mock
    const mock_result = benchmark("mock setup", 1000, struct {
        fn run() void {
            for (0..1000) |_| {
                var loop = MockEventLoop.init(gpa) catch return;
                loop.addFd() catch return;
                loop.deinit();
            }
        }
    }.run);

    std.debug.print("{}\n", .{zigzag_result});
    std.debug.print("{}\n", .{mock_result});

    // zigzag should be competitive (within 2x) of mock implementation
    const zigzag_ops_per_sec = (@as(f64, @floatFromInt(zigzag_result.operations)) * 1e9) / @as(f64, @floatFromInt(zigzag_result.duration_ns));
    const mock_ops_per_sec = (@as(f64, @floatFromInt(mock_result.operations)) * 1e9) / @as(f64, @floatFromInt(mock_result.duration_ns));

    // Allow zigzag to be up to 2x slower than mock (it does more work)
    try std.testing.expect(zigzag_ops_per_sec > mock_ops_per_sec * 0.5);
}

test "Benchmark - Terminal operations" {
    var gpa = std.testing.allocator;

    const terminal = @import("../src/terminal.zig");

    const pty_result = benchmark("PTY create/destroy", 100, struct {
        fn run() void {
            for (0..100) |_| {
                var pty = terminal.Pty.create() catch return;
                pty.close();
            }
        }
    }.run);

    std.debug.print("{}\n", .{pty_result});

    const coalesce_result = benchmark("Event coalescing", 10000, struct {
        fn run() void {
            var coalescer = terminal.EventCoalescer.init(gpa) catch return;
            defer coalescer.deinit();

            for (0..10000) |i| {
                const event = zigzag.Event{
                    .fd = -1,
                    .type = .window_resize,
                    .data = .{ .size = i },
                };
                coalescer.addEvent(event) catch return;
            }

            const events = coalescer.drainEvents() catch return;
            gpa.free(events);
        }
    }.run);

    std.debug.print("{}\n", .{coalesce_result});

    // Should be able to coalesce at least 100000 events per second
    const ops_per_sec = (@as(f64, @floatFromInt(coalesce_result.operations)) * 1e9) / @as(f64, @floatFromInt(coalesce_result.duration_ns));
    try std.testing.expect(ops_per_sec > 100000.0);
}