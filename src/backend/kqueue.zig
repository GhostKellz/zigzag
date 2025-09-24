//! macOS/BSD kqueue backend for zigzag event loop
//! Provides efficient I/O multiplexing using the kqueue API

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const EventLoop = @import("../root.zig").EventLoop;
const Event = @import("../root.zig").Event;
const EventType = @import("../root.zig").EventType;
const EventMask = @import("../root.zig").EventMask;
const Watch = @import("../root.zig").Watch;
const Timer = @import("../root.zig").Timer;

/// kqueue backend implementation
pub const KqueueBackend = struct {
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
    fn kqueueToEventType(kevent: posix.system.kevent) EventType {
        return switch (kevent.filter) {
            posix.system.EVFILT.READ => .read_ready,
            posix.system.EVFILT.WRITE => .write_ready,
            posix.system.EVFILT.TIMER => .timer_expired,
            else => .read_ready, // Default
        };
    }

    /// Add file descriptor to kqueue
    pub fn addFd(self: *KqueueBackend, fd: i32, mask: EventMask) !void {
        const filters = eventMaskToKqueue(mask);

        if (filters.read) {
            const kevent = posix.system.kevent{
                .ident = @intCast(fd),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ADD | posix.system.EV.ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            const result = posix.system.kevent(self.kqueue_fd, &[_]posix.system.kevent{kevent}, &[_]posix.system.kevent{}, null);
            if (result < 0) {
                return posix.unexpectedErrno(@enumFromInt(-result));
            }
        }

        if (filters.write) {
            const kevent = posix.system.kevent{
                .ident = @intCast(fd),
                .filter = posix.system.EVFILT.WRITE,
                .flags = posix.system.EV.ADD | posix.system.EV.ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            const result = posix.system.kevent(self.kqueue_fd, &[_]posix.system.kevent{kevent}, &[_]posix.system.kevent{}, null);
            if (result < 0) {
                return posix.unexpectedErrno(@enumFromInt(-result));
            }
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
        const read_kevent = posix.system.kevent{
            .ident = @intCast(fd),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        // Remove write filter
        const write_kevent = posix.system.kevent{
            .ident = @intCast(fd),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        // Try to remove both filters - ignore errors if they don't exist
        _ = posix.system.kevent(self.kqueue_fd, &[_]posix.system.kevent{read_kevent}, &[_]posix.system.kevent{}, null);
        _ = posix.system.kevent(self.kqueue_fd, &[_]posix.system.kevent{write_kevent}, &[_]posix.system.kevent{}, null);
    }

    /// Poll for events
    pub fn poll(self: *KqueueBackend, events: []Event, timeout_ms: ?u32) !usize {
        var kevents: [1024]posix.system.kevent = undefined;

        const timeout_spec: ?posix.system.timespec = if (timeout_ms) |ms| .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        } else null;

        const num_events = posix.system.kevent(
            self.kqueue_fd,
            &[_]posix.system.kevent{},
            &kevents,
            if (timeout_spec) |*ts| ts else null,
        );

        if (num_events < 0) {
            return posix.unexpectedErrno(@enumFromInt(-num_events));
        }

        for (0..@intCast(num_events)) |i| {
            const kevent = kevents[i];

            if (kevent.filter == posix.system.EVFILT.TIMER) {
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
                    .data = .{ .size = @intCast(kevent.data) },
                };
            }
        }

        return @intCast(num_events);
    }

    /// Add a timer using kqueue EVFILT_TIMER
    pub fn addTimer(self: *KqueueBackend, timer_id: u32, ms: u64) !void {
        const kevent = posix.system.kevent{
            .ident = @intCast(timer_id),
            .filter = posix.system.EVFILT.TIMER,
            .flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.ONESHOT,
            .fflags = 0,
            .data = @intCast(ms),
            .udata = 0,
        };

        const result = posix.system.kevent(self.kqueue_fd, &[_]posix.system.kevent{kevent}, &[_]posix.system.kevent{}, null);
        if (result < 0) {
            return posix.unexpectedErrno(@enumFromInt(-result));
        }

        try self.timer_map.put(timer_id, {});
    }

    /// Add a recurring timer
    pub fn addRecurringTimer(self: *KqueueBackend, timer_id: u32, interval_ms: u64) !void {
        const kevent = posix.system.kevent{
            .ident = @intCast(timer_id),
            .filter = posix.system.EVFILT.TIMER,
            .flags = posix.system.EV.ADD | posix.system.EV.ENABLE,
            .fflags = 0,
            .data = @intCast(interval_ms),
            .udata = 0,
        };

        const result = posix.system.kevent(self.kqueue_fd, &[_]posix.system.kevent{kevent}, &[_]posix.system.kevent{}, null);
        if (result < 0) {
            return posix.unexpectedErrno(@enumFromInt(-result));
        }

        try self.timer_map.put(timer_id, {});
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *KqueueBackend, timer_id: u32) !void {
        if (self.timer_map.contains(timer_id)) {
            const kevent = posix.system.kevent{
                .ident = @intCast(timer_id),
                .filter = posix.system.EVFILT.TIMER,
                .flags = posix.system.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };

            _ = posix.system.kevent(self.kqueue_fd, &[_]posix.system.kevent{kevent}, &[_]posix.system.kevent{}, null);
            _ = self.timer_map.remove(timer_id);
        }
    }
};

test "KqueueBackend basic operations" {
    const allocator = std.testing.allocator;

    // Skip test on non-BSD/macOS platforms
    if (builtin.os.tag != .macos and builtin.os.tag != .freebsd and builtin.os.tag != .openbsd and builtin.os.tag != .netbsd) {
        return error.SkipZigTest;
    }

    var backend = try KqueueBackend.init(allocator);
    defer backend.deinit();

    // Test that kqueue_fd is valid
    try std.testing.expect(backend.kqueue_fd > 0);
}

test "EventMask to kqueue conversion" {
    const mask = EventMask{ .read = true, .write = true };
    const filters = KqueueBackend.eventMaskToKqueue(mask);

    try std.testing.expect(filters.read);
    try std.testing.expect(filters.write);
}