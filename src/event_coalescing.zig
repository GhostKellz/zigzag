//! Event coalescing system for ZigZag
//! Optimizes event processing by batching similar events

const std = @import("std");
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;

/// Event coalescing configuration
pub const CoalescingConfig = struct {
    /// Enable window resize event coalescing
    coalesce_resize: bool = true,
    /// Maximum time to wait for coalescing (in ms)
    max_coalesce_time_ms: u32 = 10,
    /// Maximum number of events to batch
    max_batch_size: usize = 16,
};

/// Event coalescer
pub const EventCoalescer = struct {
    allocator: std.mem.Allocator,
    config: CoalescingConfig,

    // Pending events by type
    resize_events: std.ArrayList(Event),
    io_events: std.AutoHashMap(i32, Event), // fd -> latest event
    last_coalesce_time: i64,

    pub fn init(allocator: std.mem.Allocator, config: CoalescingConfig) !EventCoalescer {
        var io_events = std.AutoHashMap(i32, Event).init(allocator);
        errdefer io_events.deinit();

        return EventCoalescer{
            .allocator = allocator,
            .config = config,
            .resize_events = std.ArrayList(Event){
                .items = &.{},
                .capacity = 0,
            },
            .io_events = io_events,
            .last_coalesce_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *EventCoalescer) void {
        self.resize_events.deinit(self.allocator);
        self.io_events.deinit();
    }

    /// Add event for coalescing
    pub fn addEvent(self: *EventCoalescer, event: Event) !void {
        switch (event.type) {
            .window_resize => {
                if (self.config.coalesce_resize) {
                    // Only keep the latest resize event
                    self.resize_events.clearRetainingCapacity();
                    try self.resize_events.append(self.allocator, event);
                }
            },
            .read_ready, .write_ready => {
                // Coalesce I/O events for the same fd
                try self.io_events.put(event.fd, event);
            },
            else => {
                // Other events are not coalesced
                // They should be processed immediately
            },
        }
    }

    /// Check if coalescing should flush
    pub fn shouldFlush(self: *EventCoalescer) bool {
        const now = std.time.milliTimestamp();
        const elapsed = now - self.last_coalesce_time;

        // Flush if max time exceeded
        if (elapsed >= self.config.max_coalesce_time_ms) {
            return true;
        }

        // Flush if too many events accumulated
        const total_events = self.resize_events.items.len + self.io_events.count();
        if (total_events >= self.config.max_batch_size) {
            return true;
        }

        return false;
    }

    /// Flush coalesced events
    pub fn flush(self: *EventCoalescer, output: []Event) !usize {
        var count: usize = 0;

        // Add resize events
        for (self.resize_events.items) |event| {
            if (count >= output.len) break;
            output[count] = event;
            count += 1;
        }

        // Add I/O events
        var iter = self.io_events.iterator();
        while (iter.next()) |entry| {
            if (count >= output.len) break;
            output[count] = entry.value_ptr.*;
            count += 1;
        }

        // Clear buffers
        self.resize_events.clearRetainingCapacity();
        self.io_events.clearRetainingCapacity();
        self.last_coalesce_time = std.time.milliTimestamp();

        return count;
    }

    /// Process events with coalescing
    pub fn processEvents(self: *EventCoalescer, events: []const Event, output: []Event) !usize {
        // Add new events
        for (events) |event| {
            try self.addEvent(event);
        }

        // Check if we should flush
        if (self.shouldFlush()) {
            return try self.flush(output);
        }

        return 0;
    }
};

test "EventCoalescer basic operations" {
    const allocator = std.testing.allocator;

    var coalescer = try EventCoalescer.init(allocator, .{});
    defer coalescer.deinit();

    // Add multiple resize events
    const resize1 = Event{
        .fd = -1,
        .type = .window_resize,
        .data = .{ .size = 100 },
    };

    const resize2 = Event{
        .fd = -1,
        .type = .window_resize,
        .data = .{ .size = 200 },
    };

    try coalescer.addEvent(resize1);
    try coalescer.addEvent(resize2);

    // Should only have one resize event (the latest)
    try std.testing.expectEqual(@as(usize, 1), coalescer.resize_events.items.len);
    try std.testing.expectEqual(@as(usize, 200), coalescer.resize_events.items[0].data.size);
}

test "EventCoalescer I/O coalescing" {
    const allocator = std.testing.allocator;

    var coalescer = try EventCoalescer.init(allocator, .{});
    defer coalescer.deinit();

    // Add multiple events for same fd
    const event1 = Event{
        .fd = 5,
        .type = .read_ready,
        .data = .{ .size = 100 },
    };

    const event2 = Event{
        .fd = 5,
        .type = .read_ready,
        .data = .{ .size = 200 },
    };

    try coalescer.addEvent(event1);
    try coalescer.addEvent(event2);

    // Should only have one event for fd 5 (the latest)
    try std.testing.expectEqual(@as(usize, 1), coalescer.io_events.count());
    const stored_event = coalescer.io_events.get(5).?;
    try std.testing.expectEqual(@as(usize, 200), stored_event.data.size);
}

test "EventCoalescer flush" {
    const allocator = std.testing.allocator;

    var coalescer = try EventCoalescer.init(allocator, .{
        .max_coalesce_time_ms = 1000, // Long timeout for testing
    });
    defer coalescer.deinit();

    // Add events
    const resize = Event{
        .fd = -1,
        .type = .window_resize,
        .data = .{ .size = 100 },
    };

    const io = Event{
        .fd = 5,
        .type = .read_ready,
        .data = .{ .size = 200 },
    };

    try coalescer.addEvent(resize);
    try coalescer.addEvent(io);

    // Flush events
    var output: [10]Event = undefined;
    const count = try coalescer.flush(&output);

    try std.testing.expectEqual(@as(usize, 2), count);

    // Verify buffers are cleared
    try std.testing.expectEqual(@as(usize, 0), coalescer.resize_events.items.len);
    try std.testing.expectEqual(@as(usize, 0), coalescer.io_events.count());
}