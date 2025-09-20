//! zigzag - High-performance event loop for Zig
//! Optimized for terminal emulators with zsync integration

const std = @import("std");
const builtin = @import("builtin");

// Backend imports
const EpollBackend = @import("backend/epoll.zig").EpollBackend;
const IoUringBackend = @import("backend/io_uring.zig").IoUringBackend;

/// Platform backends for event loop
pub const Backend = enum {
    io_uring, // Linux 5.1+ (fastest)
    epoll, // Linux fallback
    kqueue, // macOS/BSD
    iocp, // Windows (future)

    /// Auto-detect the best available backend
    pub fn autoDetect() Backend {
        return switch (builtin.os.tag) {
            .linux => {
                // Try to initialize io_uring to check if it's available
                var test_ring = std.os.linux.IoUring.init(4, 0) catch {
                    return .epoll; // Fall back to epoll if io_uring fails
                };
                test_ring.deinit();
                return .io_uring; // io_uring is available
            },
            .macos, .ios, .freebsd, .openbsd, .netbsd => .kqueue,
            .windows => .iocp,
            else => .epoll, // Safe fallback
        };
    }
};

/// Event types for terminal and I/O operations
pub const EventType = enum {
    // I/O events
    read_ready,
    write_ready,
    io_error,
    hangup,

    // Terminal specific
    window_resize,
    focus_change,

    // Timer events
    timer_expired,

    // Process events
    child_exit,

    // Custom events
    user_event,
};

/// Event data union
pub const EventData = union {
    size: usize,
    signal: i32,
    timer_id: u32,
    user_data: *anyopaque,
};

/// Event structure
pub const Event = struct {
    fd: i32,
    type: EventType,
    data: EventData,
};

/// Event mask for file descriptor watching
pub const EventMask = packed struct {
    read: bool = false,
    write: bool = false,
    io_error: bool = false,
    hangup: bool = false,

    pub fn any(self: EventMask) bool {
        return self.read or self.write or self.io_error or self.hangup;
    }
};

/// Timer types
pub const TimerType = enum {
    one_shot,
    recurring,
};

/// Timer structure
pub const Timer = struct {
    id: u32,
    deadline: i64,
    interval: ?u64, // null for one-shot
    type: TimerType,
    callback: *const fn(?*anyopaque) void,
    user_data: ?*anyopaque,
};

/// File descriptor watch
pub const Watch = struct {
    fd: i32,
    events: EventMask,
    callback: ?*const fn (*const Watch, Event) void,
    user_data: ?*anyopaque,
};

/// Event loop options
pub const Options = struct {
    max_events: u32 = 1024,
    backend: ?Backend = null,
};

/// Main EventLoop structure
pub const EventLoop = struct {
    backend: Backend,
    options: Options,
    allocator: std.mem.Allocator,

    // Backend-specific data
    epoll_backend: ?EpollBackend = null,
    io_uring_backend: ?IoUringBackend = null,

    // Watch management
    watches: std.AutoHashMap(i32, Watch),
    next_watch_id: u32 = 0,

    // Timer management
    timers: std.AutoHashMap(u32, Timer),
    next_timer_id: u32 = 1,

    /// Initialize a new event loop
    pub fn init(allocator: std.mem.Allocator, options: Options) !EventLoop {
        // Auto-detect backend if not specified
        const backend = options.backend orelse Backend.autoDetect();

        var watches = std.AutoHashMap(i32, Watch).init(allocator);
        errdefer watches.deinit();

        var timers = std.AutoHashMap(u32, Timer).init(allocator);
        errdefer timers.deinit();

        var loop = EventLoop{
            .backend = backend,
            .options = options,
            .allocator = allocator,
            .epoll_backend = null,
            .io_uring_backend = null,
            .watches = watches,
            .next_watch_id = 0,
            .timers = timers,
            .next_timer_id = 1,
        };

        // Initialize the appropriate backend
        switch (backend) {
            .epoll => {
                loop.epoll_backend = try EpollBackend.init(allocator);
            },
            .io_uring => {
                loop.io_uring_backend = try IoUringBackend.init(allocator, @intCast(options.max_events));
            },
            .kqueue => {
                // TODO: Initialize kqueue backend
                return error.BackendNotImplemented;
            },
            .iocp => {
                // TODO: Initialize IOCP backend
                return error.BackendNotImplemented;
            },
        }

        return loop;
    }

    /// Deinitialize the event loop
    pub fn deinit(self: *EventLoop) void {
        // Cleanup backend-specific resources
        if (self.epoll_backend) |*backend| {
            backend.deinit();
        }
        if (self.io_uring_backend) |*backend| {
            backend.deinit();
        }

        // Cleanup watches
        self.watches.deinit();

        // Cleanup timers
        self.timers.deinit();
    }

    /// Poll for events (non-blocking)
    pub fn poll(self: *EventLoop, events: []Event, timeout_ms: ?u32) !usize {
        return switch (self.backend) {
            .epoll => {
                if (self.epoll_backend) |*backend| {
                    return backend.poll(events, timeout_ms);
                }
                return error.BackendNotInitialized;
            },
            .io_uring => {
                if (self.io_uring_backend) |*backend| {
                    return backend.poll(events, timeout_ms);
                }
                return error.BackendNotInitialized;
            },
            .kqueue => {
                // TODO: Implement kqueue polling
                return error.BackendNotImplemented;
            },
            .iocp => {
                // TODO: Implement IOCP polling
                return error.BackendNotImplemented;
            },
        };
    }

    /// Run one iteration of the event loop
    pub fn tick(self: *EventLoop) !bool {
        var events: [1024]Event = undefined;
        const count = try self.poll(&events, 0);
        if (count > 0) {
            // Process events
            for (events[0..count]) |event| {
                switch (event.type) {
                    .timer_expired => {
                        // Handle timer event
                        if (event.data.timer_id != 0) {
                            if (self.timers.getPtr(event.data.timer_id)) |timer| {
                                // Call timer callback
                                timer.callback(timer.user_data);

                                // For recurring timers, reschedule
                                if (timer.interval) |interval| {
                                    timer.deadline = std.time.milliTimestamp() + @as(i64, @intCast(interval));
                                    // Backend will handle rescheduling
                                } else {
                                    // Remove one-shot timer
                                    _ = self.timers.remove(timer.id);
                                }
                            }
                        }
                    },
                    else => {
                        // Handle I/O events
                        if (self.watches.get(event.fd)) |watch| {
                            if (watch.callback) |callback| {
                                callback(&watch, event);
                            }
                        }
                    },
                }
            }
        }
        return count > 0;
    }

    /// Run the event loop until stopped
    pub fn run(self: *EventLoop) !void {
        while (try self.tick()) {
            // Continue processing
        }
    }

    /// Stop the event loop
    pub fn stop(self: *EventLoop) void {
        _ = self;
        // TODO: Implement stop mechanism
    }

    /// Add file descriptor to watch
    pub fn addFd(self: *EventLoop, fd: i32, events: EventMask) !*const Watch {
        // Check if already watching this fd
        if (self.watches.contains(fd)) {
            return error.FdAlreadyWatched;
        }

        // Add to backend
        switch (self.backend) {
            .epoll => {
                if (self.epoll_backend) |*backend| {
                    try backend.addFd(fd, events);
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .io_uring => {
                if (self.io_uring_backend) |*backend| {
                    try backend.addFd(fd, events);
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .kqueue => {
                // TODO: Implement kqueue fd watching
                return error.BackendNotImplemented;
            },
            .iocp => {
                // TODO: Implement IOCP fd watching
                return error.BackendNotImplemented;
            },
        }

        // Create watch
        const watch = Watch{
            .fd = fd,
            .events = events,
            .callback = null,
            .user_data = null,
        };

        // Store watch
        try self.watches.put(fd, watch);

        // Return pointer to stored watch
        return &self.watches.get(fd).?;
    }

    /// Modify file descriptor watch
    pub fn modifyFd(self: *EventLoop, watch: *const Watch, events: EventMask) !void {
        // Update backend
        switch (self.backend) {
            .epoll => {
                if (self.epoll_backend) |*backend| {
                    try backend.modifyFd(watch.fd, events);
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .io_uring => {
                if (self.io_uring_backend) |*backend| {
                    try backend.modifyFd(watch.fd, events);
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .kqueue => {
                // TODO: Implement kqueue fd modification
                return error.BackendNotImplemented;
            },
            .iocp => {
                // TODO: Implement IOCP fd modification
                return error.BackendNotImplemented;
            },
        }

        // Update stored watch
        if (self.watches.getPtr(watch.fd)) |stored_watch| {
            stored_watch.events = events;
        }
    }

    /// Remove file descriptor watch
    pub fn removeFd(self: *EventLoop, watch: *const Watch) void {
        // Remove from backend
        switch (self.backend) {
            .epoll => {
                if (self.epoll_backend) |*backend| {
                    backend.removeFd(watch.fd) catch {};
                }
            },
            .io_uring => {
                if (self.io_uring_backend) |*backend| {
                    backend.removeFd(watch.fd);
                }
            },
            .kqueue => {
                // TODO: Implement kqueue fd removal
            },
            .iocp => {
                // TODO: Implement IOCP fd removal
            },
        }

        // Remove from watches
        _ = self.watches.remove(watch.fd);
    }

    /// Add a timer
    pub fn addTimer(self: *EventLoop, ms: u64, callback: *const fn(?*anyopaque) void) !Timer {
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const now = std.time.milliTimestamp();
        const deadline = now + @as(i64, @intCast(ms));

        const timer = Timer{
            .id = timer_id,
            .deadline = deadline,
            .interval = null,
            .type = .one_shot,
            .callback = callback,
            .user_data = null,
        };

        // Add to backend
        switch (self.backend) {
            .epoll => {
                if (self.epoll_backend) |*backend| {
                    try backend.addTimer(timer_id, ms);
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .io_uring => {
                if (self.io_uring_backend) |*backend| {
                    try backend.addTimer(timer_id, ms);
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .kqueue => {
                // TODO: Implement kqueue timer
                return error.BackendNotImplemented;
            },
            .iocp => {
                // TODO: Implement IOCP timer
                return error.BackendNotImplemented;
            },
        }

        // Store timer
        try self.timers.put(timer_id, timer);

        // Return the timer
        return self.timers.get(timer_id).?;
    }

    /// Add a recurring timer
    pub fn addRecurringTimer(self: *EventLoop, interval_ms: u64, callback: *const fn(?*anyopaque) void) !Timer {
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const now = std.time.milliTimestamp();
        const deadline = now + @as(i64, @intCast(interval_ms));

        const timer = Timer{
            .id = timer_id,
            .deadline = deadline,
            .interval = interval_ms,
            .type = .recurring,
            .callback = callback,
            .user_data = null,
        };

        // Add to backend
        switch (self.backend) {
            .epoll => {
                if (self.epoll_backend) |*backend| {
                    try backend.addRecurringTimer(timer_id, interval_ms);
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .io_uring => {
                if (self.io_uring_backend) |*backend| {
                    try backend.addRecurringTimer(timer_id, interval_ms);
                } else {
                    return error.BackendNotInitialized;
                }
            },
            .kqueue => {
                // TODO: Implement kqueue recurring timer
                return error.BackendNotImplemented;
            },
            .iocp => {
                // TODO: Implement IOCP recurring timer
                return error.BackendNotImplemented;
            },
        }

        // Store timer
        try self.timers.put(timer_id, timer);

        // Return pointer to stored timer
        return self.timers.get(timer_id).?;
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *EventLoop, timer: *const Timer) void {
        // Remove from backend
        switch (self.backend) {
            .epoll => {
                if (self.epoll_backend) |*backend| {
                    backend.cancelTimer(timer.id) catch {};
                }
            },
            .io_uring => {
                if (self.io_uring_backend) |*backend| {
                    backend.cancelTimer(timer.id) catch {};
                }
            },
            .kqueue => {
                // TODO: Implement kqueue timer cancellation
            },
            .iocp => {
                // TODO: Implement IOCP timer cancellation
            },
        }

        // Remove from timers
        _ = self.timers.remove(timer.id);
    }

    /// Set callback for a watch
    pub fn setCallback(self: *EventLoop, watch: *const Watch, callback: ?*const fn (*const Watch, Event) void) void {
        if (self.watches.getPtr(watch.fd)) |stored_watch| {
            stored_watch.callback = callback;
        }
    }
};

test "EventLoop basic initialization" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator, .{ .backend = .epoll });
    defer loop.deinit();

    try std.testing.expectEqual(Backend.epoll, loop.backend);
}

test "EventMask operations" {
    const mask = EventMask{ .read = true, .write = true };
    try std.testing.expect(mask.any());
    try std.testing.expect(mask.read);
    try std.testing.expect(mask.write);
    try std.testing.expect(!mask.io_error);
}

test "File descriptor watching" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator, .{ .backend = .epoll });
    defer loop.deinit();

    // Create a pipe for testing
    const pipe_result = try std.posix.pipe();
    const pipe_fds = pipe_result;

    // Add read watch
    const watch = try loop.addFd(pipe_fds[0], .{ .read = true });
    try std.testing.expectEqual(pipe_fds[0], watch.fd);
    try std.testing.expect(watch.events.read);

    // Test that watch is stored
    try std.testing.expect(loop.watches.contains(pipe_fds[0]));

    // Get the watch again to make sure we have a valid reference
    const stored_watch = loop.watches.get(pipe_fds[0]).?;
    try std.testing.expectEqual(pipe_fds[0], stored_watch.fd);

    // Remove watch before closing pipes
    loop.removeFd(&stored_watch);
    try std.testing.expect(!loop.watches.contains(pipe_fds[0]));

    // Now close the pipes
    std.posix.close(pipe_fds[0]);
    std.posix.close(pipe_fds[1]);
}

test "Timer functionality" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator, .{ .backend = .epoll });
    defer loop.deinit();

    // Callback function
    const callback = struct {
        pub fn timerCallback(user_data: ?*anyopaque) void {
            _ = user_data;
            // Just a simple callback
        }
    }.timerCallback;

    // Add a timer
    const timer = try loop.addTimer(100, callback);

    // Test that timer is stored
    try std.testing.expect(loop.timers.contains(timer.id));

    // Test that backend has the timer
    try std.testing.expect(loop.epoll_backend.?.timer_fds.contains(timer.id));

    // Cancel timer
    loop.cancelTimer(&timer);
    try std.testing.expect(!loop.timers.contains(timer.id));
    try std.testing.expect(!loop.epoll_backend.?.timer_fds.contains(timer.id));
}
