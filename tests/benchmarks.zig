//! Performance benchmarks for zigzag
//! Run with: zig build bench

const std = @import("std");
const builtin = @import("builtin");
const zigzag = @import("zigzag");
const test_utils = @import("test_utils.zig");

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

fn getTimeNs() i64 {
    return test_utils.getMonotonicNs();
}

fn benchmarkOptions() zigzag.Options {
    return switch (builtin.os.tag) {
        .linux => .{ .backend = .epoll },
        .macos, .freebsd, .openbsd, .netbsd => .{ .backend = .kqueue },
        .windows => .{ .backend = .iocp },
        else => .{},
    };
}

fn printResult(result: BenchResult) void {
    std.debug.print("{s}: {d} ops in {d}ns ({d:.0} ops/sec)\n", .{
        result.name,
        result.operations,
        result.duration_ns,
        (@as(f64, @floatFromInt(result.operations)) * 1e9) / @as(f64, @floatFromInt(result.duration_ns)),
    });
}

fn runInitBenchmark(allocator: std.mem.Allocator) !void {
    const start = getTimeNs();
    const operations: u64 = 10000;

    for (0..operations) |_| {
        var loop = try zigzag.EventLoop.init(allocator, benchmarkOptions());
        loop.deinit();
    }

    const duration_ns: u64 = @intCast(getTimeNs() - start);
    printResult(.{
        .name = "EventLoop init/deinit",
        .operations = operations,
        .duration_ns = duration_ns,
    });
}

fn runFdBenchmark(allocator: std.mem.Allocator) !void {
    if (comptime builtin.os.tag != .linux) return;

    var loop = try zigzag.EventLoop.init(allocator, .{ .backend = .epoll });
    defer loop.deinit();

    const operations: u64 = 100;
    var pipes: [100][2]std.posix.fd_t = undefined;
    const start = getTimeNs();

    for (&pipes) |*pipe| {
        pipe.* = try test_utils.createPipe();
        _ = try loop.addFd(pipe.*[0], .{ .read = true });
    }

    for (pipes) |pipe| {
        if (loop.watches.get(pipe[0])) |watch| {
            loop.removeFd(watch);
        }
        test_utils.closePipe(pipe);
    }

    const duration_ns: u64 = @intCast(getTimeNs() - start);
    printResult(.{
        .name = "Add/remove FDs",
        .operations = operations,
        .duration_ns = duration_ns,
    });
}

fn runTimerBenchmark(allocator: std.mem.Allocator) !void {
    var loop = try zigzag.EventLoop.init(allocator, benchmarkOptions());
    defer loop.deinit();

    const callback = struct {
        pub fn timerCallback(_: ?*anyopaque) void {}
    }.timerCallback;

    const operations: u64 = 1000;
    var timers: [1000]zigzag.Timer = undefined;
    const start = getTimeNs();

    for (&timers, 0..) |*timer, i| {
        timer.* = try loop.addTimer(100 + i, callback);
    }

    for (&timers) |*timer| {
        loop.cancelTimer(timer);
    }

    const duration_ns: u64 = @intCast(getTimeNs() - start);
    printResult(.{
        .name = "Timer add/cancel",
        .operations = operations,
        .duration_ns = duration_ns,
    });
}

fn runPollBenchmark(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .linux) return;

    var loop = try zigzag.EventLoop.init(allocator, .{ .backend = .epoll });
    defer loop.deinit();

    const pipe_fds = try test_utils.createPipe();
    defer test_utils.closePipe(pipe_fds);

    const watch = try loop.addFd(pipe_fds[0], .{ .read = true });
    defer loop.removeFd(watch);

    var events: [64]zigzag.Event = undefined;
    const operations: u64 = 10000;
    const start = getTimeNs();

    for (0..operations) |_| {
        _ = try loop.poll(&events, 0);
    }

    const duration_ns: u64 = @intCast(getTimeNs() - start);
    printResult(.{
        .name = "Empty polls",
        .operations = operations,
        .duration_ns = duration_ns,
    });
}

fn runTerminalBenchmark() !void {
    if (!test_utils.supportsTerminal()) return;

    const terminal = zigzag.terminal;
    if (@TypeOf(terminal) == void) return;

    const operations: u64 = 100;
    const start = getTimeNs();

    for (0..operations) |_| {
        var pty = terminal.Pty.create() catch return;
        pty.close();
    }

    const duration_ns: u64 = @intCast(getTimeNs() - start);
    printResult(.{
        .name = "PTY create/destroy",
        .operations = operations,
        .duration_ns = duration_ns,
    });
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try runInitBenchmark(allocator);
    try runFdBenchmark(allocator);
    try runTimerBenchmark(allocator);
    try runPollBenchmark(allocator);
    try runTerminalBenchmark();
}
