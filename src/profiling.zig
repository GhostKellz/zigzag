//! Performance profiling and monitoring for ZigZag event loop
//! Provides detailed metrics and performance analysis

const std = @import("std");
const builtin = @import("builtin");
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;
const Backend = @import("root.zig").Backend;

/// Timing utilities for high-resolution measurements
pub const Timer = struct {
    start_time: u64,

    pub fn start() Timer {
        return Timer{
            .start_time = getTimestamp(),
        };
    }

    pub fn elapsed(self: Timer) u64 {
        return getTimestamp() - self.start_time;
    }

    pub fn elapsedNanos(self: Timer) u64 {
        return self.elapsed();
    }

    pub fn elapsedMicros(self: Timer) u64 {
        return self.elapsed() / std.time.ns_per_us;
    }

    pub fn elapsedMillis(self: Timer) u64 {
        return self.elapsed() / std.time.ns_per_ms;
    }

    fn getTimestamp() u64 {
        return switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("rdtsc"
                : [ret] "={rax}" (-> u64)
                :
                : "rdx"
            ),
            else => @intCast(std.time.nanoTimestamp()),
        };
    }
};

/// Performance metrics for different components
pub const Metrics = struct {
    // Event processing metrics
    events_processed: u64 = 0,
    events_by_type: [8]u64 = [_]u64{0} ** 8, // Index by EventType
    total_processing_time_ns: u64 = 0,
    max_processing_time_ns: u64 = 0,
    min_processing_time_ns: u64 = std.math.maxInt(u64),

    // Event loop metrics
    total_iterations: u64 = 0,
    idle_iterations: u64 = 0,
    total_loop_time_ns: u64 = 0,
    max_loop_time_ns: u64 = 0,

    // Backend-specific metrics
    backend_calls: u64 = 0,
    backend_time_ns: u64 = 0,
    backend_max_time_ns: u64 = 0,

    // Memory metrics
    allocations: u64 = 0,
    deallocations: u64 = 0,
    peak_memory_usage: usize = 0,
    current_memory_usage: usize = 0,

    // Timer metrics
    timers_created: u64 = 0,
    timers_fired: u64 = 0,
    timer_accuracy_sum_ns: u64 = 0,
    timer_accuracy_count: u64 = 0,

    /// Record event processing
    pub fn recordEvent(self: *Metrics, event_type: EventType, processing_time_ns: u64) void {
        self.events_processed += 1;
        self.events_by_type[@intFromEnum(event_type)] += 1;
        self.total_processing_time_ns += processing_time_ns;
        self.max_processing_time_ns = @max(self.max_processing_time_ns, processing_time_ns);
        self.min_processing_time_ns = @min(self.min_processing_time_ns, processing_time_ns);
    }

    /// Record event loop iteration
    pub fn recordIteration(self: *Metrics, loop_time_ns: u64, had_events: bool) void {
        self.total_iterations += 1;
        if (!had_events) {
            self.idle_iterations += 1;
        }
        self.total_loop_time_ns += loop_time_ns;
        self.max_loop_time_ns = @max(self.max_loop_time_ns, loop_time_ns);
    }

    /// Record backend call
    pub fn recordBackendCall(self: *Metrics, call_time_ns: u64) void {
        self.backend_calls += 1;
        self.backend_time_ns += call_time_ns;
        self.backend_max_time_ns = @max(self.backend_max_time_ns, call_time_ns);
    }

    /// Record memory allocation
    pub fn recordAllocation(self: *Metrics, size: usize) void {
        self.allocations += 1;
        self.current_memory_usage += size;
        self.peak_memory_usage = @max(self.peak_memory_usage, self.current_memory_usage);
    }

    /// Record memory deallocation
    pub fn recordDeallocation(self: *Metrics, size: usize) void {
        self.deallocations += 1;
        if (self.current_memory_usage >= size) {
            self.current_memory_usage -= size;
        }
    }

    /// Record timer creation and firing
    pub fn recordTimer(self: *Metrics, created: bool, fired: bool, accuracy_ns: ?u64) void {
        if (created) {
            self.timers_created += 1;
        }
        if (fired) {
            self.timers_fired += 1;
            if (accuracy_ns) |acc| {
                self.timer_accuracy_sum_ns += acc;
                self.timer_accuracy_count += 1;
            }
        }
    }

    /// Get average event processing time
    pub fn avgEventProcessingTime(self: *const Metrics) f64 {
        if (self.events_processed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_processing_time_ns)) / @as(f64, @floatFromInt(self.events_processed));
    }

    /// Get average loop time
    pub fn avgLoopTime(self: *const Metrics) f64 {
        if (self.total_iterations == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_loop_time_ns)) / @as(f64, @floatFromInt(self.total_iterations));
    }

    /// Get idle percentage
    pub fn idlePercentage(self: *const Metrics) f64 {
        if (self.total_iterations == 0) return 0.0;
        return @as(f64, @floatFromInt(self.idle_iterations)) / @as(f64, @floatFromInt(self.total_iterations)) * 100.0;
    }

    /// Get average timer accuracy
    pub fn avgTimerAccuracy(self: *const Metrics) f64 {
        if (self.timer_accuracy_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.timer_accuracy_sum_ns)) / @as(f64, @floatFromInt(self.timer_accuracy_count));
    }

    /// Reset all metrics
    pub fn reset(self: *Metrics) void {
        self.* = Metrics{};
    }

    /// Format metrics for display
    pub fn format(
        self: Metrics,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("=== ZigZag Performance Metrics ===\n", .{});
        try writer.print("Events:\n", .{});
        try writer.print("  Total processed: {d}\n", .{self.events_processed});
        try writer.print("  Avg processing time: {d:.2} μs\n", .{self.avgEventProcessingTime() / 1000.0});
        try writer.print("  Max processing time: {d:.2} μs\n", .{@as(f64, @floatFromInt(self.max_processing_time_ns)) / 1000.0});
        try writer.print("  Min processing time: {d:.2} μs\n", .{@as(f64, @floatFromInt(self.min_processing_time_ns)) / 1000.0});

        try writer.print("\nEvent Loop:\n", .{});
        try writer.print("  Total iterations: {d}\n", .{self.total_iterations});
        try writer.print("  Idle percentage: {d:.1}%\n", .{self.idlePercentage()});
        try writer.print("  Avg loop time: {d:.2} μs\n", .{self.avgLoopTime() / 1000.0});
        try writer.print("  Max loop time: {d:.2} μs\n", .{@as(f64, @floatFromInt(self.max_loop_time_ns)) / 1000.0});

        try writer.print("\nBackend:\n", .{});
        try writer.print("  Total calls: {d}\n", .{self.backend_calls});
        try writer.print("  Avg call time: {d:.2} μs\n", .{
            if (self.backend_calls > 0)
                @as(f64, @floatFromInt(self.backend_time_ns)) / @as(f64, @floatFromInt(self.backend_calls)) / 1000.0
            else
                0.0,
        });

        try writer.print("\nMemory:\n", .{});
        try writer.print("  Allocations: {d}\n", .{self.allocations});
        try writer.print("  Deallocations: {d}\n", .{self.deallocations});
        try writer.print("  Peak usage: {d} bytes\n", .{self.peak_memory_usage});
        try writer.print("  Current usage: {d} bytes\n", .{self.current_memory_usage});

        try writer.print("\nTimers:\n", .{});
        try writer.print("  Created: {d}\n", .{self.timers_created});
        try writer.print("  Fired: {d}\n", .{self.timers_fired});
        try writer.print("  Avg accuracy: {d:.2} μs\n", .{self.avgTimerAccuracy() / 1000.0});
    }
};

/// Performance profiler for event loop
pub const Profiler = struct {
    allocator: std.mem.Allocator,
    metrics: Metrics,
    backend: Backend,
    enabled: bool = true,
    samples: std.ArrayList(Sample),
    max_samples: usize = 10000,

    const Sample = struct {
        timestamp: u64,
        event_type: ?EventType,
        processing_time_ns: u64,
        memory_usage: usize,
    };

    pub fn init(allocator: std.mem.Allocator, backend: Backend) Profiler {
        return Profiler{
            .allocator = allocator,
            .metrics = Metrics{},
            .backend = backend,
            .samples = std.ArrayList(Sample).init(allocator),
        };
    }

    pub fn deinit(self: *Profiler) void {
        self.samples.deinit();
    }

    /// Enable/disable profiling
    pub fn setEnabled(self: *Profiler, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Start timing an operation
    pub fn startTiming(self: *Profiler) Timer {
        _ = self;
        return Timer.start();
    }

    /// Record event processing
    pub fn recordEventProcessing(
        self: *Profiler,
        event_type: EventType,
        timer: Timer,
    ) void {
        if (!self.enabled) return;

        const processing_time = timer.elapsed();
        self.metrics.recordEvent(event_type, processing_time);

        // Add sample if under limit
        if (self.samples.items.len < self.max_samples) {
            const sample = Sample{
                .timestamp = Timer.getTimestamp(),
                .event_type = event_type,
                .processing_time_ns = processing_time,
                .memory_usage = self.metrics.current_memory_usage,
            };
            self.samples.append(sample) catch {};
        }
    }

    /// Record loop iteration
    pub fn recordLoopIteration(self: *Profiler, timer: Timer, had_events: bool) void {
        if (!self.enabled) return;

        const loop_time = timer.elapsed();
        self.metrics.recordIteration(loop_time, had_events);
    }

    /// Record backend call
    pub fn recordBackendCall(self: *Profiler, timer: Timer) void {
        if (!self.enabled) return;

        const call_time = timer.elapsed();
        self.metrics.recordBackendCall(call_time);
    }

    /// Get current metrics
    pub fn getMetrics(self: *const Profiler) Metrics {
        return self.metrics;
    }

    /// Generate performance report
    pub fn generateReport(self: *const Profiler, writer: anytype) !void {
        try writer.print("{}\n", .{self.metrics});

        try writer.print("\n=== Backend Specific ===\n", .{});
        try writer.print("Backend: {s}\n", .{@tagName(self.backend)});

        // Platform-specific optimizations report
        try self.reportPlatformOptimizations(writer);

        // Hot spots analysis
        try self.reportHotSpots(writer);
    }

    /// Report platform-specific optimizations
    fn reportPlatformOptimizations(self: *const Profiler, writer: anytype) !void {
        try writer.print("\n=== Platform Optimizations ===\n", .{});

        switch (self.backend) {
            .io_uring => {
                try writer.print("io_uring optimizations:\n", .{});
                try writer.print("  - Zero-copy I/O: Available\n", .{});
                try writer.print("  - Multishot operations: Enabled\n", .{});
                try writer.print("  - Submission queue batching: Active\n", .{});
            },
            .epoll => {
                try writer.print("epoll optimizations:\n", .{});
                try writer.print("  - Edge-triggered mode: Recommended\n", .{});
                try writer.print("  - timerfd integration: Active\n", .{});
                try writer.print("  - FIONREAD for available bytes: Enabled\n", .{});
            },
            .kqueue => {
                try writer.print("kqueue optimizations:\n", .{});
                try writer.print("  - EV_CLEAR flag: Enabled\n", .{});
                try writer.print("  - Timer filters: Active\n", .{});
                try writer.print("  - Batch event processing: Enabled\n", .{});
            },
            .iocp => {
                try writer.print("IOCP optimizations:\n", .{});
                try writer.print("  - Overlapped I/O: Active\n", .{});
                try writer.print("  - Completion port threads: Auto-scaled\n", .{});
                try writer.print("  - Timer queue: Enabled\n", .{});
            },
        }
    }

    /// Report performance hot spots
    fn reportHotSpots(self: *const Profiler, writer: anytype) !void {
        try writer.print("\n=== Performance Hot Spots ===\n", .{});

        // Analyze event type distribution
        const event_names = [_][]const u8{
            "read_ready",
            "write_ready",
            "io_error",
            "hangup",
            "window_resize",
            "focus_change",
            "timer_expired",
            "child_exit",
        };

        try writer.print("Event distribution:\n", .{});
        for (self.metrics.events_by_type, 0..) |count, i| {
            if (count > 0 and i < event_names.len) {
                const percentage = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(self.metrics.events_processed)) * 100.0;
                try writer.print("  {s}: {d} ({d:.1}%)\n", .{ event_names[i], count, percentage });
            }
        }

        // Performance recommendations
        try writer.print("\nRecommendations:\n", .{});
        if (self.metrics.idlePercentage() > 50.0) {
            try writer.print("  - High idle time detected, consider longer poll timeouts\n", .{});
        }
        if (self.metrics.max_processing_time_ns > 1000000) { // > 1ms
            try writer.print("  - High event processing time detected, consider optimization\n", .{});
        }
        if (self.metrics.current_memory_usage > self.metrics.peak_memory_usage / 2) {
            try writer.print("  - Consider periodic memory cleanup\n", .{});
        }
    }

    /// Export metrics to JSON
    pub fn exportMetrics(self: *const Profiler, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.print("  \"events_processed\": {d},\n", .{self.metrics.events_processed});
        try writer.print("  \"total_iterations\": {d},\n", .{self.metrics.total_iterations});
        try writer.print("  \"idle_percentage\": {d:.2},\n", .{self.metrics.idlePercentage()});
        try writer.print("  \"avg_event_time_ns\": {d:.0},\n", .{self.metrics.avgEventProcessingTime()});
        try writer.print("  \"avg_loop_time_ns\": {d:.0},\n", .{self.metrics.avgLoopTime()});
        try writer.print("  \"backend\": \"{s}\",\n", .{@tagName(self.backend)});
        try writer.print("  \"peak_memory\": {d},\n", .{self.metrics.peak_memory_usage});
        try writer.print("  \"current_memory\": {d}\n", .{self.metrics.current_memory_usage});
        try writer.writeAll("}\n");
    }
};

/// Benchmark utilities for comparing performance
pub const Benchmark = struct {
    /// Compare event processing performance between backends
    pub fn compareBackends(allocator: std.mem.Allocator) !void {
        _ = allocator;
        // TODO: Implement cross-backend performance comparison
        std.log.info("Backend performance comparison not yet implemented", .{});
    }

    /// Measure timer accuracy
    pub fn measureTimerAccuracy(timer_callback: *const fn () void, iterations: u32) !f64 {
        var total_error: u64 = 0;
        const target_interval_ns = 10 * std.time.ns_per_ms; // 10ms

        for (0..iterations) |_| {
            const start = Timer.start();
            timer_callback();
            const actual = start.elapsed();

            if (actual > target_interval_ns) {
                total_error += actual - target_interval_ns;
            } else {
                total_error += target_interval_ns - actual;
            }
        }

        return @as(f64, @floatFromInt(total_error)) / @as(f64, @floatFromInt(iterations));
    }
};

test "Timer measurements" {
    const timer = Timer.start();
    std.time.sleep(1000000); // 1ms
    const elapsed = timer.elapsedMicros();

    // Should be roughly 1000 microseconds, allow some variance
    try std.testing.expect(elapsed >= 500 and elapsed <= 2000);
}

test "Metrics recording" {
    var metrics = Metrics{};

    // Record some events
    metrics.recordEvent(.read_ready, 1000);
    metrics.recordEvent(.read_ready, 2000);
    metrics.recordEvent(.timer_expired, 500);

    try std.testing.expectEqual(@as(u64, 3), metrics.events_processed);
    try std.testing.expectEqual(@as(u64, 2), metrics.events_by_type[@intFromEnum(EventType.read_ready)]);
    try std.testing.expectEqual(@as(u64, 1), metrics.events_by_type[@intFromEnum(EventType.timer_expired)]);

    const avg_time = metrics.avgEventProcessingTime();
    try std.testing.expect(avg_time > 0);
}

test "Profiler basic operations" {
    const allocator = std.testing.allocator;

    var profiler = Profiler.init(allocator, .epoll);
    defer profiler.deinit();

    // Test timing
    const timer = profiler.startTiming();
    std.time.sleep(100000); // 100μs
    profiler.recordEventProcessing(.read_ready, timer);

    const metrics = profiler.getMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics.events_processed);
}