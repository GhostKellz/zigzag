//! macOS/BSD kqueue backend for zigzag event loop
//! Provides efficient I/O multiplexing using the kqueue API

const std = @import("std");
const posix = std.posix;
const c = std.c;
const builtin = @import("builtin");
const EventLoop = @import("../root.zig").EventLoop;
const Event = @import("../root.zig").Event;
const EventType = @import("../root.zig").EventType;
const EventMask = @import("../root.zig").EventMask;
const Watch = @import("../root.zig").Watch;
const Timer = @import("../root.zig").Timer;

// Only compile this backend on supported platforms
const supports_kqueue = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .openbsd, .netbsd => true,
    else => false,
};

/// kqueue backend implementation
pub const KqueueBackend = if (supports_kqueue) struct {
    kqueue_fd: i32,
    allocator: std.mem.Allocator,

    // Timer management - kqueue uses EVFILT_TIMER
    timer_map: std.AutoHashMap(u32, void), // timer_id -> void (just tracking existence)

    /// Initialize the kqueue backend
    pub fn init(allocator: std.mem.Allocator) !KqueueBackend {
        if (builtin.os.tag != .macos and builtin.os.tag != .freebsd and builtin.os.tag != .openbsd and builtin.os.tag != .netbsd) {
            return error.PlatformNotSupported;
        }

        const kqueue_fd = try posix.kqueue();
        errdefer posix.close(kqueue_fd);

        var timer_map = std.AutoHashMap(u32, void).init(allocator);
        errdefer timer_map.deinit();

        return KqueueBackend{
            .kqueue_fd = kqueue_fd,
            .allocator = allocator,
            .timer_map = timer_map,
        };
    }

    /// Deinitialize the kqueue backend
    pub fn deinit(self: *KqueueBackend) void {
        self.timer_map.deinit();
        posix.close(self.kqueue_fd);
    }

    /// Convert EventMask to kqueue filters
    fn eventMaskToKqueue(mask: EventMask) struct { read: bool, write: bool } {
        return .{
            .read = mask.read,
            .write = mask.write,
        };
    }

    /// Convert kqueue event to EventType
    fn kqueueToEventType(kevent: c.Kevent) EventType {
        return switch (kevent.filter) {
            c.EVFILT.READ => .read_ready,
            c.EVFILT.WRITE => .write_ready,
            c.EVFILT.TIMER => .timer_expired,
            else => .read_ready, // Default
        };
    }

    /// Add file descriptor to kqueue
    pub fn addFd(self: *KqueueBackend, fd: i32, mask: EventMask) !void {
        const filters = eventMaskToKqueue(mask);

        if (filters.read) {
            const kevent = c.Kevent{
                .ident = @intCast(fd),
                .filter = c.EVFILT.READ,
                .flags = c.EV.ADD | c.EV.ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
        }

        if (filters.write) {
            const kevent = c.Kevent{
                .ident = @intCast(fd),
                .filter = c.EVFILT.WRITE,
                .flags = c.EV.ADD | c.EV.ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
        }
    }

    /// Modify file descriptor in kqueue
    pub fn modifyFd(self: *KqueueBackend, fd: i32, mask: EventMask) !void {
        // Remove existing filters first
        try self.removeFd(fd);
        // Add with new mask
        try self.addFd(fd, mask);
    }

    /// Remove file descriptor from kqueue
    pub fn removeFd(self: *KqueueBackend, fd: i32) !void {
        // Remove read filter
        const read_kevent = c.Kevent{
            .ident = @intCast(fd),
            .filter = c.EVFILT.READ,
            .flags = c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        // Remove write filter
        const write_kevent = c.Kevent{
            .ident = @intCast(fd),
            .filter = c.EVFILT.WRITE,
            .flags = c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        // Try to remove both filters - ignore errors if they don't exist
        _ = std.c.kevent(self.kqueue_fd, &read_kevent, 1, null, 0, null);
        _ = std.c.kevent(self.kqueue_fd, &write_kevent, 1, null, 0, null);
    }

    /// Poll for events
    pub fn poll(self: *KqueueBackend, events: []Event, timeout_ms: ?u32) !usize {
        var kevents: [1024]c.Kevent = undefined;

        const timeout_spec: ?c.timespec = if (timeout_ms) |ms| .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        } else null;

        const num_events = std.c.kevent(
            self.kqueue_fd,
            null,
            0,
            &kevents,
            @intCast(kevents.len),
            if (timeout_spec) |*ts| ts else null,
        );

        if (num_events < 0) {
            return error.KQueueError;
        }

        const count = @min(@as(usize, @intCast(num_events)), events.len);
        for (0..count) |i| {
            const kevent = kevents[i];

            if (kevent.filter == c.EVFILT.TIMER) {
                // Timer event
                events[i] = Event{
                    .fd = -1,
                    .type = .timer_expired,
                    .data = .{ .timer_id = @intCast(kevent.ident) },
                };
            } else {
                // I/O event
                events[i] = Event{
                    .fd = @intCast(kevent.ident),
                    .type = kqueueToEventType(kevent),
                    .data = .{ .size = @intCast(@abs(kevent.data)) },
                };
            }
        }

        return count;
    }

    /// Add a timer using kqueue EVFILT_TIMER
    pub fn addTimer(self: *KqueueBackend, timer_id: u32, ms: u64) !void {
        const kevent = c.Kevent{
            .ident = @intCast(timer_id),
            .filter = c.EVFILT.TIMER,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
            .fflags = 0,
            .data = @intCast(ms),
            .udata = 0,
        };

        const result = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
        if (result < 0) {
            return error.KQueueError;
        }
        try self.timer_map.put(timer_id, {});
    }

    /// Add a recurring timer
    pub fn addRecurringTimer(self: *KqueueBackend, timer_id: u32, interval_ms: u64) !void {
        const kevent = c.Kevent{
            .ident = @intCast(timer_id),
            .filter = c.EVFILT.TIMER,
            .flags = c.EV.ADD | c.EV.ENABLE,
            .fflags = 0,
            .data = @intCast(interval_ms),
            .udata = 0,
        };

        const result = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
        if (result < 0) {
            return error.KQueueError;
        }
        try self.timer_map.put(timer_id, {});
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *KqueueBackend, timer_id: u32) !void {
        if (self.timer_map.contains(timer_id)) {
            const kevent = c.Kevent{
                .ident = @intCast(timer_id),
                .filter = c.EVFILT.TIMER,
                .flags = c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };

            _ = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
            _ = self.timer_map.remove(timer_id);
        }
    }
} else void;

test "KqueueBackend basic operations" {
    if (!supports_kqueue) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try KqueueBackend.init(allocator);
    defer backend.deinit();

    // Test that kqueue_fd is valid
    try std.testing.expect(backend.kqueue_fd > 0);
}

test "EventMask to kqueue conversion" {
    if (!supports_kqueue) return error.SkipZigTest;

    const mask = EventMask{ .read = true, .write = true };
    const filters = KqueueBackend.eventMaskToKqueue(mask);

    try std.testing.expect(filters.read);
    try std.testing.expect(filters.write);
}