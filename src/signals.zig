//! Signal handling for terminal emulators
//! Handles window resize, focus changes, and child process monitoring

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;

/// Signal event data
pub const SignalEvent = struct {
    signal: i32,
    pid: ?posix.pid_t = null, // For SIGCHLD
    status: ?i32 = null,      // For SIGCHLD
    timestamp: i64,
};

/// Signal handler configuration
pub const SignalConfig = struct {
    /// Handle window resize signals
    handle_winch: bool = true,
    /// Handle child process signals
    handle_chld: bool = true,
    /// Handle termination signals
    handle_term: bool = true,
    /// Handle user-defined signals
    handle_usr: bool = false,
    /// Use signalfd on Linux (more efficient)
    use_signalfd: bool = true,
};

/// Signal handler
pub const SignalHandler = struct {
    allocator: std.mem.Allocator,
    config: SignalConfig,
    signal_fd: ?i32 = null, // signalfd on Linux
    old_handlers: std.AutoHashMap(i32, ?*const fn (i32) callconv(.C) void),
    signal_mask: ?posix.sigset_t = null,

    pub fn init(allocator: std.mem.Allocator, config: SignalConfig) !SignalHandler {
        var old_handlers = std.AutoHashMap(i32, ?*const fn (i32) callconv(.C) void).init(allocator);
        errdefer old_handlers.deinit();

        var handler = SignalHandler{
            .allocator = allocator,
            .config = config,
            .old_handlers = old_handlers,
        };

        try handler.setup();
        return handler;
    }

    pub fn deinit(self: *SignalHandler) void {
        self.restore();
        self.old_handlers.deinit();
        if (self.signal_fd) |fd| {
            posix.close(fd);
        }
    }

    /// Setup signal handling
    fn setup(self: *SignalHandler) !void {
        if (builtin.os.tag == .linux and self.config.use_signalfd) {
            try self.setupSignalFd();
        } else {
            try self.setupTraditional();
        }
    }

    /// Setup using signalfd (Linux only)
    fn setupSignalFd(self: *SignalHandler) !void {
        // Create signal mask
        var mask: posix.sigset_t = undefined;
        _ = std.c.sigemptyset(&mask);

        if (self.config.handle_winch) {
            _ = std.c.sigaddset(&mask, posix.SIG.WINCH);
        }
        if (self.config.handle_chld) {
            _ = std.c.sigaddset(&mask, posix.SIG.CHLD);
        }
        if (self.config.handle_term) {
            _ = std.c.sigaddset(&mask, posix.SIG.TERM);
            _ = std.c.sigaddset(&mask, posix.SIG.INT);
        }
        if (self.config.handle_usr) {
            _ = std.c.sigaddset(&mask, posix.SIG.USR1);
            _ = std.c.sigaddset(&mask, posix.SIG.USR2);
        }

        // Block signals for current thread
        const result = std.c.pthread_sigmask(std.c.SIG.BLOCK, &mask, null);
        if (result != 0) {
            return error.SigmaskFailed;
        }

        // Create signalfd
        self.signal_fd = std.os.linux.signalfd(-1, &mask, 0);
        if (self.signal_fd == null or self.signal_fd.? < 0) {
            return error.SignalFdFailed;
        }

        self.signal_mask = mask;
    }

    /// Setup using traditional signal handlers
    fn setupTraditional(self: *SignalHandler) !void {
        const signals = [_]i32{
            if (self.config.handle_winch) posix.SIG.WINCH else -1,
            if (self.config.handle_chld) posix.SIG.CHLD else -1,
            if (self.config.handle_term) posix.SIG.TERM else -1,
            if (self.config.handle_term) posix.SIG.INT else -1,
            if (self.config.handle_usr) posix.SIG.USR1 else -1,
            if (self.config.handle_usr) posix.SIG.USR2 else -1,
        };

        for (signals) |sig| {
            if (sig == -1) continue;

            const old_handler = std.c.signal(sig, handleSignal);
            try self.old_handlers.put(sig, old_handler);
        }
    }

    /// Traditional signal handler (called from C)
    fn handleSignal(sig: i32) callconv(.C) void {
        // Just record the signal - processing happens in event loop
        global_signal_pending.set(sig);
    }

    /// Check for pending signals (signalfd)
    pub fn pollSignals(self: *SignalHandler, events: []Event) !usize {
        if (self.signal_fd) |fd| {
            return try self.pollSignalFd(fd, events);
        } else {
            return try self.pollTraditional(events);
        }
    }

    /// Poll signalfd for events
    fn pollSignalFd(self: *SignalHandler, fd: i32, events: []Event) !usize {
        _ = self;
        var count: usize = 0;

        while (count < events.len) {
            var si: std.os.linux.signalfd_siginfo = undefined;
            const bytes_read = posix.read(fd, std.mem.asBytes(&si)) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };

            if (bytes_read != @sizeOf(std.os.linux.signalfd_siginfo)) {
                break;
            }

            const event_type = switch (si.ssi_signo) {
                posix.SIG.WINCH => EventType.window_resize,
                posix.SIG.CHLD => EventType.child_exit,
                else => EventType.user_event,
            };

            events[count] = Event{
                .fd = fd,
                .type = event_type,
                .data = .{ .signal = @intCast(si.ssi_signo) },
            };
            count += 1;
        }

        return count;
    }

    /// Poll traditional signals
    fn pollTraditional(self: *SignalHandler, events: []Event) !usize {
        _ = self;
        var count: usize = 0;

        // Check each signal type
        const signals = [_]struct { sig: i32, event_type: EventType }{
            .{ .sig = posix.SIG.WINCH, .event_type = .window_resize },
            .{ .sig = posix.SIG.CHLD, .event_type = .child_exit },
            .{ .sig = posix.SIG.TERM, .event_type = .user_event },
            .{ .sig = posix.SIG.INT, .event_type = .user_event },
            .{ .sig = posix.SIG.USR1, .event_type = .user_event },
            .{ .sig = posix.SIG.USR2, .event_type = .user_event },
        };

        for (signals) |entry| {
            if (count >= events.len) break;

            if (global_signal_pending.check(entry.sig)) {
                events[count] = Event{
                    .fd = -1,
                    .type = entry.event_type,
                    .data = .{ .signal = entry.sig },
                };
                count += 1;
            }
        }

        return count;
    }

    /// Restore original signal handlers
    fn restore(self: *SignalHandler) void {
        var iter = self.old_handlers.iterator();
        while (iter.next()) |entry| {
            _ = std.c.signal(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Restore signal mask if using signalfd
        if (self.signal_mask) |mask| {
            _ = std.c.pthread_sigmask(std.c.SIG.UNBLOCK, &mask, null);
        }
    }

    /// Get signal file descriptor for event loop integration
    pub fn getSignalFd(self: *const SignalHandler) ?i32 {
        return self.signal_fd;
    }
};

/// Global signal tracking for traditional handlers
const SignalPending = struct {
    pending: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn set(self: *@This(), sig: i32) void {
        if (sig >= 0 and sig < 64) {
            const bit: u64 = @as(u64, 1) << @intCast(sig);
            _ = self.pending.fetchOr(bit, .monotonic);
        }
    }

    fn check(self: *@This(), sig: i32) bool {
        if (sig >= 0 and sig < 64) {
            const bit: u64 = @as(u64, 1) << @intCast(sig);
            const old = self.pending.fetchAnd(~bit, .monotonic);
            return (old & bit) != 0;
        }
        return false;
    }
};

var global_signal_pending = SignalPending{};

/// Child process monitor for tracking SIGCHLD
pub const ChildMonitor = struct {
    allocator: std.mem.Allocator,
    children: std.AutoHashMap(posix.pid_t, ChildInfo),

    const ChildInfo = struct {
        started: i64,
        command: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) ChildMonitor {
        return ChildMonitor{
            .allocator = allocator,
            .children = std.AutoHashMap(posix.pid_t, ChildInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ChildMonitor) void {
        // Free command strings
        var iter = self.children.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.command);
        }
        self.children.deinit();
    }

    /// Register a child process
    pub fn addChild(self: *ChildMonitor, pid: posix.pid_t, command: []const u8) !void {
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);

        const info = ChildInfo{
            .started = std.time.milliTimestamp(),
            .command = owned_command,
        };

        try self.children.put(pid, info);
    }

    /// Handle child exit
    pub fn handleChildExit(self: *ChildMonitor, pid: posix.pid_t) ?ChildInfo {
        if (self.children.fetchRemove(pid)) |kv| {
            return kv.value;
        }
        return null;
    }

    /// Wait for all children to exit
    pub fn waitAll(self: *ChildMonitor, timeout_ms: ?u32) !void {
        const start_time = std.time.milliTimestamp();

        while (self.children.count() > 0) {
            // Check timeout
            if (timeout_ms) |timeout| {
                const elapsed = std.time.milliTimestamp() - start_time;
                if (elapsed >= timeout) {
                    return error.Timeout;
                }
            }

            // Wait for any child
            var status: i32 = undefined;
            const pid = std.c.waitpid(-1, &status, std.c.WNOHANG);

            if (pid > 0) {
                _ = self.handleChildExit(pid);
            } else if (pid == 0) {
                // No child ready, wait a bit
                std.time.sleep(10_000_000); // 10ms
            } else {
                // Error or no more children
                break;
            }
        }
    }
};

/// Focus tracking for terminal applications
pub const FocusTracker = struct {
    has_focus: bool = true,
    last_focus_change: i64 = 0,

    pub fn init() FocusTracker {
        return FocusTracker{};
    }

    /// Update focus state
    pub fn setFocus(self: *FocusTracker, focused: bool) bool {
        const changed = self.has_focus != focused;
        if (changed) {
            self.has_focus = focused;
            self.last_focus_change = std.time.milliTimestamp();
        }
        return changed;
    }

    /// Check if application has focus
    pub fn hasFocus(self: *const FocusTracker) bool {
        return self.has_focus;
    }

    /// Get time since last focus change
    pub fn timeSinceLastChange(self: *const FocusTracker) i64 {
        return std.time.milliTimestamp() - self.last_focus_change;
    }
};

test "Signal handler setup" {
    const allocator = std.testing.allocator;

    var handler = try SignalHandler.init(allocator, .{
        .handle_winch = true,
        .handle_chld = true,
        .use_signalfd = false, // Use traditional for testing
    });
    defer handler.deinit();

    // Test that handlers were set up
    try std.testing.expect(handler.old_handlers.count() > 0);
}

test "Child monitor operations" {
    const allocator = std.testing.allocator;

    var monitor = ChildMonitor.init(allocator);
    defer monitor.deinit();

    // Add child
    try monitor.addChild(1234, "/bin/sh");
    try std.testing.expect(monitor.children.contains(1234));

    // Handle exit
    const info = monitor.handleChildExit(1234);
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("/bin/sh", info.?.command);
    try std.testing.expect(!monitor.children.contains(1234));
}

test "Focus tracker" {
    var tracker = FocusTracker.init();

    // Initial state
    try std.testing.expect(tracker.hasFocus());

    // Lose focus
    const changed = tracker.setFocus(false);
    try std.testing.expect(changed);
    try std.testing.expect(!tracker.hasFocus());

    // Set same state - no change
    const not_changed = tracker.setFocus(false);
    try std.testing.expect(!not_changed);
}