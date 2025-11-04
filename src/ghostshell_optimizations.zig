//! Ghostshell-specific event loop optimizations
//!
//! Terminal emulator optimizations for maximum performance with NVIDIA GPUs
//! and high-throughput terminal operations.

const std = @import("std");
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventMask = @import("root.zig").EventMask;
const logging = @import("logging.zig");

/// Terminal frame timing for 60Hz+ rendering
pub const TerminalTiming = struct {
    target_fps: u32 = 120, // Match high-refresh displays
    frame_budget_ns: u64, // Calculated from FPS

    pub fn init(target_fps: u32) TerminalTiming {
        return .{
            .target_fps = target_fps,
            .frame_budget_ns = (1_000_000_000 / target_fps),
        };
    }

    /// Calculate if we're within frame budget
    pub fn isWithinBudget(self: TerminalTiming, elapsed_ns: u64) bool {
        return elapsed_ns < self.frame_budget_ns;
    }
};

/// PTY event batching for reduced syscalls
pub const PTYEventBatcher = struct {
    allocator: std.mem.Allocator,
    batch_buffer: std.ArrayList(u8),
    max_batch_size: usize = 16384, // 16KB batches
    last_flush_ns: i64 = 0,
    flush_interval_ns: i64 = 1_000_000, // 1ms max batch time

    pub fn init(allocator: std.mem.Allocator) !PTYEventBatcher {
        return .{
            .allocator = allocator,
            .batch_buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *PTYEventBatcher) void {
        self.batch_buffer.deinit();
    }

    /// Add data to batch
    pub fn addData(self: *PTYEventBatcher, data: []const u8) !void {
        try self.batch_buffer.appendSlice(data);
    }

    /// Check if batch should be flushed
    pub fn shouldFlush(self: PTYEventBatcher) bool {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
        const now = @as(i64, @intCast(ts.sec * 1_000_000_000 + ts.nsec));
        const time_since_flush = now - self.last_flush_ns;

        return self.batch_buffer.items.len >= self.max_batch_size or
               time_since_flush >= self.flush_interval_ns;
    }

    /// Flush batch and return data
    pub fn flush(self: *PTYEventBatcher) []const u8 {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
        self.last_flush_ns = @as(i64, @intCast(ts.sec * 1_000_000_000 + ts.nsec));
        return self.batch_buffer.items;
    }

    /// Clear batch after processing
    pub fn clear(self: *PTYEventBatcher) void {
        self.batch_buffer.clearRetainingCapacity();
    }
};

/// Zero-copy rendering optimization
pub const RenderBufferPool = struct {
    allocator: std.mem.Allocator,
    free_buffers: std.ArrayList([]u8),
    buffer_size: usize = 1024 * 1024, // 1MB buffers
    max_buffers: usize = 4, // Pool size

    pub fn init(allocator: std.mem.Allocator) !RenderBufferPool {
        return .{
            .allocator = allocator,
            .free_buffers = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *RenderBufferPool) void {
        for (self.free_buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.free_buffers.deinit();
    }

    /// Acquire a buffer from pool
    pub fn acquire(self: *RenderBufferPool) ![]u8 {
        if (self.free_buffers.popOrNull()) |buffer| {
            return buffer;
        }

        // Allocate new buffer if pool is empty
        return try self.allocator.alloc(u8, self.buffer_size);
    }

    /// Release buffer back to pool
    pub fn release(self: *RenderBufferPool, buffer: []u8) !void {
        if (self.free_buffers.items.len < self.max_buffers) {
            try self.free_buffers.append(buffer);
        } else {
            self.allocator.free(buffer);
        }
    }
};

/// Terminal-specific event priorities
pub const TerminalEventPriority = enum(u8) {
    critical = 0, // Input events, must be immediate
    high = 1,     // PTY output, rendering
    normal = 2,   // Resize, focus events
    low = 3,      // Background operations

    pub fn fromEventType(event_type: @import("root.zig").EventType) TerminalEventPriority {
        return switch (event_type) {
            .read_ready, .write_ready => .critical,
            .window_resize => .normal,
            .timer_expired => .high,
            else => .low,
        };
    }
};

/// Ghostshell event loop extensions
pub const GhostshellExtensions = struct {
    loop: *EventLoop,
    timing: TerminalTiming,
    pty_batcher: PTYEventBatcher,
    render_pool: RenderBufferPool,

    /// Statistics for monitoring
    frames_rendered: u64 = 0,
    events_processed: u64 = 0,
    last_stats_time: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, loop: *EventLoop, target_fps: u32) !GhostshellExtensions {
        return .{
            .loop = loop,
            .timing = TerminalTiming.init(target_fps),
            .pty_batcher = try PTYEventBatcher.init(allocator),
            .render_pool = try RenderBufferPool.init(allocator),
            .last_stats_time = blk: {
                const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
                break :blk @as(i64, @intCast(ts.sec * 1_000_000_000 + ts.nsec));
            },
        };
    }

    pub fn deinit(self: *GhostshellExtensions) void {
        self.pty_batcher.deinit();
        self.render_pool.deinit();
    }

    /// Optimized tick with terminal-specific batching
    pub fn tickOptimized(self: *GhostshellExtensions) !bool {
        const ts_frame = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
        const frame_start = @as(i64, @intCast(ts_frame.sec * 1_000_000_000 + ts_frame.nsec));

        // Process events with frame budget awareness
        const had_events = try self.loop.tick();

        self.events_processed += 1;

        // Check frame budget
        const ts_frame_end = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
        const frame_end = @as(i64, @intCast(ts_frame_end.sec * 1_000_000_000 + ts_frame_end.nsec));
        const frame_elapsed = @as(u64, @intCast(frame_end - frame_start));
        if (!self.timing.isWithinBudget(frame_elapsed)) {
            logging.logWarning("Frame budget exceeded", "");
        }

        return had_events;
    }

    /// Get performance statistics
    pub fn getStats(self: *GhostshellExtensions) PerformanceStats {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
        const now = @as(i64, @intCast(ts.sec * 1_000_000_000 + ts.nsec));
        const elapsed_s = @as(f64, @floatFromInt(now - self.last_stats_time)) / 1_000_000_000.0;

        return .{
            .fps = @as(f64, @floatFromInt(self.frames_rendered)) / elapsed_s,
            .events_per_second = @as(f64, @floatFromInt(self.events_processed)) / elapsed_s,
            .target_fps = self.timing.target_fps,
        };
    }

    /// Reset statistics
    pub fn resetStats(self: *GhostshellExtensions) void {
        self.frames_rendered = 0;
        self.events_processed = 0;
        const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
        self.last_stats_time = @as(i64, @intCast(ts.sec * 1_000_000_000 + ts.nsec));
    }
};

pub const PerformanceStats = struct {
    fps: f64,
    events_per_second: f64,
    target_fps: u32,
};
