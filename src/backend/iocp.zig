//! Windows IOCP backend for zigzag event loop
//! Provides efficient I/O multiplexing using I/O Completion Ports

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const EventLoop = @import("../root.zig").EventLoop;
const Event = @import("../root.zig").Event;
const EventType = @import("../root.zig").EventType;
const EventMask = @import("../root.zig").EventMask;
const Watch = @import("../root.zig").Watch;
const Timer = @import("../root.zig").Timer;

/// Only compile this backend on Windows
const supports_iocp = switch (builtin.os.tag) {
    .windows => true,
    else => false,
};

/// IOCP backend implementation
pub const IOCPBackend = if (supports_iocp) struct {
    iocp_handle: windows.HANDLE,
    allocator: std.mem.Allocator,

    // Operation tracking
    operations: std.AutoHashMap(usize, IOCPOperation),
    next_operation_id: usize = 1,

    // Timer management using Windows Timer Queue
    timer_queue: ?windows.HANDLE = null,
    timers: std.AutoHashMap(u32, windows.HANDLE),

    /// IOCP operation types
    const OperationType = enum {
        read,
        write,
        accept,
        connect,
        timer,
    };

    /// IOCP operation context
    const IOCPOperation = struct {
        overlapped: windows.OVERLAPPED,
        operation_id: usize,
        operation_type: OperationType,
        fd: windows.HANDLE,
        buffer: ?[]u8 = null,
        bytes_transferred: u32 = 0,
        error_code: u32 = 0,
    };

    /// Initialize the IOCP backend
    pub fn init(allocator: std.mem.Allocator) !IOCPBackend {
        if (builtin.os.tag != .windows) {
            return error.PlatformNotSupported;
        }

        // Create I/O Completion Port
        const iocp_handle = windows.kernel32.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            0,
            0, // Use number of processors
        ) orelse return error.CreateIOCPFailed;

        errdefer windows.CloseHandle(iocp_handle);

        // Create timer queue
        const timer_queue = windows.kernel32.CreateTimerQueue();
        errdefer if (timer_queue) |tq| windows.kernel32.DeleteTimerQueue(tq);

        var operations = std.AutoHashMap(usize, IOCPOperation).init(allocator);
        errdefer operations.deinit();

        var timers = std.AutoHashMap(u32, windows.HANDLE).init(allocator);
        errdefer timers.deinit();

        return IOCPBackend{
            .iocp_handle = iocp_handle,
            .allocator = allocator,
            .operations = operations,
            .timer_queue = timer_queue,
            .timers = timers,
        };
    }

    /// Deinitialize the IOCP backend
    pub fn deinit(self: *IOCPBackend) void {
        // Cancel all pending operations
        var iter = self.operations.iterator();
        while (iter.next()) |entry| {
            const op = entry.value_ptr;
            _ = windows.kernel32.CancelIoEx(op.fd, &op.overlapped);
        }

        // Clean up timers
        if (self.timer_queue) |tq| {
            _ = windows.kernel32.DeleteTimerQueue(tq);
        }

        self.timers.deinit();
        self.operations.deinit();
        windows.CloseHandle(self.iocp_handle);
    }

    /// Convert EventMask to Windows events (conceptual)
    fn eventMaskToWindows(mask: EventMask) struct { read: bool, write: bool } {
        return .{
            .read = mask.read,
            .write = mask.write,
        };
    }

    /// Associate file handle with IOCP
    pub fn addFd(self: *IOCPBackend, fd: i32, mask: EventMask) !void {
        // Convert file descriptor to Windows HANDLE
        const handle = @as(windows.HANDLE, @ptrFromInt(@as(usize, @intCast(fd))));

        // Associate handle with IOCP
        const result = windows.kernel32.CreateIoCompletionPort(
            handle,
            self.iocp_handle,
            @intFromPtr(handle), // Use handle as completion key
            0,
        );

        if (result != self.iocp_handle) {
            return error.AssociateIOCPFailed;
        }

        // Start initial read/write operations based on mask
        const events = eventMaskToWindows(mask);
        if (events.read) {
            try self.startReadOperation(handle);
        }
        if (events.write) {
            try self.startWriteOperation(handle);
        }
    }

    /// Start a read operation
    fn startReadOperation(self: *IOCPBackend, handle: windows.HANDLE) !void {
        const operation_id = self.next_operation_id;
        self.next_operation_id += 1;

        // Allocate buffer for read
        const buffer = try self.allocator.alloc(u8, 4096);
        errdefer self.allocator.free(buffer);

        var operation = IOCPOperation{
            .overlapped = std.mem.zeroes(windows.OVERLAPPED),
            .operation_id = operation_id,
            .operation_type = .read,
            .fd = handle,
            .buffer = buffer,
        };

        try self.operations.put(operation_id, operation);

        // Start overlapped read
        var bytes_read: u32 = 0;
        const success = windows.kernel32.ReadFile(
            handle,
            buffer.ptr,
            @intCast(buffer.len),
            &bytes_read,
            &operation.overlapped,
        );

        if (success == 0) {
            const err = windows.kernel32.GetLastError();
            if (err != windows.Win32Error.IO_PENDING) {
                _ = self.operations.remove(operation_id);
                self.allocator.free(buffer);
                return error.ReadFileFailed;
            }
        }
    }

    /// Start a write operation
    fn startWriteOperation(self: *IOCPBackend, handle: windows.HANDLE) !void {
        _ = self;
        _ = handle;
        // TODO: Implement write operation initiation
        // This would typically be triggered by actual write requests
    }

    /// Modify file descriptor in IOCP
    pub fn modifyFd(self: *IOCPBackend, fd: i32, mask: EventMask) !void {
        // For IOCP, we need to cancel existing operations and start new ones
        try self.removeFd(fd);
        try self.addFd(fd, mask);
    }

    /// Remove file descriptor from IOCP
    pub fn removeFd(self: *IOCPBackend, fd: i32) !void {
        const handle = @as(windows.HANDLE, @ptrFromInt(@as(usize, @intCast(fd))));

        // Cancel all operations for this handle
        var iter = self.operations.iterator();
        var to_remove = std.ArrayList(usize).init(self.allocator);
        defer to_remove.deinit();

        while (iter.next()) |entry| {
            const op = entry.value_ptr;
            if (op.fd == handle) {
                _ = windows.kernel32.CancelIoEx(handle, &op.overlapped);
                try to_remove.append(entry.key_ptr.*);
                if (op.buffer) |buffer| {
                    self.allocator.free(buffer);
                }
            }
        }

        // Remove operations
        for (to_remove.items) |op_id| {
            _ = self.operations.remove(op_id);
        }
    }

    /// Poll for events
    pub fn poll(self: *IOCPBackend, events: []Event, timeout_ms: ?u32) !usize {
        var completion_entries: [64]windows.OVERLAPPED_ENTRY = undefined;
        var removed_count: u32 = undefined;

        const timeout = if (timeout_ms) |ms| ms else windows.INFINITE;

        const success = windows.kernel32.GetQueuedCompletionStatusEx(
            self.iocp_handle,
            &completion_entries,
            @intCast(completion_entries.len),
            &removed_count,
            timeout,
            0, // No alertable wait
        );

        if (success == 0) {
            const err = windows.kernel32.GetLastError();
            if (err == windows.Win32Error.WAIT_TIMEOUT) {
                return 0; // No events
            }
            return error.GetQueuedCompletionStatusFailed;
        }

        const count = @min(removed_count, @as(u32, @intCast(events.len)));
        for (0..count) |i| {
            const entry = completion_entries[i];
            const overlapped = @as(*windows.OVERLAPPED, @ptrCast(entry.lpOverlapped));

            // Find operation by overlapped pointer
            var operation: ?*IOCPOperation = null;
            var iter = self.operations.iterator();
            while (iter.next()) |op_entry| {
                if (&op_entry.value_ptr.overlapped == overlapped) {
                    operation = op_entry.value_ptr;
                    break;
                }
            }

            if (operation) |op| {
                events[i] = Event{
                    .fd = @intCast(@intFromPtr(op.fd)),
                    .type = switch (op.operation_type) {
                        .read => .read_ready,
                        .write => .write_ready,
                        .timer => .timer_expired,
                        else => .user_event,
                    },
                    .data = .{ .size = entry.dwNumberOfBytesTransferred },
                };

                // Clean up completed operation
                if (op.buffer) |buffer| {
                    self.allocator.free(buffer);
                }
                _ = self.operations.remove(op.operation_id);

                // Restart operation if it's a continuous one (like reading)
                if (op.operation_type == .read) {
                    self.startReadOperation(op.fd) catch {};
                }
            } else {
                // Unknown operation, create generic event
                events[i] = Event{
                    .fd = @intCast(@intFromPtr(entry.lpCompletionKey)),
                    .type = .user_event,
                    .data = .{ .size = entry.dwNumberOfBytesTransferred },
                };
            }
        }

        return count;
    }

    /// Add a timer using Windows Timer Queue
    pub fn addTimer(self: *IOCPBackend, timer_id: u32, ms: u64) !void {
        if (self.timer_queue == null) {
            return error.TimerQueueNotInitialized;
        }

        var timer_handle: windows.HANDLE = undefined;
        const success = windows.kernel32.CreateTimerQueueTimer(
            &timer_handle,
            self.timer_queue,
            timerCallback,
            @ptrFromInt(timer_id), // Pass timer_id as context
            @intCast(ms),
            0, // One-shot timer
            0, // No flags
        );

        if (success == 0) {
            return error.CreateTimerFailed;
        }

        try self.timers.put(timer_id, timer_handle);
    }

    /// Add a recurring timer
    pub fn addRecurringTimer(self: *IOCPBackend, timer_id: u32, interval_ms: u64) !void {
        if (self.timer_queue == null) {
            return error.TimerQueueNotInitialized;
        }

        var timer_handle: windows.HANDLE = undefined;
        const success = windows.kernel32.CreateTimerQueueTimer(
            &timer_handle,
            self.timer_queue,
            timerCallback,
            @ptrFromInt(timer_id), // Pass timer_id as context
            @intCast(interval_ms),
            @intCast(interval_ms), // Recurring interval
            0, // No flags
        );

        if (success == 0) {
            return error.CreateTimerFailed;
        }

        try self.timers.put(timer_id, timer_handle);
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *IOCPBackend, timer_id: u32) !void {
        if (self.timers.get(timer_id)) |timer_handle| {
            _ = windows.kernel32.DeleteTimerQueueTimer(
                self.timer_queue,
                timer_handle,
                null, // Don't wait for completion
            );
            _ = self.timers.remove(timer_id);
        }
    }

    /// Timer callback function
    fn timerCallback(context: ?*anyopaque, timer_low: u32, timer_high: u32) callconv(.C) void {
        _ = timer_low;
        _ = timer_high;

        if (context) |ctx| {
            const timer_id = @as(u32, @intCast(@intFromPtr(ctx)));
            // Post timer event to IOCP
            // This is a simplified approach - in a real implementation,
            // we'd need a more sophisticated way to deliver timer events
            _ = timer_id;
        }
    }
} else void;

test "IOCP backend compilation" {
    if (!supports_iocp) return error.SkipZigTest;

    // Basic compilation test - actual functionality would require Windows
    const BackendType = @TypeOf(IOCPBackend);
    _ = BackendType;
}