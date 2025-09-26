//! Timer wheel implementation for efficient O(1) timer operations
//! Based on hierarchical timing wheels algorithm

const std = @import("std");
const Timer = @import("root.zig").Timer;

/// Timer wheel configuration
pub const WheelConfig = struct {
    /// Number of slots per wheel level
    slots_per_wheel: u32 = 256,
    /// Number of wheel levels (for hierarchical wheels)
    num_levels: u32 = 3,
    /// Base tick interval in milliseconds
    tick_interval_ms: u32 = 10,
};

/// Timer entry in the wheel
const TimerEntry = struct {
    timer: Timer,
    next: ?*TimerEntry,
    prev: ?*TimerEntry,
    wheel_index: u32,
    level: u32,
};

/// Timer wheel level
const WheelLevel = struct {
    slots: []?*TimerEntry,
    current_slot: u32,
    tick_interval: u64,

    pub fn init(allocator: std.mem.Allocator, num_slots: u32, tick_interval: u64) !WheelLevel {
        var slots = try allocator.alloc(?*TimerEntry, num_slots);
        @memset(slots, null);

        return WheelLevel{
            .slots = slots,
            .current_slot = 0,
            .tick_interval = tick_interval,
        };
    }

    pub fn deinit(self: *WheelLevel, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
    }

    pub fn advance(self: *WheelLevel) void {
        self.current_slot = (self.current_slot + 1) % @as(u32, @intCast(self.slots.len));
    }
};

/// Hierarchical timer wheel
pub const TimerWheel = struct {
    allocator: std.mem.Allocator,
    config: WheelConfig,
    levels: []WheelLevel,
    timer_pool: std.heap.MemoryPool(TimerEntry),
    timer_map: std.AutoHashMap(u32, *TimerEntry),
    current_time: i64,
    last_tick: i64,

    pub fn init(allocator: std.mem.Allocator, config: WheelConfig) !TimerWheel {
        var levels = try allocator.alloc(WheelLevel, config.num_levels);
        errdefer allocator.free(levels);

        // Initialize each level with progressively larger tick intervals
        var tick_interval = config.tick_interval_ms;
        for (levels, 0..) |*level, i| {
            level.* = try WheelLevel.init(allocator, config.slots_per_wheel, tick_interval);
            tick_interval *= config.slots_per_wheel;

            if (i > 0) {
                errdefer {
                    for (levels[0..i]) |*l| {
                        l.deinit(allocator);
                    }
                }
            }
        }

        var timer_pool = std.heap.MemoryPool(TimerEntry).init(allocator);
        errdefer timer_pool.deinit();

        var timer_map = std.AutoHashMap(u32, *TimerEntry).init(allocator);
        errdefer timer_map.deinit();

        return TimerWheel{
            .allocator = allocator,
            .config = config,
            .levels = levels,
            .timer_pool = timer_pool,
            .timer_map = timer_map,
            .current_time = std.time.milliTimestamp(),
            .last_tick = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *TimerWheel) void {
        // Clean up all timer entries
        self.timer_map.deinit();
        self.timer_pool.deinit();

        // Clean up wheel levels
        for (self.levels) |*level| {
            level.deinit(self.allocator);
        }
        self.allocator.free(self.levels);
    }

    /// Calculate which level and slot a timer belongs to
    fn calculatePosition(self: *TimerWheel, deadline: i64) struct { level: u32, slot: u32 } {
        const delta = deadline - self.current_time;
        if (delta <= 0) {
            return .{ .level = 0, .slot = self.levels[0].current_slot };
        }

        const delta_ms = @as(u64, @intCast(delta));

        // Find appropriate level based on time delta
        var level: u32 = 0;
        var cumulative_interval: u64 = self.config.tick_interval_ms;

        for (self.levels, 0..) |wheel_level, i| {
            const level_capacity = wheel_level.tick_interval * self.config.slots_per_wheel;
            if (delta_ms < level_capacity) {
                level = @intCast(i);
                break;
            }
            cumulative_interval = level_capacity;
        } else {
            // Timer is too far in future, put in highest level
            level = @intCast(self.levels.len - 1);
        }

        // Calculate slot within the level
        const level_delta = delta_ms / self.levels[level].tick_interval;
        const slot = (self.levels[level].current_slot + level_delta) % self.config.slots_per_wheel;

        return .{ .level = level, .slot = @intCast(slot) };
    }

    /// Add a timer to the wheel
    pub fn addTimer(self: *TimerWheel, timer: Timer) !void {
        // Check if timer already exists
        if (self.timer_map.contains(timer.id)) {
            return error.TimerAlreadyExists;
        }

        // Create timer entry
        var entry = try self.timer_pool.create();
        entry.* = TimerEntry{
            .timer = timer,
            .next = null,
            .prev = null,
            .wheel_index = 0,
            .level = 0,
        };

        // Calculate position
        const pos = self.calculatePosition(timer.deadline);
        entry.level = pos.level;
        entry.wheel_index = pos.slot;

        // Insert into wheel
        self.insertEntry(entry);

        // Add to map
        try self.timer_map.put(timer.id, entry);
    }

    /// Insert entry into the wheel
    fn insertEntry(self: *TimerWheel, entry: *TimerEntry) void {
        const level = &self.levels[entry.level];
        const slot = &level.slots[entry.wheel_index];

        // Insert at head of list
        entry.next = slot.*;
        entry.prev = null;
        if (slot.*) |head| {
            head.prev = entry;
        }
        slot.* = entry;
    }

    /// Remove entry from the wheel
    fn removeEntry(self: *TimerWheel, entry: *TimerEntry) void {
        const level = &self.levels[entry.level];
        const slot = &level.slots[entry.wheel_index];

        // Remove from linked list
        if (entry.prev) |prev| {
            prev.next = entry.next;
        } else {
            // Entry is head of list
            slot.* = entry.next;
        }

        if (entry.next) |next| {
            next.prev = entry.prev;
        }

        entry.next = null;
        entry.prev = null;
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *TimerWheel, timer_id: u32) !void {
        if (self.timer_map.get(timer_id)) |entry| {
            // Remove from wheel
            self.removeEntry(entry);

            // Remove from map
            _ = self.timer_map.remove(timer_id);

            // Return to pool
            self.timer_pool.destroy(entry);
        } else {
            return error.TimerNotFound;
        }
    }

    /// Process timers and advance the wheel
    pub fn tick(self: *TimerWheel) !std.ArrayList(Timer) {
        const now = std.time.milliTimestamp();
        const elapsed = now - self.last_tick;

        var expired_timers = std.ArrayList(Timer){
            .items = &.{},
            .capacity = 0,
        };
        errdefer expired_timers.deinit(self.allocator);

        // Calculate how many ticks to advance
        const ticks_to_advance = @divTrunc(elapsed, self.config.tick_interval_ms);

        for (0..ticks_to_advance) |_| {
            // Process current slot in level 0
            const level0 = &self.levels[0];
            if (level0.slots[level0.current_slot]) |head| {
                var current: ?*TimerEntry = head;
                while (current) |entry| {
                    const next = entry.next;

                    // Check if timer has expired
                    if (entry.timer.deadline <= now) {
                        // Remove from wheel
                        self.removeEntry(entry);

                        // Add to expired list
                        try expired_timers.append(self.allocator, entry.timer);

                        // Handle recurring timers
                        if (entry.timer.interval) |interval| {
                            // Reschedule recurring timer
                            entry.timer.deadline = now + @as(i64, @intCast(interval));
                            const new_pos = self.calculatePosition(entry.timer.deadline);
                            entry.level = new_pos.level;
                            entry.wheel_index = new_pos.slot;
                            self.insertEntry(entry);
                        } else {
                            // Remove one-shot timer
                            _ = self.timer_map.remove(entry.timer.id);
                            self.timer_pool.destroy(entry);
                        }
                    }

                    current = next;
                }
            }

            // Advance wheels
            level0.advance();

            // Cascade to higher levels if needed
            if (level0.current_slot == 0 and self.levels.len > 1) {
                self.cascade();
            }

            self.current_time += @intCast(self.config.tick_interval_ms);
        }

        self.last_tick = now;
        return expired_timers;
    }

    /// Cascade timers from higher levels to lower levels
    fn cascade(self: *TimerWheel) void {
        for (1..self.levels.len) |i| {
            const level = &self.levels[i];

            // Move timers from current slot to lower level
            if (level.slots[level.current_slot]) |head| {
                var current: ?*TimerEntry = head;
                while (current) |entry| {
                    const next = entry.next;

                    // Remove from current level
                    self.removeEntry(entry);

                    // Recalculate position
                    const new_pos = self.calculatePosition(entry.timer.deadline);
                    entry.level = new_pos.level;
                    entry.wheel_index = new_pos.slot;

                    // Insert into new position
                    self.insertEntry(entry);

                    current = next;
                }
            }

            level.advance();

            // Stop cascading if this level didn't wrap
            if (level.current_slot != 0) {
                break;
            }
        }
    }

    /// Get the next timer expiration time
    pub fn getNextExpiration(self: *TimerWheel) ?i64 {
        var min_deadline: ?i64 = null;

        // Check all slots in level 0 starting from current
        const level0 = &self.levels[0];
        for (0..self.config.slots_per_wheel) |offset| {
            const slot_index = (level0.current_slot + offset) % self.config.slots_per_wheel;
            if (level0.slots[slot_index]) |head| {
                var current: ?*TimerEntry = head;
                while (current) |entry| {
                    if (min_deadline) |min| {
                        if (entry.timer.deadline < min) {
                            min_deadline = entry.timer.deadline;
                        }
                    } else {
                        min_deadline = entry.timer.deadline;
                    }
                    current = entry.next;
                }
            }
        }

        return min_deadline;
    }
};

test "TimerWheel basic operations" {
    const allocator = std.testing.allocator;

    var wheel = try TimerWheel.init(allocator, .{
        .slots_per_wheel = 16,
        .num_levels = 2,
        .tick_interval_ms = 10,
    });
    defer wheel.deinit();

    // Add a timer
    const timer = Timer{
        .id = 1,
        .deadline = wheel.current_time + 100,
        .interval = null,
        .type = .one_shot,
        .callback = undefined,
        .user_data = null,
    };

    try wheel.addTimer(timer);
    try std.testing.expect(wheel.timer_map.contains(1));

    // Cancel timer
    try wheel.cancelTimer(1);
    try std.testing.expect(!wheel.timer_map.contains(1));
}

test "TimerWheel tick and expiration" {
    const allocator = std.testing.allocator;

    var wheel = try TimerWheel.init(allocator, .{
        .slots_per_wheel = 16,
        .num_levels = 2,
        .tick_interval_ms = 10,
    });
    defer wheel.deinit();

    // Add a timer that expires in 50ms
    const timer = Timer{
        .id = 1,
        .deadline = wheel.current_time + 50,
        .interval = null,
        .type = .one_shot,
        .callback = undefined,
        .user_data = null,
    };

    try wheel.addTimer(timer);

    // Simulate time passing
    wheel.last_tick = wheel.current_time - 60; // Simulate 60ms elapsed
    const expired = try wheel.tick();
    defer expired.deinit();

    // Timer should have expired
    try std.testing.expect(expired.items.len > 0);
    try std.testing.expectEqual(@as(u32, 1), expired.items[0].id);
}