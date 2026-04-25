//! Linux epoll backend for zigzag event loop
//! Provides efficient I/O multiplexing using the epoll API

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const builtin = @import("builtin");
const EventLoop = @import("../root.zig").EventLoop;
const Event = @import("../root.zig").Event;
const EventType = @import("../root.zig").EventType;
const EventMask = @import("../root.zig").EventMask;
const Watch = @import("../root.zig").Watch;
const Timer = @import("../root.zig").Timer;

/// Create a timerfd (wrapper around raw syscall)
fn timerfd_create(clockid: linux.timerfd_clockid_t, flags: linux.TFD) !i32 {
    const rc = linux.timerfd_create(clockid, flags);
    if (rc > std.math.maxInt(i32)) {
        return posix.unexpectedErrno(@enumFromInt(rc));
    }
    return @intCast(rc);
}

/// Set timerfd time (wrapper around raw syscall)
fn timerfd_settime(fd: i32, flags: linux.TFD.TIMER, new_value: *const linux.itimerspec, old_value: ?*linux.itimerspec) !void {
    const rc = linux.timerfd_settime(fd, flags, new_value, old_value);
    if (rc != 0) {
        return posix.unexpectedErrno(@enumFromInt(rc));
    }
}

/// Epoll backend implementation
pub const EpollBackend = struct {
    epoll_fd: i32,
    allocator: std.mem.Allocator,

    // Timer management
    timer_fds: std.AutoHashMap(u32, i32), // timer_id -> timerfd
    timer_ids_by_fd: std.AutoHashMap(i32, u32), // timerfd -> timer_id

    /// Epoll event structure
    const EpollEvent = std.os.linux.epoll_event;

    /// Initialize the epoll backend
    pub fn init(allocator: std.mem.Allocator) !EpollBackend {
        const rc = std.os.linux.epoll_create1(0);
        const epoll_fd: i32 = if (rc > std.math.maxInt(i32))
            return std.posix.unexpectedErrno(@enumFromInt(rc))
        else
            @intCast(rc);
        errdefer std.Io.Threaded.closeFd(epoll_fd);

        var timer_fds = std.AutoHashMap(u32, i32).init(allocator);
        errdefer timer_fds.deinit();

        var timer_ids_by_fd = std.AutoHashMap(i32, u32).init(allocator);
        errdefer timer_ids_by_fd.deinit();

        return EpollBackend{
            .epoll_fd = epoll_fd,
            .allocator = allocator,
            .timer_fds = timer_fds,
            .timer_ids_by_fd = timer_ids_by_fd,
        };
    }

    /// Deinitialize the epoll backend
    pub fn deinit(self: *EpollBackend) void {
        // Close all timer file descriptors
        var iter = self.timer_fds.iterator();
        while (iter.next()) |entry| {
            std.Io.Threaded.closeFd(entry.value_ptr.*);
        }
        self.timer_ids_by_fd.deinit();
        self.timer_fds.deinit();

        std.Io.Threaded.closeFd(self.epoll_fd);
    }

    /// Convert EventMask to epoll events
    fn eventMaskToEpoll(mask: EventMask) u32 {
        var events: u32 = 0;
        if (mask.read) events |= std.os.linux.EPOLL.IN;
        if (mask.write) events |= std.os.linux.EPOLL.OUT;
        if (mask.io_error) events |= std.os.linux.EPOLL.ERR;
        if (mask.hangup) events |= std.os.linux.EPOLL.HUP;
        return events;
    }

    /// Convert epoll events to EventType
    fn epollToEventType(epoll_events: u32) EventType {
        if (epoll_events & std.os.linux.EPOLL.ERR != 0) return .io_error;
        if (epoll_events & std.os.linux.EPOLL.HUP != 0) return .hangup;
        if (epoll_events & std.os.linux.EPOLL.OUT != 0) return .write_ready;
        if (epoll_events & std.os.linux.EPOLL.IN != 0) return .read_ready;
        return .read_ready; // Default
    }

    /// Add file descriptor to epoll
    pub fn addFd(self: *EpollBackend, fd: i32, mask: EventMask) !void {
        var event = EpollEvent{
            .events = eventMaskToEpoll(mask),
            .data = .{ .fd = fd },
        };

        const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
        if (rc != 0) return std.posix.unexpectedErrno(@enumFromInt(rc));
    }

    /// Modify file descriptor in epoll
    pub fn modifyFd(self: *EpollBackend, fd: i32, mask: EventMask) !void {
        var event = EpollEvent{
            .events = eventMaskToEpoll(mask),
            .data = .{ .fd = fd },
        };

        const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event);
        if (rc != 0) return std.posix.unexpectedErrno(@enumFromInt(rc));
    }

    /// Remove file descriptor from epoll
    pub fn removeFd(self: *EpollBackend, fd: i32) !void {
        // Use raw syscall to avoid the unreachable in std.posix.epoll_ctl
        const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS and err != .NOENT and err != .BADF) {
            return std.posix.unexpectedErrno(err);
        }
    }

    /// Poll for events
    pub fn poll(self: *EpollBackend, events: []Event, timeout_ms: ?u32) !usize {
        if (events.len == 0) return 0;

        var epoll_events: [1024]EpollEvent = undefined;

        const timeout = if (timeout_ms) |ms| @as(i32, @intCast(ms)) else -1;
        const max_events: u32 = @intCast(@min(events.len, epoll_events.len));
        const rc = std.os.linux.epoll_wait(self.epoll_fd, &epoll_events, max_events, timeout);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc < 0) {
            const err = @as(std.posix.E, @enumFromInt(-signed_rc));
            if (err == .INTR) {
                return 0;
            }
            return std.posix.unexpectedErrno(err);
        }
        const num_events: usize = @intCast(rc);

        for (0..@intCast(num_events)) |i| {
            const epoll_event = epoll_events[i];
            const fd = epoll_event.data.fd;

            if (self.timer_ids_by_fd.get(fd)) |timer_id| {
                // Timer event - read from timerfd to reset it
                var buffer: u64 = 0;
                _ = posix.read(fd, std.mem.asBytes(&buffer)) catch {};

                events[i] = Event{
                    .fd = fd,
                    .type = .timer_expired,
                    .data = .{ .timer_id = timer_id },
                };
            } else {
                // Regular I/O event
                // For read events, we can determine how much data is available
                var available_bytes: usize = 0;
                if (epoll_event.events & std.os.linux.EPOLL.IN != 0) {
                    // Use ioctl FIONREAD to get available bytes for reading
                    var bytes_available: i32 = 0;
                    const result = std.os.linux.ioctl(fd, std.os.linux.T.FIONREAD, @intFromPtr(&bytes_available));
                    if (result == 0 and bytes_available >= 0) {
                        available_bytes = @intCast(bytes_available);
                    }
                }

                events[i] = Event{
                    .fd = fd,
                    .type = epollToEventType(epoll_event.events),
                    .data = .{ .size = available_bytes },
                };
            }
        }

        return @intCast(num_events);
    }

    /// Add a timer using timerfd
    pub fn addTimer(self: *EpollBackend, timer_id: u32, ms: u64) !void {
        // Create timerfd
        const timer_fd = try timerfd_create(linux.TIMERFD_CLOCK.MONOTONIC, std.mem.zeroes(linux.TFD));
        errdefer std.Io.Threaded.closeFd(timer_fd);

        // Set timer
        const new_value = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 }, // one-shot
            .it_value = .{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * 1_000_000),
            },
        };

        try timerfd_settime(timer_fd, std.mem.zeroes(linux.TFD.TIMER), &new_value, null);

        // Add to epoll
        var event = EpollEvent{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = timer_fd },
        };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, timer_fd, &event);
        if (rc != 0) return posix.unexpectedErrno(@enumFromInt(rc));

        // Store mapping
        try self.timer_fds.put(timer_id, timer_fd);
        try self.timer_ids_by_fd.put(timer_fd, timer_id);
    }

    /// Add a recurring timer using timerfd
    pub fn addRecurringTimer(self: *EpollBackend, timer_id: u32, interval_ms: u64) !void {
        // Create timerfd
        const timer_fd = try timerfd_create(linux.TIMERFD_CLOCK.MONOTONIC, std.mem.zeroes(linux.TFD));
        errdefer std.Io.Threaded.closeFd(timer_fd);

        // Set recurring timer
        const new_value = linux.itimerspec{
            .it_interval = .{
                .sec = @intCast(interval_ms / 1000),
                .nsec = @intCast((interval_ms % 1000) * 1_000_000),
            },
            .it_value = .{
                .sec = @intCast(interval_ms / 1000),
                .nsec = @intCast((interval_ms % 1000) * 1_000_000),
            },
        };

        try timerfd_settime(timer_fd, std.mem.zeroes(linux.TFD.TIMER), &new_value, null);

        // Add to epoll
        var event = EpollEvent{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = timer_fd },
        };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, timer_fd, &event);
        if (rc != 0) return posix.unexpectedErrno(@enumFromInt(rc));

        // Store mapping
        try self.timer_fds.put(timer_id, timer_fd);
        try self.timer_ids_by_fd.put(timer_fd, timer_id);
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *EpollBackend, timer_id: u32) !void {
        if (self.timer_fds.get(timer_id)) |timer_fd| {
            // Remove from epoll
            _ = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, timer_fd, null);

            // Close timerfd
            std.Io.Threaded.closeFd(timer_fd);

            // Remove from mapping
            _ = self.timer_fds.remove(timer_id);
            _ = self.timer_ids_by_fd.remove(timer_fd);
        }
    }
};

test "EpollBackend basic operations" {
    const allocator = std.testing.allocator;

    // Skip test on non-Linux platforms
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var backend = try EpollBackend.init(allocator);
    defer backend.deinit();

    // Test that epoll_fd is valid
    try std.testing.expect(backend.epoll_fd > 0);
}

test "EventMask to epoll conversion" {
    const mask = EventMask{ .read = true, .write = true };
    const epoll_events = EpollBackend.eventMaskToEpoll(mask);

    try std.testing.expect(epoll_events & std.os.linux.EPOLL.IN != 0);
    try std.testing.expect(epoll_events & std.os.linux.EPOLL.OUT != 0);
    try std.testing.expect(epoll_events & std.os.linux.EPOLL.ERR == 0);
}

test "poll respects caller event buffer length" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try EpollBackend.init(allocator);
    defer backend.deinit();

    var timer_fds: [2]i32 = undefined;
    for (&timer_fds) |*timer_fd| {
        timer_fd.* = try timerfd_create(linux.TIMERFD_CLOCK.MONOTONIC, std.mem.zeroes(linux.TFD));
        try backend.addFd(timer_fd.*, .{ .read = true });

        const timer_spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = 1_000_000 },
        };
        try timerfd_settime(timer_fd.*, std.mem.zeroes(linux.TFD.TIMER), &timer_spec, null);
    }
    defer {
        for (timer_fds) |timer_fd| {
            backend.removeFd(timer_fd) catch {};
            std.Io.Threaded.closeFd(timer_fd);
        }
    }

    var events: [1]Event = undefined;
    const count = try backend.poll(&events, 100);
    try std.testing.expectEqual(@as(usize, 1), count);
}
