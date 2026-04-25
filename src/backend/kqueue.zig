//! macOS/BSD kqueue backend for zigzag event loop
//! Status: Production-ready
//!
//! Provides efficient I/O multiplexing using the kqueue API.
//! Supports file descriptor watching, one-shot timers, and recurring timers.

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

        // Use libc kqueue() function for cross-compilation compatibility
        const kqueue_fd = c.kqueue();
        if (kqueue_fd < 0) {
            return posix.unexpectedErrno(@enumFromInt(c._errno().*));
        }
        errdefer std.Io.Threaded.closeFd(kqueue_fd);

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
        std.Io.Threaded.closeFd(self.kqueue_fd);
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
            const result = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
            if (result < 0) {
                return error.KQueueRegistrationFailed;
            }
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
            const result = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
            if (result < 0) {
                // If we already added read filter, try to clean it up
                if (filters.read) {
                    const cleanup = c.Kevent{
                        .ident = @intCast(fd),
                        .filter = c.EVFILT.READ,
                        .flags = c.EV.DELETE,
                        .fflags = 0,
                        .data = 0,
                        .udata = 0,
                    };
                    _ = std.c.kevent(self.kqueue_fd, &cleanup, 1, null, 0, null);
                }
                return error.KQueueRegistrationFailed;
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
    ///
    /// Uses best-effort cleanup semantics. This intentionally ignores kevent
    /// errors because:
    /// 1. The filter may not exist (only read or write was registered)
    /// 2. The fd may already be closed (which auto-removes from kqueue)
    /// 3. This is a cleanup path where best-effort removal is acceptable
    ///
    /// Edge cases handled:
    /// - fd closed before removeWatch: kqueue auto-removes, EV_DELETE returns ENOENT
    /// - Timer cancelled while callback pending: kqueue handles gracefully
    /// - kqueue fd closed during poll: returns EBADF, caught by poll error handling
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

        // Best-effort removal - errors are expected if filter wasn't registered
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

test "kqueue add/remove fd watch" {
    if (!supports_kqueue) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try KqueueBackend.init(allocator);
    defer backend.deinit();

    // Create a pipe for testing
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeCreationFailed;
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // Add read watch on read end of pipe
    try backend.addFd(fds[0], EventMask{ .read = true });

    // Remove the watch
    try backend.removeFd(fds[0]);
}

test "kqueue pipe readability event" {
    if (!supports_kqueue) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try KqueueBackend.init(allocator);
    defer backend.deinit();

    // Create a pipe
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeCreationFailed;
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // Watch read end for readability
    try backend.addFd(fds[0], EventMask{ .read = true });

    // Write data to pipe
    const msg = "test";
    _ = c.write(fds[1], msg.ptr, msg.len);

    // Poll should return read event
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 100);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(EventType.read_ready, events[0].type);
    try std.testing.expectEqual(fds[0], events[0].fd);
}

test "kqueue one-shot timer" {
    if (!supports_kqueue) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try KqueueBackend.init(allocator);
    defer backend.deinit();

    // Add 50ms one-shot timer
    try backend.addTimer(42, 50);

    // Poll with 200ms timeout - should get timer event
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 200);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(EventType.timer_expired, events[0].type);
    try std.testing.expectEqual(@as(u32, 42), events[0].data.timer_id);
}

test "kqueue recurring timer" {
    if (!supports_kqueue) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try KqueueBackend.init(allocator);
    defer backend.deinit();

    // Add 30ms recurring timer
    try backend.addRecurringTimer(99, 30);

    // Should get multiple timer events
    var events: [16]Event = undefined;
    var timer_count: usize = 0;

    for (0..3) |_| {
        const count = try backend.poll(&events, 100);
        for (0..count) |i| {
            if (events[i].type == .timer_expired and events[i].data.timer_id == 99) {
                timer_count += 1;
            }
        }
    }

    // Should have received at least 2 timer events
    try std.testing.expect(timer_count >= 2);

    // Cancel the timer
    try backend.cancelTimer(99);
}

test "kqueue timer cancellation" {
    if (!supports_kqueue) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try KqueueBackend.init(allocator);
    defer backend.deinit();

    // Add a timer
    try backend.addTimer(123, 500);

    // Cancel it immediately
    try backend.cancelTimer(123);

    // Poll with short timeout - should NOT get timer event
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 50);

    // No timer events should be received
    for (0..count) |i| {
        if (events[i].type == .timer_expired and events[i].data.timer_id == 123) {
            return error.TimerNotCancelled;
        }
    }
}