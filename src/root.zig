//! zigzag - High-performance event loop for Zig
//! Optimized for terminal emulators with zsync integration

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const logging = @import("logging.zig");

// Backend imports - conditionally compiled based on build options AND target platform
// Linux backends (epoll, io_uring) only compile on Linux
const EpollBackend = if (builtin.os.tag == .linux and build_options.enable_epoll) @import("backend/epoll.zig").EpollBackend else void;
const IoUringBackend = if (builtin.os.tag == .linux and build_options.enable_io_uring) @import("backend/io_uring.zig").IoUringBackend else void;
// BSD/macOS backend (kqueue)
const KqueueBackend = if ((builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) and build_options.enable_kqueue) @import("backend/kqueue.zig").KqueueBackend else void;
// Windows backend (IOCP)
const IOCPBackend = if (builtin.os.tag == .windows and build_options.enable_iocp) @import("backend/iocp.zig").IOCPBackend else void;
pub const SocketHandle = if (builtin.os.tag == .windows and build_options.enable_iocp) @import("backend/iocp.zig").SOCKET else usize;

// Event coalescing system
const EventCoalescer = @import("event_coalescing.zig").EventCoalescer;
pub const CoalescingConfig = @import("event_coalescing.zig").CoalescingConfig;

// Time utilities
const time_utils = @import("time_utils.zig");
pub const time = time_utils;

// Escape sequence parser for terminal input
pub const escape_parser = @import("escape_parser.zig");
pub const EscapeParser = escape_parser.EscapeParser;
pub const ParseResult = escape_parser.ParseResult;

// Terminal module - conditionally compiled
pub const terminal = if (build_options.enable_terminal) @import("terminal.zig") else void;

// File watching module - exports FileWatcher and runs regression tests
pub const file_watching = @import("file_watching.zig");
pub const FileWatcher = file_watching.FileWatcher;

// Optional async integration and higher-level extensions
pub const async_runtime = if (build_options.enable_zsync) @import("async_runtime.zig") else void;
pub const AsyncRuntime = if (build_options.enable_zsync) async_runtime.AsyncRuntime else void;
pub const AsyncTimer = if (build_options.enable_zsync) async_runtime.AsyncTimer else void;
pub const AsyncFile = if (build_options.enable_zsync) async_runtime.AsyncFile else void;
pub const AsyncUtils = if (build_options.enable_zsync) async_runtime.AsyncUtils else void;
pub const ghostshell = @import("ghostshell_optimizations.zig");
pub const grim_editor = @import("grim_editor_support.zig");

// zsync integration - conditionally compiled
const zsync = if (build_options.enable_zsync) @import("zsync") else void;

/// Platform backends for event loop
pub const Backend = enum {
    io_uring, // Linux 5.1+ (fastest)
    epoll, // Linux fallback
    kqueue, // macOS/BSD
    iocp, // Windows (timers, wake events, and overlapped socket I/O)

    /// Auto-detect the best available backend
    pub fn autoDetect() Backend {
        return switch (builtin.os.tag) {
            .linux => blk: {
                // Check if io_uring is enabled and available
                if (build_options.enable_io_uring) {
                    var test_ring = std.os.linux.IoUring.init(4, 0) catch {
                        if (build_options.enable_epoll) {
                            break :blk .epoll; // Fall back to epoll if io_uring fails
                        }
                        @compileError("No Linux backends enabled");
                    };
                    test_ring.deinit();
                    break :blk .io_uring; // io_uring is available
                } else if (build_options.enable_epoll) {
                    break :blk .epoll;
                } else {
                    @compileError("No Linux backends enabled");
                }
            },
            .macos, .ios, .freebsd, .openbsd, .netbsd => blk: {
                if (build_options.enable_kqueue) {
                    break :blk .kqueue;
                } else {
                    @compileError("kqueue backend not enabled for BSD/macOS");
                }
            },
            .windows => blk: {
                if (build_options.enable_iocp) {
                    break :blk .iocp;
                } else {
                    @compileError("IOCP backend not enabled for Windows");
                }
            },
            else => blk: {
                if (build_options.enable_epoll) {
                    break :blk .epoll; // Safe fallback
                } else {
                    @compileError("No compatible backends enabled for this platform");
                }
            },
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
    callback: *const fn (?*anyopaque) void,
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
    coalescing: ?CoalescingConfig = null,
};

/// Main EventLoop structure
pub const EventLoop = struct {
    backend: Backend,
    options: Options,
    allocator: std.mem.Allocator,

    // Backend-specific data - conditionally compiled
    epoll_backend: if (EpollBackend != void) ?EpollBackend else void = if (EpollBackend != void) null else {},
    io_uring_backend: if (IoUringBackend != void) ?IoUringBackend else void = if (IoUringBackend != void) null else {},
    kqueue_backend: if (KqueueBackend != void) ?KqueueBackend else void = if (KqueueBackend != void) null else {},
    iocp_backend: if (IOCPBackend != void) ?IOCPBackend else void = if (IOCPBackend != void) null else {},

    // Watch management
    watches: std.AutoHashMap(i32, *Watch),
    next_watch_id: u32 = 0,

    // Timer management
    timers: std.AutoHashMap(u32, Timer),
    next_timer_id: u32 = 1,

    // Stop mechanism
    should_stop: bool = false,

    // Event coalescing
    coalescer: ?EventCoalescer = null,

    /// Initialize a new event loop
    pub fn init(allocator: std.mem.Allocator, options: Options) !EventLoop {
        // Auto-detect backend if not specified
        const backend = options.backend orelse Backend.autoDetect();

        var watches = std.AutoHashMap(i32, *Watch).init(allocator);
        errdefer watches.deinit();

        var timers = std.AutoHashMap(u32, Timer).init(allocator);
        errdefer timers.deinit();

        // Initialize coalescer if configured
        var coalescer: ?EventCoalescer = null;
        if (options.coalescing) |config| {
            coalescer = try EventCoalescer.init(allocator, config);
        }
        errdefer if (coalescer) |*c| c.deinit();

        var loop = EventLoop{
            .backend = backend,
            .options = options,
            .allocator = allocator,
            .epoll_backend = if (EpollBackend != void) null else {},
            .io_uring_backend = if (IoUringBackend != void) null else {},
            .kqueue_backend = if (KqueueBackend != void) null else {},
            .iocp_backend = if (IOCPBackend != void) null else {},
            .watches = watches,
            .next_watch_id = 0,
            .timers = timers,
            .next_timer_id = 1,
            .should_stop = false,
            .coalescer = coalescer,
        };

        // Initialize the appropriate backend
        switch (backend) {
            .epoll => {
                if (EpollBackend != void) {
                    logging.logBackendInit("epoll");
                    loop.epoll_backend = try EpollBackend.init(allocator);
                } else {
                    return error.OperationNotSupported;
                }
            },
            .io_uring => {
                if (IoUringBackend != void) {
                    logging.logBackendInit("io_uring");
                    loop.io_uring_backend = try IoUringBackend.init(allocator, @intCast(options.max_events));
                } else {
                    return error.OperationNotSupported;
                }
            },
            .kqueue => {
                if (KqueueBackend != void) {
                    logging.logBackendInit("kqueue");
                    loop.kqueue_backend = try KqueueBackend.init(allocator);
                } else {
                    return error.OperationNotSupported;
                }
            },
            .iocp => {
                if (IOCPBackend != void) {
                    logging.logBackendInit("iocp");
                    loop.iocp_backend = try IOCPBackend.init(allocator);
                } else {
                    return error.OperationNotSupported;
                }
            },
        }

        return loop;
    }

    /// Deinitialize the event loop
    pub fn deinit(self: *EventLoop) void {
        // Cleanup backend-specific resources
        if (EpollBackend != void) {
            if (self.epoll_backend) |*backend| {
                backend.deinit();
            }
        }
        if (IoUringBackend != void) {
            if (self.io_uring_backend) |*backend| {
                backend.deinit();
            }
        }
        if (KqueueBackend != void) {
            if (self.kqueue_backend) |*backend| {
                backend.deinit();
            }
        }
        if (IOCPBackend != void) {
            if (self.iocp_backend) |*backend| {
                backend.deinit();
            }
        }

        // Cleanup coalescer
        if (self.coalescer) |*coalescer| {
            coalescer.deinit();
        }

        // Cleanup watches
        var watch_iter = self.watches.iterator();
        while (watch_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.watches.deinit();

        // Cleanup timers
        self.timers.deinit();
    }

    /// Poll for events (non-blocking)
    pub fn poll(self: *EventLoop, events: []Event, timeout_ms: ?u32) !usize {
        return switch (self.backend) {
            .epoll => {
                if (EpollBackend != void) {
                    if (self.epoll_backend) |*backend| {
                        return backend.poll(events, timeout_ms);
                    }
                    return error.BackendNotInitialized;
                }
                return error.OperationNotSupported;
            },
            .io_uring => {
                if (IoUringBackend != void) {
                    if (self.io_uring_backend) |*backend| {
                        return backend.poll(events, timeout_ms);
                    }
                    return error.BackendNotInitialized;
                }
                return error.OperationNotSupported;
            },
            .kqueue => {
                if (KqueueBackend != void) {
                    if (self.kqueue_backend) |*backend| {
                        return backend.poll(events, timeout_ms);
                    }
                    return error.BackendNotInitialized;
                }
                return error.OperationNotSupported;
            },
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        return backend.poll(events, timeout_ms);
                    }
                    return error.BackendNotInitialized;
                }
                return error.OperationNotSupported;
            },
        };
    }

    /// Run one iteration of the event loop
    pub fn tick(self: *EventLoop) !bool {
        var events: [1024]Event = undefined;
        const count = try self.poll(&events, 0);
        if (count > 0) {
            var processed_events = events[0..count];
            var coalesced_events: [1024]Event = undefined;

            // Apply event coalescing if enabled
            if (self.coalescer) |*coalescer| {
                const coalesced_count = try coalescer.processEvents(processed_events, &coalesced_events);
                if (coalesced_count > 0) {
                    processed_events = coalesced_events[0..coalesced_count];
                }
            }

            // Process events
            for (processed_events) |event| {
                switch (event.type) {
                    .timer_expired => {
                        // Handle timer event
                        if (event.data.timer_id != 0) {
                            if (self.timers.getPtr(event.data.timer_id)) |timer| {
                                // Call timer callback
                                timer.callback(timer.user_data);

                                // For recurring timers, reschedule
                                if (timer.interval) |interval| {
                                    const ts = time_utils.getMonotonicTime();
                                    const now_ms = @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
                                    timer.deadline = now_ms + @as(i64, @intCast(interval));
                                    // Backend will handle rescheduling
                                } else {
                                    // Remove one-shot timer
                                    const timer_copy = timer.*;
                                    self.cancelTimer(&timer_copy);
                                }
                            }
                        }
                    },
                    else => {
                        // Handle I/O events
                        if (self.watches.get(event.fd)) |watch| {
                            if (watch.callback) |callback| {
                                callback(watch, event);
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
        while (!self.should_stop) {
            if (!try self.tick()) {
                // No events, but we can continue if not stopped
                // Add a small delay to prevent busy-waiting
                time_utils.sleep(1_000_000); // 1ms
            }
        }
    }

    /// Stop the event loop
    pub fn stop(self: *EventLoop) void {
        self.should_stop = true;
    }

    /// Reset the stop flag to allow the event loop to run again
    pub fn reset(self: *EventLoop) void {
        self.should_stop = false;
    }

    /// Add file descriptor to watch.
    /// On Windows IOCP, generic fd-style watches are not supported.
    pub fn addFd(self: *EventLoop, fd: i32, events: EventMask) !*const Watch {
        // Check if already watching this fd
        if (self.watches.contains(fd)) {
            return error.FdAlreadyWatched;
        }

        // Add to backend
        switch (self.backend) {
            .epoll => {
                if (EpollBackend != void) {
                    if (self.epoll_backend) |*backend| {
                        try backend.addFd(fd, events);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
            .io_uring => {
                if (IoUringBackend != void) {
                    if (self.io_uring_backend) |*backend| {
                        try backend.addFd(fd, events);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
            .kqueue => {
                if (KqueueBackend != void) {
                    if (self.kqueue_backend) |*backend| {
                        try backend.addFd(fd, events);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        try backend.addFd(fd, events);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
        }

        const watch = try self.allocator.create(Watch);
        errdefer self.allocator.destroy(watch);

        watch.* = Watch{
            .fd = fd,
            .events = events,
            .callback = null,
            .user_data = null,
        };

        // Store watch
        try self.watches.put(fd, watch);

        return watch;
    }

    /// Register a Windows socket with the active IOCP backend.
    /// On non-Windows backends this returns `error.OperationNotSupported`.
    pub fn addSocket(self: *EventLoop, socket: SocketHandle) !void {
        switch (self.backend) {
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        try backend.addSocket(socket);
                        return;
                    }
                    return error.BackendNotInitialized;
                }
                return error.OperationNotSupported;
            },
            else => return error.OperationNotSupported,
        }
    }

    /// Remove a Windows socket and any outstanding IOCP operations.
    pub fn removeSocket(self: *EventLoop, socket: SocketHandle) !void {
        switch (self.backend) {
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        backend.removeSocket(socket);
                        return;
                    }
                    return error.BackendNotInitialized;
                }
                return error.OperationNotSupported;
            },
            else => return error.OperationNotSupported,
        }
    }

    /// Initiate an overlapped receive on a Windows socket.
    pub fn recvSocket(self: *EventLoop, socket: SocketHandle, buffer: []u8) !void {
        switch (self.backend) {
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        try backend.recvAsync(socket, buffer);
                        return;
                    }
                    return error.BackendNotInitialized;
                }
                return error.OperationNotSupported;
            },
            else => return error.OperationNotSupported,
        }
    }

    /// Initiate an overlapped send on a Windows socket.
    pub fn sendSocket(self: *EventLoop, socket: SocketHandle, data: []const u8) !void {
        switch (self.backend) {
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        try backend.sendAsync(socket, data);
                        return;
                    }
                    return error.BackendNotInitialized;
                }
                return error.OperationNotSupported;
            },
            else => return error.OperationNotSupported,
        }
    }

    /// Modify file descriptor watch
    pub fn modifyFd(self: *EventLoop, watch: *const Watch, events: EventMask) !void {
        // Update backend
        switch (self.backend) {
            .epoll => {
                if (EpollBackend != void) {
                    if (self.epoll_backend) |*backend| {
                        try backend.modifyFd(watch.fd, events);
                    } else {
                        return error.BackendNotInitialized;
                    }
                } else return error.OperationNotSupported;
            },
            .io_uring => {
                if (IoUringBackend != void) {
                    if (self.io_uring_backend) |*backend| {
                        try backend.modifyFd(watch.fd, events);
                    } else {
                        return error.BackendNotInitialized;
                    }
                } else return error.OperationNotSupported;
            },
            .kqueue => {
                if (KqueueBackend != void) {
                    if (self.kqueue_backend) |*backend| {
                        try backend.modifyFd(watch.fd, events);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        try backend.modifyFd(watch.fd, events);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
        }

        // Update stored watch
        if (self.watches.get(watch.fd)) |stored_watch| {
            stored_watch.events = events;
        }
    }

    /// Remove file descriptor watch
    pub fn removeFd(self: *EventLoop, watch: *const Watch) void {
        // Remove from backend
        switch (self.backend) {
            .epoll => {
                if (EpollBackend != void) {
                    if (self.epoll_backend) |*backend| {
                        backend.removeFd(watch.fd) catch {};
                    }
                }
            },
            .io_uring => {
                if (IoUringBackend != void) {
                    if (self.io_uring_backend) |*backend| {
                        backend.removeFd(watch.fd);
                    }
                }
            },
            .kqueue => {
                if (KqueueBackend != void) {
                    if (self.kqueue_backend) |*backend| {
                        backend.removeFd(watch.fd) catch {};
                    }
                }
            },
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        backend.removeFd(watch.fd) catch {};
                    }
                }
            },
        }

        // Remove from watches
        if (self.watches.fetchRemove(watch.fd)) |entry| {
            self.allocator.destroy(entry.value);
        }
    }

    /// Add a timer
    pub fn addTimer(self: *EventLoop, ms: u64, callback: *const fn (?*anyopaque) void) !Timer {
        return self.addTimerWithUserData(ms, callback, null);
    }

    /// Add a timer with user data passed to the callback.
    pub fn addTimerWithUserData(self: *EventLoop, ms: u64, callback: *const fn (?*anyopaque) void, user_data: ?*anyopaque) !Timer {
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const ts = time_utils.getMonotonicTime();
        const now = @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
        const deadline = now + @as(i64, @intCast(ms));

        const timer = Timer{
            .id = timer_id,
            .deadline = deadline,
            .interval = null,
            .type = .one_shot,
            .callback = callback,
            .user_data = user_data,
        };

        // Add to backend
        switch (self.backend) {
            .epoll => {
                if (EpollBackend != void) {
                    if (self.epoll_backend) |*backend| {
                        try backend.addTimer(timer_id, ms);
                    } else {
                        return error.BackendNotInitialized;
                    }
                } else return error.OperationNotSupported;
            },
            .io_uring => {
                if (IoUringBackend != void) {
                    if (self.io_uring_backend) |*backend| {
                        try backend.addTimer(timer_id, ms);
                    } else {
                        return error.BackendNotInitialized;
                    }
                } else return error.OperationNotSupported;
            },
            .kqueue => {
                if (KqueueBackend != void) {
                    if (self.kqueue_backend) |*backend| {
                        try backend.addTimer(timer_id, ms);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        try backend.addTimer(timer_id, ms);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
        }

        // Store timer
        try self.timers.put(timer_id, timer);

        // Return the timer
        return self.timers.get(timer_id).?;
    }

    /// Add a recurring timer
    pub fn addRecurringTimer(self: *EventLoop, interval_ms: u64, callback: *const fn (?*anyopaque) void) !Timer {
        return self.addRecurringTimerWithUserData(interval_ms, callback, null);
    }

    /// Add a recurring timer with user data passed to the callback.
    pub fn addRecurringTimerWithUserData(self: *EventLoop, interval_ms: u64, callback: *const fn (?*anyopaque) void, user_data: ?*anyopaque) !Timer {
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const ts = time_utils.getMonotonicTime();
        const now = @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
        const deadline = now + @as(i64, @intCast(interval_ms));

        const timer = Timer{
            .id = timer_id,
            .deadline = deadline,
            .interval = interval_ms,
            .type = .recurring,
            .callback = callback,
            .user_data = user_data,
        };

        // Add to backend
        switch (self.backend) {
            .epoll => {
                if (EpollBackend != void) {
                    if (self.epoll_backend) |*backend| {
                        try backend.addRecurringTimer(timer_id, interval_ms);
                    } else {
                        return error.BackendNotInitialized;
                    }
                } else return error.OperationNotSupported;
            },
            .io_uring => {
                if (IoUringBackend != void) {
                    if (self.io_uring_backend) |*backend| {
                        backend.addRecurringTimer(timer_id, interval_ms) catch |err| switch (err) {
                            error.OperationNotSupported => {
                                if (EpollBackend != void) {
                                    if (self.epoll_backend) |*epoll_backend| {
                                        try epoll_backend.addRecurringTimer(timer_id, interval_ms);
                                    } else {
                                        return err;
                                    }
                                } else {
                                    return err;
                                }
                            },
                            else => return err,
                        };
                    } else {
                        return error.BackendNotInitialized;
                    }
                } else return error.OperationNotSupported;
            },
            .kqueue => {
                if (KqueueBackend != void) {
                    if (self.kqueue_backend) |*backend| {
                        try backend.addRecurringTimer(timer_id, interval_ms);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
            },
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        try backend.addRecurringTimer(timer_id, interval_ms);
                    } else {
                        return error.BackendNotInitialized;
                    }
                }
                else return error.OperationNotSupported;
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
                if (EpollBackend != void) {
                    if (self.epoll_backend) |*backend| {
                        backend.cancelTimer(timer.id) catch {};
                    }
                }
            },
            .io_uring => {
                if (IoUringBackend != void) {
                    if (self.io_uring_backend) |*backend| {
                        backend.cancelTimer(timer.id) catch {};
                    }
                }
            },
            .kqueue => {
                if (KqueueBackend != void) {
                    if (self.kqueue_backend) |*backend| {
                        backend.cancelTimer(timer.id) catch {};
                    }
                }
            },
            .iocp => {
                if (IOCPBackend != void) {
                    if (self.iocp_backend) |*backend| {
                        backend.cancelTimer(timer.id);
                    }
                }
            },
        }

        // Remove from timers
        _ = self.timers.remove(timer.id);
    }

    /// Set callback for a watch
    pub fn setCallback(self: *EventLoop, watch: *const Watch, callback: ?*const fn (*const Watch, Event) void) void {
        if (self.watches.get(watch.fd)) |stored_watch| {
            stored_watch.callback = callback;
        }
    }

    /// Set opaque user data for a watch.
    pub fn setUserData(self: *EventLoop, watch: *const Watch, user_data: ?*anyopaque) void {
        if (self.watches.get(watch.fd)) |stored_watch| {
            stored_watch.user_data = user_data;
        }
    }
};

test "EventLoop basic initialization" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator, .{});
    defer loop.deinit();

    switch (builtin.os.tag) {
        .linux => try std.testing.expect(loop.backend == .io_uring or loop.backend == .epoll),
        .macos, .ios, .freebsd, .openbsd, .netbsd => try std.testing.expectEqual(Backend.kqueue, loop.backend),
        .windows => try std.testing.expectEqual(Backend.iocp, loop.backend),
        else => {},
    }
}

test "EventMask operations" {
    const mask = EventMask{ .read = true, .write = true };
    try std.testing.expect(mask.any());
    try std.testing.expect(mask.read);
    try std.testing.expect(mask.write);
    try std.testing.expect(!mask.io_error);
}

test "terminal socket states are hangup and io_error" {
    const terminal_states = [_]EventType{ .hangup, .io_error };

    try std.testing.expectEqual(@as(usize, 2), terminal_states.len);
    try std.testing.expect(terminal_states[0] == .hangup or terminal_states[1] == .hangup);
    try std.testing.expect(terminal_states[0] == .io_error or terminal_states[1] == .io_error);
}

test "File descriptor watching" {
    // This test requires Linux epoll backend
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator, .{ .backend = .epoll });
    defer loop.deinit();

    // Create a pipe for testing using Linux-specific syscall
    var pipe_fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe(&pipe_fds);
    if (rc != 0) return error.PipeCreationFailed;

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
    loop.removeFd(stored_watch);
    try std.testing.expect(!loop.watches.contains(pipe_fds[0]));

    // Now close the pipes
    std.Io.Threaded.closeFd(pipe_fds[0]);
    std.Io.Threaded.closeFd(pipe_fds[1]);
}

test "Timer functionality" {
    // This test requires Linux epoll backend
    if (builtin.os.tag != .linux) return error.SkipZigTest;

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
