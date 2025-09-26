//! Performance benchmarking and validation suite
//! Validates that ZigZag meets all performance targets

const std = @import("std");
const builtin = @import("builtin");
const time = std.time;

const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;
const Backend = @import("root.zig").Backend;
const Timer = @import("root.zig").Timer;
const TimerType = @import("root.zig").TimerType;

/// Performance targets as defined in TODO.md
pub const PerformanceTargets = struct {
    /// Sub-microsecond event processing
    pub const max_event_latency_ns: u64 = 1000; // 1 microsecond
    /// 1M+ events per second
    pub const min_events_per_second: u64 = 1_000_000;
    /// <1MB base memory usage
    pub const max_base_memory_mb: f64 = 1.0;
    /// <1% idle CPU usage
    pub const max_idle_cpu_percent: f64 = 1.0;
};

/// Benchmark results
pub const BenchmarkResults = struct {
    event_latency_ns: u64,
    events_per_second: u64,
    memory_usage_mb: f64,
    cpu_usage_percent: f64,
    test_duration_ms: u64,
    backend_used: Backend,

    pub fn meetsTargets(self: BenchmarkResults) bool {
        return self.event_latency_ns <= PerformanceTargets.max_event_latency_ns and
               self.events_per_second >= PerformanceTargets.min_events_per_second and
               self.memory_usage_mb <= PerformanceTargets.max_base_memory_mb and
               self.cpu_usage_percent <= PerformanceTargets.max_idle_cpu_percent;
    }

    pub fn printResults(self: BenchmarkResults) void {
        std.debug.print("\n=== Benchmark Results ===\n");
        std.debug.print("Backend: {s}\n", .{@tagName(self.backend_used)});
        std.debug.print("Event Latency: {d}ns (target: <{d}ns) {s}\n", .{
            self.event_latency_ns,
            PerformanceTargets.max_event_latency_ns,
            if (self.event_latency_ns <= PerformanceTargets.max_event_latency_ns) "✓" else "✗"
        });
        std.debug.print("Events/Second: {d} (target: >{d}) {s}\n", .{
            self.events_per_second,
            PerformanceTargets.min_events_per_second,
            if (self.events_per_second >= PerformanceTargets.min_events_per_second) "✓" else "✗"
        });
        std.debug.print("Memory Usage: {d:.2}MB (target: <{d:.1}MB) {s}\n", .{
            self.memory_usage_mb,
            PerformanceTargets.max_base_memory_mb,
            if (self.memory_usage_mb <= PerformanceTargets.max_base_memory_mb) "✓" else "✗"
        });
        std.debug.print("CPU Usage: {d:.2}% (target: <{d:.1}%) {s}\n", .{
            self.cpu_usage_percent,
            PerformanceTargets.max_idle_cpu_percent,
            if (self.cpu_usage_percent <= PerformanceTargets.max_idle_cpu_percent) "✓" else "✗"
        });
        std.debug.print("Test Duration: {d}ms\n", .{self.test_duration_ms});
        std.debug.print("Overall: {s}\n", .{if (self.meetsTargets()) "PASS ✓" else "FAIL ✗"});
    }
};

/// Memory monitoring utilities
const MemoryMonitor = struct {
    initial_rss: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !MemoryMonitor {
        return MemoryMonitor{
            .initial_rss = try getCurrentRSS(),
            .allocator = allocator,
        };
    }

    pub fn getCurrentUsageMB(self: MemoryMonitor) !f64 {
        const current_rss = try getCurrentRSS();
        const diff_bytes = current_rss - self.initial_rss;
        return @as(f64, @floatFromInt(diff_bytes)) / (1024.0 * 1024.0);
    }

    fn getCurrentRSS() !u64 {
        if (builtin.os.tag == .linux) {
            const file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return 0;
            defer file.close();

            var buf: [4096]u8 = undefined;
            const len = try file.readAll(&buf);
            const content = buf[0..len];

            var lines = std.mem.splitSequence(u8, content, "\n");
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "VmRSS:")) {
                    var parts = std.mem.splitSequence(u8, line, " ");
                    _ = parts.next(); // Skip "VmRSS:"
                    while (parts.next()) |part| {
                        if (part.len > 0 and std.ascii.isDigit(part[0])) {
                            const kb = std.fmt.parseInt(u64, part, 10) catch continue;
                            return kb * 1024; // Convert KB to bytes
                        }
                    }
                }
            }
        }
        return 0; // Fallback for unsupported platforms
    }
};

/// CPU monitoring utilities
const CPUMonitor = struct {
    start_time: i128,
    start_cpu_time: i128,

    pub fn init() CPUMonitor {
        return CPUMonitor{
            .start_time = time.nanoTimestamp(),
            .start_cpu_time = getCPUTime(),
        };
    }

    pub fn getCurrentUsagePercent(self: CPUMonitor) f64 {
        const end_time = time.nanoTimestamp();
        const end_cpu_time = getCPUTime();

        const wall_time = end_time - self.start_time;
        const cpu_time = end_cpu_time - self.start_cpu_time;

        if (wall_time <= 0) return 0.0;

        return (@as(f64, @floatFromInt(cpu_time)) / @as(f64, @floatFromInt(wall_time))) * 100.0;
    }

    fn getCPUTime() i128 {
        // Platform-specific CPU time measurement
        if (builtin.os.tag == .linux) {
            const file = std.fs.openFileAbsolute("/proc/self/stat", .{}) catch return 0;
            defer file.close();

            var buf: [1024]u8 = undefined;
            const len = file.readAll(&buf) catch return 0;
            const content = buf[0..len];

            var parts = std.mem.splitSequence(u8, content, " ");
            var i: u32 = 0;
            while (parts.next()) |part| {
                i += 1;
                if (i == 14) { // utime
                    const utime = std.fmt.parseInt(u64, part, 10) catch 0;
                    return @as(i128, @intCast(utime)) * 10_000_000; // Convert to nanoseconds (assuming 100Hz)
                }
            }
        }
        return time.nanoTimestamp(); // Fallback
    }
};

/// High-performance event latency benchmark
pub fn benchmarkEventLatency(allocator: std.mem.Allocator, backend: Backend) !BenchmarkResults {
    const test_duration_ms = 1000; // 1 second test
    const events_to_process = 100_000;

    var event_loop = try EventLoop.init(allocator, .{ .backend = backend });
    defer event_loop.deinit();

    // Create pipes for testing
    var pipes: [2]std.os.fd_t = undefined;
    try std.os.pipe(&pipes);
    defer std.os.close(pipes[0]);
    defer std.os.close(pipes[1]);

    try event_loop.addWatch(pipes[0], .{ .read = true });

    var memory_monitor = try MemoryMonitor.init(allocator);
    var cpu_monitor = CPUMonitor.init();

    var event_count: u64 = 0;
    var total_latency_ns: u64 = 0;
    var min_latency_ns: u64 = std.math.maxInt(u64);
    var max_latency_ns: u64 = 0;

    const start_time = time.nanoTimestamp();
    const end_time = start_time + (test_duration_ms * time.ns_per_ms);

    // Benchmark loop
    while (time.nanoTimestamp() < end_time and event_count < events_to_process) {
        // Trigger an event
        const event_start = time.nanoTimestamp();
        _ = std.os.write(pipes[1], "x") catch break;

        // Process event
        var events: [32]Event = undefined;
        const num_events = event_loop.wait(&events, 1) catch break;

        if (num_events > 0) {
            const event_end = time.nanoTimestamp();
            const latency = @as(u64, @intCast(event_end - event_start));

            total_latency_ns += latency;
            min_latency_ns = @min(min_latency_ns, latency);
            max_latency_ns = @max(max_latency_ns, latency);
            event_count += 1;
        }
    }

    const actual_duration_ms = @as(u64, @intCast((time.nanoTimestamp() - start_time) / time.ns_per_ms));
    const events_per_second = if (actual_duration_ms > 0) (event_count * 1000) / actual_duration_ms else 0;
    const avg_latency_ns = if (event_count > 0) total_latency_ns / event_count else 0;

    return BenchmarkResults{
        .event_latency_ns = avg_latency_ns,
        .events_per_second = events_per_second,
        .memory_usage_mb = try memory_monitor.getCurrentUsageMB(),
        .cpu_usage_percent = cpu_monitor.getCurrentUsagePercent(),
        .test_duration_ms = actual_duration_ms,
        .backend_used = backend,
    };
}

/// Throughput benchmark for high-volume event processing
pub fn benchmarkThroughput(allocator: std.mem.Allocator, backend: Backend) !BenchmarkResults {
    const test_duration_ms = 5000; // 5 second test
    const batch_size = 1000;

    var event_loop = try EventLoop.init(allocator, .{ .backend = backend });
    defer event_loop.deinit();

    // Create multiple pipes for parallel testing
    const num_pipes = 8;
    var pipes: [num_pipes][2]std.os.fd_t = undefined;
    defer {
        for (pipes) |pipe_pair| {
            std.os.close(pipe_pair[0]);
            std.os.close(pipe_pair[1]);
        }
    }

    for (&pipes) |*pipe_pair| {
        try std.os.pipe(pipe_pair);
        try event_loop.addWatch(pipe_pair[0], .{ .read = true });
    }

    var memory_monitor = try MemoryMonitor.init(allocator);
    var cpu_monitor = CPUMonitor.init();

    var total_events: u64 = 0;
    const start_time = time.nanoTimestamp();
    const end_time = start_time + (test_duration_ms * time.ns_per_ms);

    // High-throughput event generation and processing
    while (time.nanoTimestamp() < end_time) {
        // Generate batch of events
        for (pipes) |pipe_pair| {
            _ = std.os.write(pipe_pair[1], "x") catch continue;
        }

        // Process events in batches
        var events: [64]Event = undefined;
        const num_events = event_loop.wait(&events, 1) catch 0;
        total_events += num_events;

        // Simulate some work
        if (total_events % batch_size == 0) {
            std.time.sleep(100); // 100ns work simulation
        }
    }

    const actual_duration_ms = @as(u64, @intCast((time.nanoTimestamp() - start_time) / time.ns_per_ms));
    const events_per_second = if (actual_duration_ms > 0) (total_events * 1000) / actual_duration_ms else 0;

    // Estimate latency based on throughput (approximate)
    const estimated_latency_ns = if (events_per_second > 0) (time.ns_per_s / events_per_second) else 0;

    return BenchmarkResults{
        .event_latency_ns = estimated_latency_ns,
        .events_per_second = events_per_second,
        .memory_usage_mb = try memory_monitor.getCurrentUsageMB(),
        .cpu_usage_percent = cpu_monitor.getCurrentUsagePercent(),
        .test_duration_ms = actual_duration_ms,
        .backend_used = backend,
    };
}

/// Timer precision benchmark
pub fn benchmarkTimers(allocator: std.mem.Allocator, backend: Backend) !BenchmarkResults {
    var event_loop = try EventLoop.init(allocator, .{ .backend = backend });
    defer event_loop.deinit();

    var memory_monitor = try MemoryMonitor.init(allocator);
    var cpu_monitor = CPUMonitor.init();

    const timer_count = 1000;
    const timer_interval_ms = 10;
    var timer_events: u64 = 0;
    var total_precision_error_ns: u64 = 0;

    // Create multiple timers
    var timers = std.ArrayList(Timer).init(allocator);
    defer timers.deinit();

    const start_time = time.nanoTimestamp();

    for (0..timer_count) |_| {
        const timer_start = time.nanoTimestamp();
        const timer = try event_loop.addTimer(timer_interval_ms, .oneshot, struct {
            expected_time: i128,
            timer_events_ptr: *u64,
            total_error_ptr: *u64,

            pub fn callback(self: @This()) void {
                const actual_time = time.nanoTimestamp();
                const error_ns = @abs(actual_time - self.expected_time);
                self.total_error_ptr.* += @intCast(error_ns);
                self.timer_events_ptr.* += 1;
            }
        }{
            .expected_time = timer_start + (timer_interval_ms * time.ns_per_ms),
            .timer_events_ptr = &timer_events,
            .total_error_ptr = &total_precision_error_ns,
        });
        try timers.append(timer);
    }

    // Wait for all timers to fire
    const timeout_ms = (timer_interval_ms * 2) + 1000; // Give extra time
    const timeout_end = time.nanoTimestamp() + (timeout_ms * time.ns_per_ms);

    while (timer_events < timer_count and time.nanoTimestamp() < timeout_end) {
        var events: [32]Event = undefined;
        _ = event_loop.wait(&events, 10) catch break;
    }

    const actual_duration_ms = @as(u64, @intCast((time.nanoTimestamp() - start_time) / time.ns_per_ms));
    const avg_precision_error_ns = if (timer_events > 0) total_precision_error_ns / timer_events else 0;

    // Use timer precision as our latency metric
    return BenchmarkResults{
        .event_latency_ns = avg_precision_error_ns,
        .events_per_second = if (actual_duration_ms > 0) (timer_events * 1000) / actual_duration_ms else 0,
        .memory_usage_mb = try memory_monitor.getCurrentUsageMB(),
        .cpu_usage_percent = cpu_monitor.getCurrentUsagePercent(),
        .test_duration_ms = actual_duration_ms,
        .backend_used = backend,
    };
}

/// Run comprehensive benchmark suite
pub fn runBenchmarkSuite(allocator: std.mem.Allocator) !void {
    std.debug.print("\n🚀 ZigZag RC1 Performance Validation Suite\n");
    std.debug.print("==========================================\n");

    const backends = [_]Backend{ .epoll, .io_uring, .kqueue };

    var all_passed = true;

    for (backends) |backend| {
        std.debug.print("\n--- Testing Backend: {s} ---\n", .{@tagName(backend)});

        // Skip backends not available on this platform
        var event_loop = EventLoop.init(allocator, .{ .backend = backend }) catch |err| {
            std.debug.print("Backend {s} not available: {}\n", .{ @tagName(backend), err });
            continue;
        };
        event_loop.deinit();

        // Run latency benchmark
        std.debug.print("\n1. Event Latency Benchmark:\n");
        const latency_results = try benchmarkEventLatency(allocator, backend);
        latency_results.printResults();
        if (!latency_results.meetsTargets()) all_passed = false;

        // Run throughput benchmark
        std.debug.print("\n2. Throughput Benchmark:\n");
        const throughput_results = try benchmarkThroughput(allocator, backend);
        throughput_results.printResults();
        if (!throughput_results.meetsTargets()) all_passed = false;

        // Run timer benchmark
        std.debug.print("\n3. Timer Precision Benchmark:\n");
        const timer_results = try benchmarkTimers(allocator, backend);
        timer_results.printResults();
        if (!timer_results.meetsTargets()) all_passed = false;

        std.debug.print("\n" ++ "="*50 ++ "\n");
    }

    std.debug.print("\n🎯 FINAL RESULT: {s}\n", .{if (all_passed) "ALL BENCHMARKS PASSED ✓" else "SOME BENCHMARKS FAILED ✗"});

    if (all_passed) {
        std.debug.print("\n✅ ZigZag meets all RC1 performance targets!\n");
        std.debug.print("Ready for production deployment.\n");
    } else {
        std.debug.print("\n⚠️  Some performance targets not met.\n");
        std.debug.print("Review failed benchmarks and optimize accordingly.\n");
    }
}

test "benchmark suite compilation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test that benchmark functions compile and can be called
    _ = try MemoryMonitor.init(allocator);
    _ = CPUMonitor.init();

    // Test performance targets
    const results = BenchmarkResults{
        .event_latency_ns = 500,
        .events_per_second = 1_500_000,
        .memory_usage_mb = 0.8,
        .cpu_usage_percent = 0.5,
        .test_duration_ms = 1000,
        .backend_used = .epoll,
    };

    try std.testing.expect(results.meetsTargets());
}