//! io_uring backend for zigzag event loop
//! Provides maximum Linux performance with zero-copy operations

const std = @import("std");
const posix = std.posix;
const EventLoop = @import("../root.zig").EventLoop;
const Event = @import("../root.zig").Event;
const EventType = @import("../root.zig").EventType;
const EventMask = @import("../root.zig").EventMask;
const Watch = @import("../root.zig").Watch;
const Timer = @import("../root.zig").Timer;

/// io_uring backend implementation
pub const IoUringBackend = struct {
    ring: std.os.linux.IoUring,
    allocator: std.mem.Allocator,

    // File descriptor management
    watches: std.AutoHashMap(i32, Watch),

    // Timer management
    timers: std.AutoHashMap(u32, Timer),
    next_timer_id: u32 = 1,

    /// Initialize the io_uring backend
    pub fn init(allocator: std.mem.Allocator, entries: u16) !IoUringBackend {
        var ring = try std.os.linux.IoUring.init(entries, 0);
        errdefer ring.deinit();

        var watches = std.AutoHashMap(i32, Watch).init(allocator);
        errdefer watches.deinit();

        var timers = std.AutoHashMap(u32, Timer).init(allocator);
        errdefer timers.deinit();

        return IoUringBackend{
            .ring = ring,
            .allocator = allocator,
            .watches = watches,
            .timers = timers,
            .next_timer_id = 1,
        };
    }

    /// Deinitialize the io_uring backend
    pub fn deinit(self: *IoUringBackend) void {
        // Cancel all pending operations - TODO: implement proper cancellation
        // _ = self.ring.cancel(0, 0) catch {};

        // Note: No need to submit_and_wait since we haven't submitted any operations

        self.timers.deinit();
        self.watches.deinit();
        self.ring.deinit();
    }

    /// Convert EventMask to io_uring events
    fn eventMaskToIoUring(mask: EventMask) u32 {
        var events: u32 = 0;
        if (mask.read) events |= std.os.linux.IORING_OP.READ;
        if (mask.write) events |= std.os.linux.IORING_OP.WRITE;
        return events;
    }

    /// Add file descriptor to io_uring
    pub fn addFd(self: *IoUringBackend, fd: i32, mask: EventMask) !void {
        // Check if already watching this fd
        if (self.watches.contains(fd)) {
            return error.FdAlreadyWatched;
        }

        // For io_uring, we don't pre-register FDs like with epoll
        // Instead, we prepare SQEs (Submission Queue Entries) as needed
        // The actual I/O operations will be submitted when events occur

        // Create watch
        const watch = Watch{
            .fd = fd,
            .events = mask,
            .callback = null,
            .user_data = null,
        };

        // Store watch
        try self.watches.put(fd, watch);
    }

    /// Modify file descriptor in io_uring
    pub fn modifyFd(self: *IoUringBackend, fd: i32, mask: EventMask) !void {
        if (self.watches.getPtr(fd)) |watch| {
            watch.events = mask;
        } else {
            return error.FdNotWatched;
        }
    }

    /// Remove file descriptor from io_uring
    pub fn removeFd(self: *IoUringBackend, fd: i32) void {
        _ = self.watches.remove(fd);
    }

    /// Add a timer using io_uring timeout
    pub fn addTimer(self: *IoUringBackend, timer_id: u32, ms: u64) !void {
        const now = std.time.nanoTimestamp();
        const deadline_ns = now + (ms * std.time.ns_per_ms);

        // Prepare timeout SQE
        var sqe = self.ring.get_sqe() catch return error.SubmissionQueueFull;

        // Set up timeout operation
        var ts: std.os.linux.kernel_timespec = .{
            .sec = @intCast(@divTrunc(deadline_ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(deadline_ns, std.time.ns_per_s)),
        };
        sqe.prep_timeout(&ts, 0, 0);

        // Store user data to identify this as a timer
        sqe.user_data = timer_id;

        // Submit the SQE
        _ = try self.ring.submit();
    }

    /// Add a recurring timer
    pub fn addRecurringTimer(self: *IoUringBackend, timer_id: u32, interval_ms: u64) !void {
        // Prepare timeout SQE for recurring timer
        var sqe = self.ring.get_sqe() catch return error.SubmissionQueueFull;

        // Set up timeout operation with interval
        var ts: std.os.linux.kernel_timespec = .{
            .sec = @intCast(@divTrunc(interval_ms, 1000)),
            .nsec = @intCast((@mod(interval_ms, 1000)) * 1_000_000),
        };

        // Use multishot flag for recurring behavior if available
        sqe.prep_timeout(&ts, 0, std.os.linux.IORING_TIMEOUT_MULTISHOT);
        sqe.user_data = timer_id;

        _ = try self.ring.submit();
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *IoUringBackend, timer_id: u32) !void {
        // Cancel the timeout operation
        var sqe = self.ring.get_sqe() catch return error.SubmissionQueueFull;
        sqe.prep_cancel(timer_id, 0);
        _ = try self.ring.submit();
    }

    /// Poll for events
    pub fn poll(self: *IoUringBackend, events: []Event, timeout_ms: ?u32) !usize {
        // For now, implement a simple timeout if specified
        if (timeout_ms) |ms| {
            if (ms > 0) {
                std.time.sleep(ms * std.time.ns_per_ms);
            }
        }

        // Submit any pending SQEs - for now we don't have any prepared
        _ = self.ring.submit() catch 0;

        var event_count: usize = 0;

        // Check for completions without waiting
        while (self.ring.cq_ready() > 0 and event_count < events.len) {
            const cqe = try self.ring.copy_cqe();

            // Process based on result and user_data
            if (cqe.user_data > 0) {
                // Timer event (user_data contains timer_id)
                events[event_count] = Event{
                    .fd = -1, // timers don't have FDs
                    .type = .timer_expired,
                    .data = .{ .timer_id = @as(u32, @intCast(cqe.user_data)) },
                };
                event_count += 1;
            } else if (cqe.res >= 0) {
                // Successful I/O completion
                // For now, we'll use a simplified approach
                // In a real implementation, we'd track which FD this completion relates to
                events[event_count] = Event{
                    .fd = 0, // placeholder - would need proper FD mapping
                    .type = .read_ready,
                    .data = .{ .size = @intCast(cqe.res) },
                };
                event_count += 1;
            }
        }

        return event_count;
    }
};

test "IoUringBackend basic operations" {
    const allocator = std.testing.allocator;

    // Try to initialize io_uring, skip if not available
    var backend = IoUringBackend.init(allocator, 256) catch |err| {
        if (err == error.SystemOutdated or err == error.PermissionDenied) {
            return error.SkipZigTest;
        }
        return err;
    };
    defer backend.deinit();

    // Test that ring is initialized
    try std.testing.expect(backend.ring.fd > 0);
}
