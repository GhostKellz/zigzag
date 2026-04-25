//! Terminal-specific features for zigzag event loop
//! Optimized for terminal emulators with PTY handling and signal management

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;
const time_utils = @import("time_utils.zig");

// PTY libc functions - not in std.posix, need to declare extern
const c = struct {
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
};

/// PTY (Pseudo Terminal) management
pub const Pty = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    slave_path: [:0]const u8,

    /// Create a new PTY pair
    pub fn create() !Pty {
        // Only supported on Unix-like systems
        if (builtin.os.tag == .windows) {
            return error.PlatformNotSupported;
        }

        // Open /dev/ptmx for master using libc open
        const master_fd = std.c.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (master_fd < 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }
        errdefer std.Io.Threaded.closeFd(master_fd);

        // Grant access to the slave pseudoterminal
        if (c.grantpt(master_fd) != 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }

        // Unlock the slave pseudoterminal
        if (c.unlockpt(master_fd) != 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }

        // Get the name of the slave pseudoterminal
        const slave_name_ptr = c.ptsname(master_fd) orelse {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        };
        const slave_path = std.mem.span(slave_name_ptr);

        // Open the slave pseudoterminal
        const slave_fd = std.c.open(slave_name_ptr, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (slave_fd < 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }
        errdefer std.Io.Threaded.closeFd(slave_fd);

        return Pty{
            .master_fd = master_fd,
            .slave_fd = slave_fd,
            .slave_path = slave_path,
        };
    }

    /// Close the PTY
    pub fn close(self: *Pty) void {
        std.Io.Threaded.closeFd(self.slave_fd);
        std.Io.Threaded.closeFd(self.master_fd);
    }

    /// Set terminal size
    pub fn setSize(self: *Pty, rows: u16, cols: u16) !void {
        var ws = std.c.winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const rc = std.c.ioctl(self.master_fd, std.c.T.IOCSWINSZ, @intFromPtr(&ws));
        if (rc != 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }
    }

    /// Get terminal size
    pub fn getSize(self: *Pty) !std.c.winsize {
        var ws: std.c.winsize = undefined;
        const rc = std.c.ioctl(self.master_fd, std.c.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }
        return ws;
    }
};

/// Signal handler for terminal events
pub const SignalHandler = struct {
    event_loop: *EventLoop,
    signal_fd: posix.fd_t,

    /// Initialize signal handler
    pub fn init(event_loop: *EventLoop) !SignalHandler {
        if (builtin.os.tag != .linux) {
            return error.PlatformNotSupported;
        }

        // Create signalfd for real-time signals
        var mask = posix.sigemptyset();
        posix.sigaddset(&mask, posix.SIG.WINCH);
        posix.sigaddset(&mask, posix.SIG.CHLD);
        posix.sigaddset(&mask, posix.SIG.INT);
        posix.sigaddset(&mask, posix.SIG.TERM);

        const signal_fd = try posix.signalfd(-1, &mask, .{ .CLOEXEC = true });
        errdefer std.Io.Threaded.closeFd(signal_fd);

        // Block these signals from default handlers
        posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

        return SignalHandler{
            .event_loop = event_loop,
            .signal_fd = signal_fd,
        };
    }

    /// Clean up signal handler
    pub fn deinit(self: *SignalHandler) void {
        std.Io.Threaded.closeFd(self.signal_fd);
    }

    /// Read and dispatch pending signals
    pub fn poll(self: *SignalHandler) !?Event {
        var info: std.os.linux.signalfd_siginfo = undefined;
        const bytes_read = std.c.read(self.signal_fd, @ptrCast(&info), @sizeOf(@TypeOf(info)));
        if (bytes_read < 0) {
            const err = @as(posix.E, @enumFromInt(std.c._errno().*));
            if (err == .AGAIN or err == .WOULDBLOCK) {
                return null;
            }
            return posix.unexpectedErrno(err);
        }

        if (bytes_read < @sizeOf(@TypeOf(info))) {
            return null;
        }

        return switch (@as(posix.SIG, @enumFromInt(info.signo))) {
            posix.SIG.WINCH => Event{
                .fd = self.signal_fd,
                .type = .window_resize,
                .data = .{ .signal = @intCast(info.signo) },
            },
            posix.SIG.CHLD => Event{
                .fd = self.signal_fd,
                .type = .child_exit,
                .data = .{ .signal = @intCast(info.signo) },
            },
            else => Event{
                .fd = self.signal_fd,
                .type = .user_event,
                .data = .{ .signal = @intCast(info.signo) },
            },
        };
    }
};

/// Terminal input processor
pub const InputProcessor = struct {
    event_loop: *EventLoop,
    input_fd: posix.fd_t,
    coalescer: ?*EventCoalescer,

    /// Initialize input processor
    pub fn init(event_loop: *EventLoop, input_fd: posix.fd_t) InputProcessor {
        return InputProcessor{
            .event_loop = event_loop,
            .input_fd = input_fd,
            .coalescer = null,
        };
    }

    /// Set event coalescer
    pub fn setCoalescer(self: *InputProcessor, coalescer: *EventCoalescer) void {
        self.coalescer = coalescer;
    }

    /// Process input events
    pub fn process(self: *InputProcessor) !void {
        var buf: [4096]u8 = undefined;
        const n = std.c.read(self.input_fd, &buf, buf.len);
        if (n < 0) {
            const err = @as(posix.E, @enumFromInt(std.c._errno().*));
            if (err == .AGAIN or err == .WOULDBLOCK) {
                return;
            }
            return posix.unexpectedErrno(err);
        }

        if (n > 0) {
            const event = Event{
                .fd = self.input_fd,
                .type = .read_ready,
                .data = .{ .size = @intCast(n) },
            };

            if (self.coalescer) |coalescer| {
                coalescer.addEvent(event) catch {};
            }
        }
    }
};

/// Terminal event coalescer for grouping related events
pub const EventCoalescer = struct {
    allocator: std.mem.Allocator,
    pending_events: std.ArrayList(Event),
    last_window_resize_ns: ?i128 = null,
    coalesce_window: i128 = 50_000_000, // 50ms in nanoseconds

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
                const now = time_utils.getMonotonicNs();

                if (self.last_window_resize_ns) |last| {
                    if (now - last < self.coalesce_window) {
                        // Replace existing resize event
                        for (self.pending_events.items) |*existing| {
                            if (existing.type == .window_resize) {
                                existing.* = event;
                                return;
                            }
                        }
                    }
                }

                self.last_window_resize_ns = now;
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
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return error.SkipZigTest;
    }

    var pty = Pty.create() catch |err| switch (err) {
        error.AccessDenied, error.DeviceNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer pty.close();

    // Test setting and getting size
    try pty.setSize(24, 80);
    const size = try pty.getSize();
    try std.testing.expectEqual(@as(u16, 24), size.ws_row);
    try std.testing.expectEqual(@as(u16, 80), size.ws_col);
}

test "EventCoalescer basic operations" {
    const allocator = std.testing.allocator;

    var coalescer = try EventCoalescer.init(allocator);
    defer coalescer.deinit();

    // Add multiple events
    const event1 = Event{ .fd = 1, .type = .read_ready, .data = .{ .size = 10 } };
    const event2 = Event{ .fd = -1, .type = .window_resize, .data = .{ .size = 0 } };
    const event3 = Event{ .fd = 2, .type = .write_ready, .data = .{ .size = 0 } };

    try coalescer.addEvent(event1);
    try coalescer.addEvent(event2);
    try coalescer.addEvent(event3);

    const events = try coalescer.drainEvents();
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
}
