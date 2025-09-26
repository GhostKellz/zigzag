//! Priority queue implementation for event processing
//! Supports different priority levels for optimal performance

const std = @import("std");
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;

/// Event priority levels
pub const Priority = enum(u8) {
    critical = 0, // Signal events, errors
    high = 1,     // Timer events, I/O completion
    normal = 2,   // Regular I/O events
    low = 3,      // Background events, maintenance

    pub fn fromEventType(event_type: EventType) Priority {
        return switch (event_type) {
            .io_error, .hangup => .critical,
            .timer_expired, .child_exit => .high,
            .read_ready, .write_ready => .normal,
            .window_resize, .focus_change, .user_event => .low,
        };
    }
};

/// Prioritized event wrapper
pub const PriorityEvent = struct {
    event: Event,
    priority: Priority,
    sequence: u64, // For FIFO within same priority

    /// Compare function for heap ordering
    pub fn lessThan(_: void, a: PriorityEvent, b: PriorityEvent) bool {
        // Lower priority value = higher actual priority
        if (@intFromEnum(a.priority) != @intFromEnum(b.priority)) {
            return @intFromEnum(a.priority) < @intFromEnum(b.priority);
        }
        // Same priority, use FIFO (earlier sequence first)
        return a.sequence < b.sequence;
    }
};

/// Priority queue for events
pub const EventPriorityQueue = struct {
    heap: std.PriorityQueue(PriorityEvent, void, PriorityEvent.lessThan),
    sequence_counter: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EventPriorityQueue {
        return EventPriorityQueue{
            .heap = std.PriorityQueue(PriorityEvent, void, PriorityEvent.lessThan).init(allocator, {}),
            .sequence_counter = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventPriorityQueue) void {
        self.heap.deinit();
    }

    /// Add event with automatic priority assignment
    pub fn add(self: *EventPriorityQueue, event: Event) !void {
        const priority = Priority.fromEventType(event.type);
        try self.addWithPriority(event, priority);
    }

    /// Add event with explicit priority
    pub fn addWithPriority(self: *EventPriorityQueue, event: Event, priority: Priority) !void {
        const priority_event = PriorityEvent{
            .event = event,
            .priority = priority,
            .sequence = self.sequence_counter,
        };
        self.sequence_counter += 1;
        try self.heap.add(priority_event);
    }

    /// Remove highest priority event
    pub fn remove(self: *EventPriorityQueue) ?Event {
        const priority_event = self.heap.removeOrNull() orelse return null;
        return priority_event.event;
    }

    /// Peek at highest priority event without removing
    pub fn peek(self: *const EventPriorityQueue) ?Event {
        const priority_event = self.heap.peek() orelse return null;
        return priority_event.event;
    }

    /// Get number of events in queue
    pub fn count(self: *const EventPriorityQueue) usize {
        return self.heap.count();
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *const EventPriorityQueue) bool {
        return self.heap.count() == 0;
    }

    /// Drain all events with a specific priority or higher
    pub fn drainPriority(self: *EventPriorityQueue, min_priority: Priority, output: []Event) usize {
        var drained: usize = 0;

        while (drained < output.len) {
            const priority_event = self.heap.peek() orelse break;

            // Stop if next event has lower priority
            if (@intFromEnum(priority_event.priority) > @intFromEnum(min_priority)) {
                break;
            }

            // Remove and add to output
            output[drained] = self.heap.remove().event;
            drained += 1;
        }

        return drained;
    }

    /// Get count by priority level
    pub fn countByPriority(self: *const EventPriorityQueue, priority: Priority) usize {
        var count_found: usize = 0;

        // Note: This is inefficient but useful for debugging/monitoring
        // In production, we'd maintain separate counters
        const items = self.heap.items;
        for (items) |item| {
            if (item.priority == priority) {
                count_found += 1;
            }
        }

        return count_found;
    }
};

/// Batch processor for prioritized events
pub const BatchProcessor = struct {
    max_batch_size: usize,
    max_process_time_ms: u32,

    pub fn init(max_batch_size: usize, max_process_time_ms: u32) BatchProcessor {
        return BatchProcessor{
            .max_batch_size = max_batch_size,
            .max_process_time_ms = max_process_time_ms,
        };
    }

    /// Process events in batches with priority awareness
    pub fn processBatch(
        self: *const BatchProcessor,
        queue: *EventPriorityQueue,
        processor: *const fn ([]const Event) void,
    ) usize {
        const start_time = std.time.milliTimestamp();
        var batch: [64]Event = undefined; // Stack allocation for small batches
        var total_processed: usize = 0;

        while (!queue.isEmpty()) {
            // Check time limit
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed >= self.max_process_time_ms) {
                break;
            }

            // Determine batch size
            const batch_size = @min(
                @min(batch.len, self.max_batch_size),
                queue.count()
            );

            if (batch_size == 0) break;

            // Fill batch with highest priority events
            var filled: usize = 0;
            for (0..batch_size) |i| {
                if (queue.remove()) |event| {
                    batch[i] = event;
                    filled += 1;
                } else {
                    break;
                }
            }

            if (filled > 0) {
                // Process the batch
                processor(batch[0..filled]);
                total_processed += filled;
            }
        }

        return total_processed;
    }

    /// Process only critical events (emergency processing)
    pub fn processEmergency(
        queue: *EventPriorityQueue,
        processor: *const fn ([]const Event) void,
    ) usize {
        var batch: [16]Event = undefined;
        const drained = queue.drainPriority(.critical, &batch);

        if (drained > 0) {
            processor(batch[0..drained]);
        }

        return drained;
    }
};

/// Event statistics for monitoring
pub const EventStats = struct {
    total_processed: u64,
    by_priority: [4]u64, // Index by priority value
    avg_queue_size: f64,
    max_queue_size: usize,
    measurements: u64,

    pub fn init() EventStats {
        return EventStats{
            .total_processed = 0,
            .by_priority = [_]u64{0} ** 4,
            .avg_queue_size = 0.0,
            .max_queue_size = 0,
            .measurements = 0,
        };
    }

    pub fn recordEvent(self: *EventStats, priority: Priority) void {
        self.total_processed += 1;
        self.by_priority[@intFromEnum(priority)] += 1;
    }

    pub fn recordQueueSize(self: *EventStats, size: usize) void {
        self.measurements += 1;
        self.max_queue_size = @max(self.max_queue_size, size);

        // Update moving average
        const weight = 1.0 / @as(f64, @floatFromInt(self.measurements));
        self.avg_queue_size = self.avg_queue_size * (1.0 - weight) + @as(f64, @floatFromInt(size)) * weight;
    }

    pub fn format(
        self: EventStats,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("EventStats:\n", .{});
        try writer.print("  Total processed: {d}\n", .{self.total_processed});
        try writer.print("  Critical: {d}, High: {d}, Normal: {d}, Low: {d}\n", .{
            self.by_priority[0],
            self.by_priority[1],
            self.by_priority[2],
            self.by_priority[3],
        });
        try writer.print("  Avg queue size: {d:.2}\n", .{self.avg_queue_size});
        try writer.print("  Max queue size: {d}\n", .{self.max_queue_size});
    }
};

test "Priority queue basic operations" {
    const allocator = std.testing.allocator;

    var queue = EventPriorityQueue.init(allocator);
    defer queue.deinit();

    // Add events with different priorities
    const low_event = Event{
        .fd = 1,
        .type = .window_resize,
        .data = .{ .size = 100 },
    };

    const critical_event = Event{
        .fd = 2,
        .type = .io_error,
        .data = .{ .size = 0 },
    };

    try queue.add(low_event);
    try queue.add(critical_event);

    // Critical event should come out first
    const first = queue.remove().?;
    try std.testing.expectEqual(critical_event.fd, first.fd);
    try std.testing.expectEqual(EventType.io_error, first.type);

    // Low priority event should come out second
    const second = queue.remove().?;
    try std.testing.expectEqual(low_event.fd, second.fd);
    try std.testing.expectEqual(EventType.window_resize, second.type);
}

test "Priority queue FIFO within same priority" {
    const allocator = std.testing.allocator;

    var queue = EventPriorityQueue.init(allocator);
    defer queue.deinit();

    // Add multiple events with same priority
    for (0..5) |i| {
        const event = Event{
            .fd = @intCast(i),
            .type = .read_ready,
            .data = .{ .size = i },
        };
        try queue.add(event);
    }

    // Should come out in FIFO order
    for (0..5) |i| {
        const event = queue.remove().?;
        try std.testing.expectEqual(@as(i32, @intCast(i)), event.fd);
    }
}

test "Batch processing" {
    const allocator = std.testing.allocator;

    var queue = EventPriorityQueue.init(allocator);
    defer queue.deinit();

    // Add test events
    for (0..10) |i| {
        const event = Event{
            .fd = @intCast(i),
            .type = if (i < 3) .io_error else .read_ready,
            .data = .{ .size = i },
        };
        try queue.add(event);
    }

    const processor = BatchProcessor.init(5, 100);
    var processed_count: usize = 0;

    const test_processor = struct {
        var count: *usize = undefined;
        pub fn process(events: []const Event) void {
            count.* += events.len;
        }
    };
    test_processor.count = &processed_count;

    const total = processor.processBatch(&queue, test_processor.process);
    try std.testing.expectEqual(@as(usize, 10), total);
    try std.testing.expectEqual(@as(usize, 10), processed_count);
}