//! ZigZag Beta Feature Demo
//! Demonstrates all beta features: performance profiling, priority queues,
//! PTY management, signal handling, and platform optimizations

const std = @import("std");
const zigzag = @import("zigzag");

// Import beta features
const Profiler = @import("../src/profiling.zig").Profiler;
const EventPriorityQueue = @import("../src/priority_queue.zig").EventPriorityQueue;
const Priority = @import("../src/priority_queue.zig").Priority;
const PtyManager = @import("../src/pty.zig").PtyManager;
const SignalHandler = @import("../src/signals.zig").SignalHandler;
const BackendDetector = @import("../src/platform_optimizations.zig").BackendDetector;
const RingBuffer = @import("../src/zero_copy.zig").RingBuffer;
const BufferPool = @import("../src/zero_copy.zig").BufferPool;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZigZag Beta Feature Demo ===", .{});

    // 1. Platform Detection and Optimization
    std.log.info("\n1. Platform Detection:", .{});
    const detector = BackendDetector.init();
    const optimal_backend = detector.getOptimalBackend();
    const fallback_chain = detector.getFallbackChain();

    std.log.info("  Optimal backend: {s}", .{@tagName(optimal_backend)});
    std.log.info("  Fallback chain: ", .{});
    for (fallback_chain) |backend| {
        std.log.info("    - {s}", .{@tagName(backend)});
    }
    std.log.info("  Zero-copy support: {}", .{detector.supportsZeroCopy()});
    std.log.info("  Recommended queue size: {d}", .{detector.getRecommendedQueueSize()});

    // 2. Event Loop with Performance Profiling
    std.log.info("\n2. Event Loop with Profiling:", .{});
    var loop = try zigzag.EventLoop.init(allocator, .{
        .max_events = detector.getRecommendedQueueSize(),
        .backend = optimal_backend,
        .coalescing = .{
            .coalesce_resize = true,
            .max_coalesce_time_ms = 5,
        },
    });
    defer loop.deinit();

    // Initialize profiler
    var profiler = Profiler.init(allocator, optimal_backend);
    defer profiler.deinit();

    std.log.info("  Backend: {s}", .{@tagName(loop.backend)});

    // 3. Priority Queue Demo
    std.log.info("\n3. Priority Queue Demo:", .{});
    var priority_queue = EventPriorityQueue.init(allocator);
    defer priority_queue.deinit();

    // Add events with different priorities
    const critical_event = zigzag.Event{
        .fd = 1,
        .type = .io_error,
        .data = .{ .size = 0 },
    };

    const normal_event = zigzag.Event{
        .fd = 2,
        .type = .read_ready,
        .data = .{ .size = 1024 },
    };

    const low_event = zigzag.Event{
        .fd = 3,
        .type = .window_resize,
        .data = .{ .size = 0 },
    };

    try priority_queue.add(normal_event);
    try priority_queue.add(critical_event);
    try priority_queue.add(low_event);

    std.log.info("  Added 3 events with different priorities", .{});
    std.log.info("  Queue size: {d}", .{priority_queue.count()});

    // Process events by priority
    std.log.info("  Processing events by priority:", .{});
    while (!priority_queue.isEmpty()) {
        const event = priority_queue.remove().?;
        const priority = Priority.fromEventType(event.type);
        std.log.info("    Event: {s} (priority: {s})", .{ @tagName(event.type), @tagName(priority) });
    }

    // 4. Zero-Copy I/O Demo
    std.log.info("\n4. Zero-Copy I/O Demo:", .{});
    var ring_buffer = try RingBuffer.init(allocator, 4096);
    defer ring_buffer.deinit();

    var buffer_pool = BufferPool.init(allocator, 1024, 10);
    defer buffer_pool.deinit();

    // Test ring buffer
    const write_buf = ring_buffer.getWriteBuffer();
    const test_data = "Hello, Zero-Copy World!";
    @memcpy(write_buf[0..test_data.len], test_data);
    ring_buffer.commitWrite(test_data.len);

    std.log.info("  Ring buffer available for read: {d} bytes", .{ring_buffer.availableRead()});

    const read_buf = ring_buffer.getReadBuffer();
    std.log.info("  Data: {s}", .{read_buf[0..test_data.len]});
    ring_buffer.commitRead(test_data.len);

    // Test buffer pool
    const pooled_buf = try buffer_pool.acquire();
    std.log.info("  Acquired buffer from pool: {d} bytes", .{pooled_buf.len});
    try buffer_pool.release(pooled_buf);
    std.log.info("  Released buffer back to pool", .{});

    // 5. Signal Handling Demo
    std.log.info("\n5. Signal Handling Demo:", .{});
    var signal_handler = try SignalHandler.init(allocator, .{
        .handle_winch = true,
        .handle_chld = false, // Don't interfere with demo
        .use_signalfd = false, // Use traditional for demo compatibility
    });
    defer signal_handler.deinit();

    if (signal_handler.getSignalFd()) |signal_fd| {
        std.log.info("  Using signalfd: {d}", .{signal_fd});
    } else {
        std.log.info("  Using traditional signal handlers", .{});
    }

    // 6. PTY Management Demo (simplified)
    std.log.info("\n6. PTY Management Demo:", .{});
    var pty_manager = PtyManager.init(allocator);
    defer pty_manager.deinit();

    std.log.info("  PTY manager initialized", .{});
    std.log.info("  Note: Skipping actual process spawn for demo safety", .{});

    // In a real scenario, you would:
    // const process = try pty_manager.spawn(.{
    //     .shell = "/bin/sh",
    //     .cols = 80,
    //     .rows = 24,
    // });

    // 7. Performance Benchmarking
    std.log.info("\n7. Performance Benchmarking:", .{});
    const iterations = 1000;
    var total_time: u64 = 0;

    for (0..iterations) |_| {
        const timer = profiler.startTiming();

        // Simulate event processing
        std.time.sleep(1000); // 1 microsecond

        profiler.recordEventProcessing(.read_ready, timer);
        total_time += timer.elapsedNanos();
    }

    const avg_time_ns = total_time / iterations;
    std.log.info("  Processed {d} events", .{iterations});
    std.log.info("  Average processing time: {d} ns", .{avg_time_ns});
    std.log.info("  Events per second: {d:.0}", .{1e9 / @as(f64, @floatFromInt(avg_time_ns))});

    // 8. Performance Report
    std.log.info("\n8. Performance Report:", .{});
    const metrics = profiler.getMetrics();
    std.log.info("  Total events processed: {d}", .{metrics.events_processed});
    std.log.info("  Average processing time: {d:.2} μs", .{metrics.avgEventProcessingTime() / 1000.0});

    // Generate detailed report to stderr so it doesn't interfere with logging
    std.log.info("  Generating detailed performance report...", .{});
    try profiler.generateReport(std.io.getStdErr().writer());

    std.log.info("\n=== Beta Demo Complete ===", .{});
    std.log.info("All beta features demonstrated successfully!", .{});
}

test "Beta features integration" {
    const allocator = std.testing.allocator;

    // Test platform detection
    const detector = BackendDetector.init();
    const backend = detector.getOptimalBackend();
    try std.testing.expect(backend != undefined);

    // Test priority queue
    var queue = EventPriorityQueue.init(allocator);
    defer queue.deinit();

    const event = zigzag.Event{
        .fd = 1,
        .type = .read_ready,
        .data = .{ .size = 100 },
    };

    try queue.add(event);
    try std.testing.expect(queue.count() == 1);

    const retrieved = queue.remove().?;
    try std.testing.expectEqual(event.fd, retrieved.fd);

    // Test zero-copy buffers
    var ring = try RingBuffer.init(allocator, 1024);
    defer ring.deinit();

    try std.testing.expect(ring.availableWrite() > 0);
    try std.testing.expect(ring.availableRead() == 0);

    // Test profiler
    var profiler = Profiler.init(allocator, backend);
    defer profiler.deinit();

    const timer = profiler.startTiming();
    std.time.sleep(1000); // 1μs
    profiler.recordEventProcessing(.read_ready, timer);

    const metrics = profiler.getMetrics();
    try std.testing.expect(metrics.events_processed > 0);

    // Test signal handler
    var signals = try SignalHandler.init(allocator, .{
        .handle_winch = true,
        .use_signalfd = false,
    });
    defer signals.deinit();

    // Test PTY manager
    var pty = PtyManager.init(allocator);
    defer pty.deinit();

    try std.testing.expect(pty.processes.count() == 0);
}