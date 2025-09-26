//! Advanced timer features for ZigZag
//! High-resolution timers, timer statistics, and context callbacks

const std = @import("std");
const builtin = @import("builtin");
const Timer = @import("root.zig").Timer;
const TimerType = @import("root.zig").TimerType;

/// High-resolution timer using platform-specific mechanisms
pub const HighResTimer = struct {
    start_time: u64,
    frequency: u64,

    pub fn init() HighResTimer {
        return HighResTimer{
            .start_time = getHighResTime(),
            .frequency = getFrequency(),
        };
    }

    pub fn elapsed(self: HighResTimer) u64 {
        return getHighResTime() - self.start_time;
    }

    pub fn elapsedNanos(self: HighResTimer) u64 {
        const ticks = self.elapsed();
        return (ticks * std.time.ns_per_s) / self.frequency;
    }

    pub fn elapsedMicros(self: HighResTimer) u64 {
        return self.elapsedNanos() / std.time.ns_per_us;
    }

    pub fn elapsedMillis(self: HighResTimer) u64 {
        return self.elapsedNanos() / std.time.ns_per_ms;
    }

    fn getHighResTime() u64 {
        return switch (builtin.os.tag) {
            .windows => blk: {
                var counter: i64 = undefined;
                _ = std.os.windows.kernel32.QueryPerformanceCounter(&counter);
                break :blk @bitCast(counter);
            },
            .linux => blk: {
                var ts: std.os.linux.timespec = undefined;
                _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC_RAW, &ts);
                break :blk @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
            },
            .macos, .ios => blk: {
                break :blk std.c.mach_absolute_time();
            },
            else => @intCast(std.time.nanoTimestamp()),
        };
    }

    fn getFrequency() u64 {
        return switch (builtin.os.tag) {
            .windows => blk: {
                var frequency: i64 = undefined;
                _ = std.os.windows.kernel32.QueryPerformanceFrequency(&frequency);
                break :blk @bitCast(frequency);
            },
            .linux => std.time.ns_per_s,
            .macos, .ios => blk: {
                var info: std.c.mach_timebase_info_data_t = undefined;
                _ = std.c.mach_timebase_info(&info);
                break :blk (std.time.ns_per_s * info.denom) / info.numer;
            },
            else => std.time.ns_per_s,
        };
    }
};

/// Timer statistics and monitoring
pub const TimerStats = struct {
    total_timers_created: u64 = 0,
    total_timers_fired: u64 = 0,
    total_timers_cancelled: u64 = 0,

    // Accuracy tracking
    accuracy_sum_ns: u64 = 0,
    accuracy_count: u64 = 0,
    max_drift_ns: u64 = 0,
    min_drift_ns: u64 = std.math.maxInt(u64),

    // Performance tracking
    total_callback_time_ns: u64 = 0,
    max_callback_time_ns: u64 = 0,
    callback_count: u64 = 0,

    // Timer wheel metrics
    wheel_advances: u64 = 0,
    cascade_operations: u64 = 0,
    rehash_operations: u64 = 0,

    pub fn recordTimerCreated(self: *TimerStats) void {
        self.total_timers_created += 1;
    }

    pub fn recordTimerFired(self: *TimerStats, expected_time: i64, actual_time: i64) void {
        self.total_timers_fired += 1;

        // Calculate accuracy
        const drift = @abs(actual_time - expected_time);
        self.accuracy_sum_ns += @as(u64, @intCast(drift));
        self.accuracy_count += 1;
        self.max_drift_ns = @max(self.max_drift_ns, @as(u64, @intCast(drift)));
        self.min_drift_ns = @min(self.min_drift_ns, @as(u64, @intCast(drift)));
    }

    pub fn recordTimerCancelled(self: *TimerStats) void {
        self.total_timers_cancelled += 1;
    }

    pub fn recordCallbackExecution(self: *TimerStats, execution_time_ns: u64) void {
        self.total_callback_time_ns += execution_time_ns;
        self.max_callback_time_ns = @max(self.max_callback_time_ns, execution_time_ns);
        self.callback_count += 1;
    }

    pub fn recordWheelAdvance(self: *TimerStats) void {
        self.wheel_advances += 1;
    }

    pub fn recordCascade(self: *TimerStats) void {
        self.cascade_operations += 1;
    }

    pub fn recordRehash(self: *TimerStats) void {
        self.rehash_operations += 1;
    }

    pub fn getAverageAccuracy(self: *const TimerStats) f64 {
        if (self.accuracy_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.accuracy_sum_ns)) / @as(f64, @floatFromInt(self.accuracy_count));
    }

    pub fn getAverageCallbackTime(self: *const TimerStats) f64 {
        if (self.callback_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_callback_time_ns)) / @as(f64, @floatFromInt(self.callback_count));
    }

    pub fn getCancellationRate(self: *const TimerStats) f64 {
        if (self.total_timers_created == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_timers_cancelled)) / @as(f64, @floatFromInt(self.total_timers_created));
    }

    pub fn format(
        self: TimerStats,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Timer Statistics:\n", .{});
        try writer.print("  Created: {d}, Fired: {d}, Cancelled: {d}\n", .{
            self.total_timers_created,
            self.total_timers_fired,
            self.total_timers_cancelled,
        });
        try writer.print("  Cancellation rate: {d:.1}%\n", .{self.getCancellationRate() * 100.0});
        try writer.print("  Average accuracy: {d:.2} μs\n", .{self.getAverageAccuracy() / 1000.0});
        try writer.print("  Max drift: {d:.2} μs\n", .{@as(f64, @floatFromInt(self.max_drift_ns)) / 1000.0});
        try writer.print("  Average callback time: {d:.2} μs\n", .{self.getAverageCallbackTime() / 1000.0});
        try writer.print("  Wheel advances: {d}, Cascades: {d}\n", .{ self.wheel_advances, self.cascade_operations });
    }
};

/// Timer context for advanced callback functionality
pub const TimerContext = struct {
    timer_id: u32,
    user_data: ?*anyopaque,
    creation_time: i64,
    expected_fire_time: i64,
    actual_fire_time: i64 = 0,
    fire_count: u32 = 0,
    stats: *TimerStats,

    pub fn init(timer_id: u32, user_data: ?*anyopaque, fire_time: i64, stats: *TimerStats) TimerContext {
        return TimerContext{
            .timer_id = timer_id,
            .user_data = user_data,
            .creation_time = std.time.milliTimestamp(),
            .expected_fire_time = fire_time,
            .stats = stats,
        };
    }

    pub fn onFire(self: *TimerContext) void {
        self.actual_fire_time = std.time.milliTimestamp();
        self.fire_count += 1;
        self.stats.recordTimerFired(self.expected_fire_time, self.actual_fire_time);
    }

    pub fn getDrift(self: *const TimerContext) i64 {
        if (self.actual_fire_time == 0) return 0;
        return self.actual_fire_time - self.expected_fire_time;
    }

    pub fn getAge(self: *const TimerContext) i64 {
        return std.time.milliTimestamp() - self.creation_time;
    }
};

/// Advanced timer with context and statistics
pub const AdvancedTimer = struct {
    base_timer: Timer,
    context: TimerContext,
    high_res_creation: HighResTimer,
    callback_with_context: ?*const fn (*TimerContext) void = null,

    pub fn init(
        id: u32,
        deadline: i64,
        interval: ?u64,
        timer_type: TimerType,
        user_data: ?*anyopaque,
        stats: *TimerStats,
    ) AdvancedTimer {
        const base_callback = struct {
            pub fn defaultCallback(data: ?*anyopaque) void {
                _ = data;
                // Default empty callback
            }
        }.defaultCallback;

        return AdvancedTimer{
            .base_timer = Timer{
                .id = id,
                .deadline = deadline,
                .interval = interval,
                .type = timer_type,
                .callback = base_callback,
                .user_data = user_data,
            },
            .context = TimerContext.init(id, user_data, deadline, stats),
            .high_res_creation = HighResTimer.init(),
        };
    }

    pub fn setCallback(self: *AdvancedTimer, callback: *const fn (*TimerContext) void) void {
        self.callback_with_context = callback;
    }

    pub fn fire(self: *AdvancedTimer) void {
        const callback_timer = HighResTimer.init();

        // Update context
        self.context.onFire();

        // Call user callback if set
        if (self.callback_with_context) |callback| {
            callback(&self.context);
        }

        // Record callback execution time
        const execution_time = callback_timer.elapsedNanos();
        self.context.stats.recordCallbackExecution(execution_time);
    }

    pub fn cancel(self: *AdvancedTimer) void {
        self.context.stats.recordTimerCancelled();
    }

    pub fn getAccuracy(self: *const AdvancedTimer) i64 {
        return self.context.getDrift();
    }

    pub fn getLifetime(self: *const AdvancedTimer) u64 {
        return self.high_res_creation.elapsedNanos();
    }
};

/// Timer registry for managing multiple advanced timers
pub const TimerRegistry = struct {
    allocator: std.mem.Allocator,
    timers: std.AutoHashMap(u32, *AdvancedTimer),
    stats: TimerStats,
    next_timer_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) TimerRegistry {
        return TimerRegistry{
            .allocator = allocator,
            .timers = std.AutoHashMap(u32, *AdvancedTimer).init(allocator),
            .stats = TimerStats{},
        };
    }

    pub fn deinit(self: *TimerRegistry) void {
        // Clean up all timers
        var iter = self.timers.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.timers.deinit();
    }

    pub fn createTimer(
        self: *TimerRegistry,
        deadline: i64,
        interval: ?u64,
        timer_type: TimerType,
        user_data: ?*anyopaque,
    ) !*AdvancedTimer {
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const timer = try self.allocator.create(AdvancedTimer);
        timer.* = AdvancedTimer.init(timer_id, deadline, interval, timer_type, user_data, &self.stats);

        try self.timers.put(timer_id, timer);
        self.stats.recordTimerCreated();

        return timer;
    }

    pub fn removeTimer(self: *TimerRegistry, timer_id: u32) ?*AdvancedTimer {
        if (self.timers.fetchRemove(timer_id)) |kv| {
            return kv.value;
        }
        return null;
    }

    pub fn getTimer(self: *const TimerRegistry, timer_id: u32) ?*AdvancedTimer {
        return self.timers.get(timer_id);
    }

    pub fn fireTimer(self: *TimerRegistry, timer_id: u32) !void {
        if (self.getTimer(timer_id)) |timer| {
            timer.fire();
        } else {
            return error.TimerNotFound;
        }
    }

    pub fn cancelTimer(self: *TimerRegistry, timer_id: u32) !void {
        if (self.removeTimer(timer_id)) |timer| {
            timer.cancel();
            self.allocator.destroy(timer);
        } else {
            return error.TimerNotFound;
        }
    }

    pub fn getStatistics(self: *const TimerRegistry) TimerStats {
        return self.stats;
    }

    pub fn getActiveCount(self: *const TimerRegistry) usize {
        return self.timers.count();
    }

    /// Clean up expired one-shot timers
    pub fn cleanupExpired(self: *TimerRegistry) void {
        const now = std.time.milliTimestamp();
        var to_remove = std.ArrayList(u32).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.timers.iterator();
        while (iter.next()) |entry| {
            const timer = entry.value_ptr.*;
            if (timer.base_timer.type == .one_shot and timer.base_timer.deadline < now) {
                to_remove.append(timer.base_timer.id) catch continue;
            }
        }

        for (to_remove.items) |timer_id| {
            self.cancelTimer(timer_id) catch {};
        }
    }
};

/// Timer scheduling algorithms
pub const TimerScheduler = struct {
    /// Deadline-based priority scheduling
    pub fn deadlinePriority(timer_a: *const AdvancedTimer, timer_b: *const AdvancedTimer) bool {
        return timer_a.base_timer.deadline < timer_b.base_timer.deadline;
    }

    /// Fair scheduling considering timer age
    pub fn fairScheduling(timer_a: *const AdvancedTimer, timer_b: *const AdvancedTimer) bool {
        const age_a = timer_a.getLifetime();
        const age_b = timer_b.getLifetime();

        // If ages are similar, use deadline
        if (@abs(@as(i64, @intCast(age_a)) - @as(i64, @intCast(age_b))) < 1000000) { // 1ms
            return timer_a.base_timer.deadline < timer_b.base_timer.deadline;
        }

        // Otherwise, prefer older timers
        return age_a > age_b;
    }

    /// Load-balanced scheduling
    pub fn loadBalanced(timer_a: *const AdvancedTimer, timer_b: *const AdvancedTimer) bool {
        // Consider callback execution time for load balancing
        const stats_a = timer_a.context.stats;
        const stats_b = timer_b.context.stats;

        const avg_time_a = stats_a.getAverageCallbackTime();
        const avg_time_b = stats_b.getAverageCallbackTime();

        // Prefer timers with shorter callback times when load is high
        return avg_time_a < avg_time_b;
    }
};

/// Benchmarking and profiling for timers
pub const TimerBenchmark = struct {
    /// Measure timer accuracy over multiple iterations
    pub fn measureAccuracy(
        allocator: std.mem.Allocator,
        target_interval_ms: u64,
        iterations: u32,
    ) !TimerStats {
        var registry = TimerRegistry.init(allocator);
        defer registry.deinit();

        var results = TimerStats{};

        for (0..iterations) |_| {
            const start_time = std.time.milliTimestamp();
            const target_time = start_time + @as(i64, @intCast(target_interval_ms));

            const timer = try registry.createTimer(
                target_time,
                null,
                .one_shot,
                null,
            );

            // Simulate timer firing
            std.time.sleep(target_interval_ms * std.time.ns_per_ms);
            const actual_time = std.time.milliTimestamp();

            results.recordTimerFired(target_time, actual_time);
            try registry.cancelTimer(timer.base_timer.id);
        }

        return results;
    }

    /// Benchmark callback execution overhead
    pub fn benchmarkCallbacks(
        allocator: std.mem.Allocator,
        iterations: u32,
    ) !f64 {
        var registry = TimerRegistry.init(allocator);
        defer registry.deinit();

        const callback = struct {
            pub fn benchCallback(ctx: *TimerContext) void {
                _ = ctx;
                // Minimal callback for benchmarking
            }
        }.benchCallback;

        var total_time: u64 = 0;

        for (0..iterations) |_| {
            const timer = try registry.createTimer(
                std.time.milliTimestamp(),
                null,
                .one_shot,
                null,
            );
            timer.setCallback(callback);

            const start = HighResTimer.init();
            timer.fire();
            total_time += start.elapsedNanos();

            try registry.cancelTimer(timer.base_timer.id);
        }

        return @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    }
};

test "High-resolution timer" {
    const timer = HighResTimer.init();
    std.time.sleep(1_000_000); // 1ms
    const elapsed = timer.elapsedMicros();

    // Should be roughly 1000 microseconds, allow variance
    try std.testing.expect(elapsed >= 500 and elapsed <= 2000);
}

test "Timer statistics" {
    var stats = TimerStats{};

    // Record some events
    stats.recordTimerCreated();
    stats.recordTimerCreated();
    stats.recordTimerFired(1000, 1050); // 50ns drift
    stats.recordTimerCancelled();

    try std.testing.expectEqual(@as(u64, 2), stats.total_timers_created);
    try std.testing.expectEqual(@as(u64, 1), stats.total_timers_fired);
    try std.testing.expectEqual(@as(u64, 1), stats.total_timers_cancelled);
    try std.testing.expectEqual(@as(f64, 50.0), stats.getAverageAccuracy());
    try std.testing.expectEqual(@as(f64, 0.5), stats.getCancellationRate());
}

test "Timer registry operations" {
    const allocator = std.testing.allocator;

    var registry = TimerRegistry.init(allocator);
    defer registry.deinit();

    // Create timer
    const timer = try registry.createTimer(
        std.time.milliTimestamp() + 1000,
        null,
        .one_shot,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), registry.getActiveCount());

    // Fire timer
    try registry.fireTimer(timer.base_timer.id);

    // Cancel timer
    try registry.cancelTimer(timer.base_timer.id);
    try std.testing.expectEqual(@as(usize, 0), registry.getActiveCount());
}

test "Timer context functionality" {
    var stats = TimerStats{};
    var context = TimerContext.init(1, null, 1000, &stats);

    try std.testing.expectEqual(@as(u32, 1), context.timer_id);
    try std.testing.expectEqual(@as(i64, 1000), context.expected_fire_time);
    try std.testing.expectEqual(@as(u32, 0), context.fire_count);

    context.onFire();
    try std.testing.expectEqual(@as(u32, 1), context.fire_count);
    try std.testing.expect(context.actual_fire_time > 0);
}