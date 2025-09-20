//! Linux epoll backend for zigzag event loop
//! Provides efficient I/O multiplexing using the epoll API

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const EventLoop = @import("../root.zig").EventLoop;
const Event = @import("../root.zig").Event;
const EventType = @import("../root.zig").EventType;
const EventMask = @import("../root.zig").EventMask;
const Watch = @import("../root.zig").Watch;
const Timer = @import("../root.zig").Timer;

/// Epoll backend implementation
pub const EpollBackend = struct {
    epoll_fd: i32,
    allocator: std.mem.Allocator,

    // Timer management
    timer_fds: std.AutoHashMap(u32, i32), // timer_id -> timerfd

    /// Epoll event structure
    const EpollEvent = std.os.linux.epoll_event;

    /// Initialize the epoll backend
    pub fn init(allocator: std.mem.Allocator) !EpollBackend {
        const epoll_fd = try posix.epoll_create1(0);
        errdefer posix.close(epoll_fd);

        var timer_fds = std.AutoHashMap(u32, i32).init(allocator);
        errdefer timer_fds.deinit();

        return EpollBackend{
            .epoll_fd = epoll_fd,
            .allocator = allocator,
            .timer_fds = timer_fds,
        };
    }

    /// Deinitialize the epoll backend
    pub fn deinit(self: *EpollBackend) void {
        // Close all timer file descriptors
        var iter = self.timer_fds.iterator();
        while (iter.next()) |entry| {
            posix.close(entry.value_ptr.*);
        }
        self.timer_fds.deinit();

        posix.close(self.epoll_fd);
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

        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
    }

    /// Modify file descriptor in epoll
    pub fn modifyFd(self: *EpollBackend, fd: i32, mask: EventMask) !void {
        var event = EpollEvent{
            .events = eventMaskToEpoll(mask),
            .data = .{ .fd = fd },
        };

        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event);
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
        var epoll_events: [1024]EpollEvent = undefined;

        const timeout = if (timeout_ms) |ms| @as(i32, @intCast(ms)) else -1;
        const num_events = posix.epoll_wait(self.epoll_fd, &epoll_events, timeout);

        for (0..@intCast(num_events)) |i| {
            const epoll_event = epoll_events[i];
            const fd = epoll_event.data.fd;

            // Check if this is a timer event
            var is_timer = false;
            var timer_id: u32 = 0;

            var iter = self.timer_fds.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* == fd) {
                    is_timer = true;
                    timer_id = entry.key_ptr.*;
                    break;
                }
            }

            if (is_timer) {
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
                events[i] = Event{
                    .fd = fd,
                    .type = epollToEventType(epoll_event.events),
                    .data = .{ .size = 0 }, // TODO: Add actual data
                };
            }
        }

        return @intCast(num_events);
    }

    /// Add a timer using timerfd
    pub fn addTimer(self: *EpollBackend, timer_id: u32, ms: u64) !void {
        // Create timerfd
        const timer_fd = posix.timerfd_create(std.os.linux.TIMERFD_CLOCK.MONOTONIC, std.mem.zeroes(std.os.linux.TFD)) catch |err| {
            return err;
        };
        errdefer posix.close(timer_fd);

        // Set timer
        var new_value = std.os.linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 }, // one-shot
            .it_value = .{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * 1_000_000),
            },
        };

        posix.timerfd_settime(timer_fd, std.mem.zeroes(std.os.linux.TFD.TIMER), &new_value, null) catch |err| {
            return err;
        };

        // Add to epoll
        var event = EpollEvent{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = timer_fd },
        };
        std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, timer_fd, &event) catch |err| {
            return err;
        };

        // Store mapping
        try self.timer_fds.put(timer_id, timer_fd);
    }

    /// Add a recurring timer using timerfd
    pub fn addRecurringTimer(self: *EpollBackend, timer_id: u32, interval_ms: u64) !void {
        // Create timerfd
        const timer_fd = try posix.timerfd_create(std.os.linux.TIMERFD_CLOCK.MONOTONIC, std.mem.zeroes(std.os.linux.TFD));
        errdefer posix.close(timer_fd);

        // Set recurring timer
        var new_value = std.os.linux.itimerspec{
            .it_interval = .{
                .sec = @intCast(interval_ms / 1000),
                .nsec = @intCast((interval_ms % 1000) * 1_000_000),
            },
            .it_value = .{
                .sec = @intCast(interval_ms / 1000),
                .nsec = @intCast((interval_ms % 1000) * 1_000_000),
            },
        };

        try posix.timerfd_settime(timer_fd, std.mem.zeroes(std.os.linux.TFD.TIMER), &new_value, null);

        // Add to epoll
        var event = EpollEvent{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = timer_fd },
        };
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, timer_fd, &event);

        // Store mapping
        try self.timer_fds.put(timer_id, timer_fd);
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *EpollBackend, timer_id: u32) !void {
        if (self.timer_fds.get(timer_id)) |timer_fd| {
            // Remove from epoll
            std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, timer_fd, null) catch {};

            // Close timerfd
            posix.close(timer_fd);

            // Remove from mapping
            _ = self.timer_fds.remove(timer_id);
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
