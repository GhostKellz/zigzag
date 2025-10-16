//! Tests for Ghostshell-specific optimizations

const std = @import("std");
const testing = std.testing;
const zigzag = @import("zigzag");
const ghostshell = @import("ghostshell_optimizations.zig");

test "Terminal timing initialization" {
    const timing = ghostshell.TerminalTiming.init(120);

    try testing.expectEqual(@as(u32, 120), timing.target_fps);
    try testing.expectEqual(@as(u64, 8_333_333), timing.frame_budget_ns); // ~8.3ms for 120fps

    // Test budget checking
    try testing.expect(timing.isWithinBudget(5_000_000)); // 5ms - within budget
    try testing.expect(!timing.isWithinBudget(10_000_000)); // 10ms - over budget
}

test "PTY event batcher" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var batcher = try ghostshell.PTYEventBatcher.init(allocator);
    defer batcher.deinit();

    // Add some data
    try batcher.addData("Hello ");
    try batcher.addData("World!");

    try testing.expectEqual(@as(usize, 12), batcher.batch_buffer.items.len);

    // Should not flush yet (under threshold)
    try testing.expect(!batcher.shouldFlush());

    // Get batch
    const batch = batcher.flush();
    try testing.expectEqualStrings("Hello World!", batch);

    // Clear
    batcher.clear();
    try testing.expectEqual(@as(usize, 0), batcher.batch_buffer.items.len);
}

test "PTY batcher automatic flush" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var batcher = try ghostshell.PTYEventBatcher.init(allocator);
    defer batcher.deinit();

    // Fill buffer to trigger size-based flush
    var large_data: [20000]u8 = undefined;
    @memset(&large_data, 'x');

    try batcher.addData(&large_data);

    // Should trigger flush due to size
    try testing.expect(batcher.shouldFlush());
}

test "Render buffer pool" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try ghostshell.RenderBufferPool.init(allocator);
    defer pool.deinit();

    // Acquire buffers
    const buf1 = try pool.acquire();
    const buf2 = try pool.acquire();
    const buf3 = try pool.acquire();

    try testing.expectEqual(@as(usize, 1024 * 1024), buf1.len);
    try testing.expectEqual(@as(usize, 1024 * 1024), buf2.len);

    // Release back to pool
    try pool.release(buf1);
    try pool.release(buf2);
    try pool.release(buf3);

    try testing.expectEqual(@as(usize, 3), pool.free_buffers.items.len);

    // Acquire again - should reuse from pool
    const buf4 = try pool.acquire();
    try testing.expectEqual(@as(usize, 2), pool.free_buffers.items.len);
    try pool.release(buf4);
}

test "Terminal event priorities" {
    const prio1 = ghostshell.TerminalEventPriority.fromEventType(.read_ready);
    const prio2 = ghostshell.TerminalEventPriority.fromEventType(.window_resize);
    const prio3 = ghostshell.TerminalEventPriority.fromEventType(.timer_expired);

    try testing.expectEqual(ghostshell.TerminalEventPriority.critical, prio1);
    try testing.expectEqual(ghostshell.TerminalEventPriority.normal, prio2);
    try testing.expectEqual(ghostshell.TerminalEventPriority.high, prio3);
}

test "Ghostshell extensions integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    var ext = try ghostshell.GhostshellExtensions.init(allocator, &loop, 120);
    defer ext.deinit();

    try testing.expectEqual(@as(u32, 120), ext.timing.target_fps);
    try testing.expectEqual(@as(u64, 0), ext.frames_rendered);

    // Test optimized tick
    _ = try ext.tickOptimized();

    try testing.expectEqual(@as(u64, 1), ext.events_processed);
}

test "Performance statistics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    var ext = try ghostshell.GhostshellExtensions.init(allocator, &loop, 60);
    defer ext.deinit();

    // Simulate some activity
    ext.frames_rendered = 600;
    ext.events_processed = 6000;

    std.time.sleep(std.time.ns_per_s); // Wait 1 second

    const stats = ext.getStats();

    try testing.expect(stats.fps > 0);
    try testing.expect(stats.events_per_second > 0);
    try testing.expectEqual(@as(u32, 60), stats.target_fps);
}
