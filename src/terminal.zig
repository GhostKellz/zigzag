//! Terminal-specific features for zigzag event loop
//! Optimized for terminal emulators with PTY handling and signal management

const std = @import("std");
const posix = std.posix;
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;

/// PTY (Pseudo Terminal) management
pub const Pty = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    slave_path: []const u8,

    /// Create a new PTY pair
    pub fn create() !Pty {
        // Open /dev/ptmx for master
        const master_fd = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        errdefer posix.close(master_fd);

        // Grant access to the slave pseudoterminal
        try posix.grantpt(master_fd);

        // Unlock the slave pseudoterminal
        try posix.unlockpt(master_fd);

        // Get the name of the slave pseudoterminal
        const slave_path = try posix.ptsname_r(master_fd);
        errdefer std.heap.page_allocator.free(slave_path);

        // Open the slave pseudoterminal
        const slave_fd = try posix.open(slave_path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        errdefer posix.close(slave_fd);

        return Pty{
            .master_fd = master_fd,
            .slave_fd = slave_fd,
            .slave_path = slave_path,
        };
    }

    /// Close the PTY
    pub fn close(self: *Pty) void {
        posix.close(self.slave_fd);
        posix.close(self.master_fd);
        std.heap.page_allocator.free(self.slave_path);
    }

    /// Set terminal size
    pub fn setSize(self: *Pty, rows: u16, cols: u16) !void {
        var winsize = posix.system.winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const rc = std.c.ioctl(self.master_fd, posix.TIOCSWINSZ, &winsize);
        if (rc != 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }
    }

    /// Get terminal size
    pub fn getSize(self: *Pty) !posix.system.winsize {
        var winsize: posix.system.winsize = undefined;
        const rc = std.c.ioctl(self.master_fd, posix.TIOCGWINSZ, &winsize);
        if (rc != 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }
        return winsize;
    }
};

/// Signal handler for terminal events
pub const SignalHandler = struct {
    event_loop: *EventLoop,
    signal_fd: posix.fd_t,

    /// Initialize signal handler
    pub fn init(event_loop: *EventLoop) !SignalHandler {
        // Create signalfd for real-time signals
        var mask = posix.empty_sigset;
        posix.sigaddset(&mask, posix.SIG.WINCH);
        posix.sigaddset(&mask, posix.SIG.CHLD);
        posix.sigaddset(&mask, posix.SIG.INT);
        posix.sigaddset(&mask, posix.SIG.TERM);

        const signal_fd = try posix.signalfd(-1, &mask, posix.S.OFD_CLOEXEC);
        errdefer posix.close(signal_fd);

        // Block these signals from default handlers
        try posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

        return SignalHandler{
            .event_loop = event_loop,
            .signal_fd = signal_fd,
        };
    }

    /// Close signal handler
    pub fn close(self: *SignalHandler) void {
        posix.close(self.signal_fd);
    }

    /// Register signal handler with event loop
    pub fn register(self: *SignalHandler) !void {
        const watch = try self.event_loop.addFd(self.signal_fd, .{ .read = true });
        self.event_loop.setCallback(watch, signalCallback);
        // Store self as user data - we'll need to update the watch structure for this
        if (self.event_loop.watches.getPtr(self.signal_fd)) |stored_watch| {
            stored_watch.user_data = @ptrCast(self);
        }
    }

    /// Signal callback function
    fn signalCallback(watch: *const @import("root.zig").Watch, event: Event) void {
        _ = event; // Event parameter not used in this callback
        const self = @as(*SignalHandler, @ptrCast(@alignCast(watch.user_data.?)));
        _ = self.handleSignal() catch {};
    }

    /// Handle incoming signals
    fn handleSignal(self: *SignalHandler) !void {
        var siginfo: posix.siginfo_t = undefined;
        const bytes_read = try posix.read(self.signal_fd, std.mem.asBytes(&siginfo));

        if (bytes_read == @sizeOf(posix.siginfo_t)) {
            const event = switch (siginfo.signo) {
                posix.SIG.WINCH => Event{
                    .fd = -1,
                    .type = .window_resize,
                    .data = .{ .size = 0 }, // Size will be queried by application
                },
                posix.SIG.CHLD => Event{
                    .fd = -1,
                    .type = .child_exit,
                    .data = .{ .signal = @intCast(siginfo.fields.common.first.pid) },
                },
                else => Event{
                    .fd = -1,
                    .type = .user_event,
                    .data = .{ .signal = @intCast(siginfo.signo) },
                },
            };

            // TODO: Dispatch event to application
            _ = event;
        }
    }
};

/// Terminal event coalescer for grouping related events
pub const EventCoalescer = struct {
    allocator: std.mem.Allocator,
    pending_events: std.ArrayList(Event),
    last_window_resize: ?std.time.Instant = null,
    coalesce_window: u64 = 50_000_000, // 50ms in nanoseconds

    pub fn init(allocator: std.mem.Allocator) !EventCoalescer {
        return EventCoalescer{
            .allocator = allocator,
            .pending_events = try std.ArrayList(Event).initCapacity(allocator, 16),
        };
    }

    pub fn deinit(self: *EventCoalescer) void {
        self.pending_events.deinit(self.allocator);
    }

    /// Add event to coalescer, potentially merging with existing events
    pub fn addEvent(self: *EventCoalescer, event: Event) !void {
        switch (event.type) {
            .window_resize => {
                // Coalesce window resize events
                const now = std.time.Instant.now() catch return;

                if (self.last_window_resize) |last| {
                    if (now.since(last) < self.coalesce_window) {
                        // Replace existing resize event
                        for (self.pending_events.items) |*existing| {
                            if (existing.type == .window_resize) {
                                existing.* = event;
                                return;
                            }
                        }
                    }
                }

                self.last_window_resize = now;
                try self.pending_events.append(self.allocator, event);
            },
            else => {
                try self.pending_events.append(self.allocator, event);
            },
        }
    }

    /// Get all pending events and clear the queue
    pub fn drainEvents(self: *EventCoalescer) ![]Event {
        return try self.pending_events.toOwnedSlice(self.allocator);
    }
};

test "PTY creation and basic operations" {
    // PTY creation should work on Unix systems
    var pty = Pty.create() catch |err| switch (err) {
        error.AccessDenied, error.DeviceNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer pty.close();

    // Test that FDs are valid
    try std.testing.expect(pty.master_fd > 0);
    try std.testing.expect(pty.slave_fd > 0);
    try std.testing.expect(pty.slave_path.len > 0);

    // Test size operations
    try pty.setSize(24, 80);
    const size = try pty.getSize();
    try std.testing.expectEqual(@as(u16, 24), size.ws_row);
    try std.testing.expectEqual(@as(u16, 80), size.ws_col);
}

test "Event coalescer" {
    var coalescer = try EventCoalescer.init(std.testing.allocator);
    defer coalescer.deinit();

    // Add some events
    const event1 = Event{ .fd = 1, .type = .read_ready, .data = .{ .size = 10 } };
    const event2 = Event{ .fd = 2, .type = .window_resize, .data = .{ .size = 0 } };
    const event3 = Event{ .fd = 2, .type = .window_resize, .data = .{ .size = 0 } }; // Should be coalesced

    try coalescer.addEvent(event1);
    try coalescer.addEvent(event2);
    try coalescer.addEvent(event3);

    const events = try coalescer.drainEvents();
    defer std.testing.allocator.free(events);

    // Should have 2 events (event3 coalesced with event2)
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(EventType.read_ready, events[0].type);
    try std.testing.expectEqual(EventType.window_resize, events[1].type);
}
