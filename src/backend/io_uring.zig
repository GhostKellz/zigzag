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
const time_utils = @import("../time_utils.zig");
// Define IORING_TIMEOUT_MULTISHOT constant (added in Linux 6.1)
// This constant may not be available in older versions of Zig's standard library
const IORING_TIMEOUT_MULTISHOT: u32 = (1 << 6);

/// io_uring backend implementation
pub const IoUringBackend = struct {
    ring: std.os.linux.IoUring,
    allocator: std.mem.Allocator,

    // File descriptor management
    watches: std.AutoHashMap(i32, Watch),

    // User data mapping (maps io_uring user_data to file descriptors)
    user_data_to_fd: std.AutoHashMap(u64, i32),
    fd_to_user_data: std.AutoHashMap(i32, u64),
    next_user_data: u64 = 1000, // Start at 1000 to avoid conflicts with timer IDs

    // Timer management
    timers: std.AutoHashMap(u32, Timer),
    next_timer_id: u32 = 1,

    /// Initialize the io_uring backend
    pub fn init(allocator: std.mem.Allocator, entries: u16) !IoUringBackend {
        var ring = try std.os.linux.IoUring.init(entries, 0);
        errdefer ring.deinit();

        var watches = std.AutoHashMap(i32, Watch).init(allocator);
        errdefer watches.deinit();

        var user_data_to_fd = std.AutoHashMap(u64, i32).init(allocator);
        errdefer user_data_to_fd.deinit();

        var fd_to_user_data = std.AutoHashMap(i32, u64).init(allocator);
        errdefer fd_to_user_data.deinit();

        var timers = std.AutoHashMap(u32, Timer).init(allocator);
        errdefer timers.deinit();

        return IoUringBackend{
            .ring = ring,
            .allocator = allocator,
            .watches = watches,
            .user_data_to_fd = user_data_to_fd,
            .fd_to_user_data = fd_to_user_data,
            .next_user_data = 1000,
            .timers = timers,
            .next_timer_id = 1,
        };
    }

    /// Deinitialize the io_uring backend
    pub fn deinit(self: *IoUringBackend) void {
        // Cancel all pending poll operations
        var iterator = self.user_data_to_fd.iterator();
        while (iterator.next()) |entry| {
            const user_data = entry.key_ptr.*;
            if (self.ring.get_sqe()) |sqe| {
                sqe.prep_cancel(user_data, 0);
            } else |_| {
                break;
            }
        }

        // Submit cancellations if any were queued
        if (self.user_data_to_fd.count() > 0) {
            _ = self.ring.submit() catch {};
        }

        self.timers.deinit();
        self.fd_to_user_data.deinit();
        self.user_data_to_fd.deinit();
        self.watches.deinit();
        self.ring.deinit();
    }

    /// Convert EventMask to io_uring poll events
    fn eventMaskToIoUring(mask: EventMask) u32 {
        var events: u32 = 0;
        if (mask.read) events |= std.os.linux.POLL.IN;
        if (mask.write) events |= std.os.linux.POLL.OUT;
        if (mask.io_error) events |= std.os.linux.POLL.ERR;
        if (mask.hangup) events |= std.os.linux.POLL.HUP;
        return events;
    }

    /// Add file descriptor to io_uring
    pub fn addFd(self: *IoUringBackend, fd: i32, mask: EventMask) !void {
        // Check if already watching this fd
        if (self.watches.contains(fd)) {
            return error.FdAlreadyWatched;
        }

        // Create watch
        const watch = Watch{
            .fd = fd,
            .events = mask,
            .callback = null,
            .user_data = null,
        };

        // Store watch
        try self.watches.put(fd, watch);

        // Set up a poll operation for this FD
        var sqe = try self.ring.get_sqe();
        const user_data = self.next_user_data;
        self.next_user_data += 1;

        // Map user_data to fd for later lookup
        try self.user_data_to_fd.put(user_data, fd);
        try self.fd_to_user_data.put(fd, user_data);

        // Setup poll operation
        const poll_events = eventMaskToIoUring(mask);
        sqe.prep_poll_add(fd, poll_events);
        sqe.user_data = user_data;

        // Submit the operation
        _ = try self.ring.submit();
    }

    /// Modify file descriptor in io_uring
    pub fn modifyFd(self: *IoUringBackend, fd: i32, mask: EventMask) !void {
        if (self.watches.getPtr(fd)) |watch| {
            watch.events = mask;

            if (self.fd_to_user_data.get(fd)) |user_data| {
                var sqe = self.ring.get_sqe() catch return error.SubmissionQueueFull;
                sqe.prep_cancel(user_data, 0);
                _ = self.ring.submit() catch {};

                sqe = try self.ring.get_sqe();
                sqe.prep_poll_add(fd, eventMaskToIoUring(mask));
                sqe.user_data = user_data;
                _ = try self.ring.submit();
                return;
            }

            return error.FdNotWatched;
        }

        return error.FdNotWatched;
    }

    /// Remove file descriptor from io_uring
    pub fn removeFd(self: *IoUringBackend, fd: i32) void {
        // Remove the watch
        _ = self.watches.remove(fd);

        if (self.fd_to_user_data.fetchRemove(fd)) |entry| {
            const user_data = entry.value;
            _ = self.user_data_to_fd.remove(user_data);

            // Cancel the poll operation
            var sqe = self.ring.get_sqe() catch return;
            sqe.prep_cancel(user_data, 0);
            _ = self.ring.submit() catch {};
        }
    }

    /// Add a timer using io_uring timeout
    pub fn addTimer(self: *IoUringBackend, timer_id: u32, ms: u64) !void {
        // Prepare timeout SQE
        var sqe = self.ring.get_sqe() catch return error.SubmissionQueueFull;

        // Set up relative timeout in kernel_timespec format
        var timeout_ts: std.os.linux.kernel_timespec = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
        sqe.prep_timeout(&timeout_ts, 0, 0);

        // Store timer_id as user_data to identify this timer when it fires
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
        sqe.prep_timeout(&ts, 0, IORING_TIMEOUT_MULTISHOT);
        sqe.user_data = timer_id;

        const submitted = self.ring.submit() catch |err| {
            if (err == error.InvalidArgument or err == error.OperationNotSupported) {
                return error.OperationNotSupported;
            }
            return err;
        };
        _ = submitted;
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
        if (events.len == 0) return 0;

        // Submit any pending SQEs first
        _ = self.ring.submit() catch 0;

        // Wait for events with timeout
        if (timeout_ms) |ms| {
            if (ms > 0) {
                // Set up a timeout operation using io_uring's timeout SQE
                var ts = std.os.linux.kernel_timespec{
                    .sec = @intCast(ms / 1000),
                    .nsec = @intCast((ms % 1000) * 1_000_000),
                };
                // Queue a timeout SQE with user_data = 0 (reserved for poll timeout)
                _ = self.ring.timeout(0, &ts, 0, 0) catch {};
                // Submit and wait for at least 1 event (timeout or actual event)
                _ = self.ring.submit_and_wait(1) catch 0;
            } else {
                // Non-blocking poll (ms == 0)
                _ = self.ring.submit() catch 0;
            }
        } else {
            // No timeout specified - block until at least one completion is available.
            _ = self.ring.submit_and_wait(1) catch 0;
        }

        var event_count: usize = 0;

        // Process completions
        while (self.ring.cq_ready() > 0 and event_count < events.len) {
            const cqe = try self.ring.copy_cqe();

            // Skip poll timeout completions (user_data = 0)
            if (cqe.user_data == 0) {
                continue;
            }

            // Determine if this is a timer or FD event
            if (cqe.user_data < 1000) {
                // Timer event (user_data < 1000 are timer IDs)
                events[event_count] = Event{
                    .fd = -1,
                    .type = .timer_expired,
                    .data = .{ .timer_id = @as(u32, @intCast(cqe.user_data)) },
                };
                event_count += 1;
            } else if (self.user_data_to_fd.get(cqe.user_data)) |fd| {
                // FD event - map back to file descriptor
                const event_type: EventType = if (cqe.res < 0)
                    .io_error
                else if (@as(u32, @intCast(cqe.res)) & std.os.linux.POLL.ERR != 0)
                    .io_error
                else if (@as(u32, @intCast(cqe.res)) & std.os.linux.POLL.HUP != 0)
                    .hangup
                else if (@as(u32, @intCast(cqe.res)) & std.os.linux.POLL.OUT != 0)
                    .write_ready
                else
                    .read_ready;
                const event_size: usize = if (cqe.res > 0 and event_type == .read_ready)
                    @intCast(cqe.res)
                else
                    0;
                events[event_count] = Event{
                    .fd = fd,
                    .type = event_type,
                    .data = .{ .size = event_size },
                };
                event_count += 1;

                // For multishot polls, we don't need to re-add
                // For one-shot polls, we need to re-add the poll operation
                if (self.watches.get(fd)) |watch| {
                    var sqe = self.ring.get_sqe() catch continue;
                    const poll_events = eventMaskToIoUring(watch.events);
                    sqe.prep_poll_add(fd, poll_events);
                    sqe.user_data = cqe.user_data;
                }
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

test "IoUringBackend tracks user data by fd" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = IoUringBackend.init(allocator, 64) catch |err| {
        if (err == error.SystemOutdated or err == error.PermissionDenied) return error.SkipZigTest;
        return err;
    };
    defer backend.deinit();

    var pipe_fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe(&pipe_fds);
    if (rc != 0) return error.PipeCreationFailed;
    defer {
        std.Io.Threaded.closeFd(pipe_fds[0]);
        std.Io.Threaded.closeFd(pipe_fds[1]);
    }

    try backend.addFd(pipe_fds[0], .{ .read = true });
    try std.testing.expect(backend.fd_to_user_data.contains(pipe_fds[0]));

    try backend.modifyFd(pipe_fds[0], .{ .read = true, .write = true });
    try std.testing.expect(backend.fd_to_user_data.contains(pipe_fds[0]));

    var events: [4]Event = undefined;
    _ = try backend.poll(&events, 0);

    backend.removeFd(pipe_fds[0]);
    _ = try backend.poll(&events, 0);
    try std.testing.expect(!backend.fd_to_user_data.contains(pipe_fds[0]));
}
