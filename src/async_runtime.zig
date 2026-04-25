//! ZSync async runtime integration for ZigZag
//! Provides async/await support and coroutine integration

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;
const Watch = @import("root.zig").Watch;

// Conditional zsync import
const zsync = if (build_options.enable_zsync) @import("zsync") else void;

/// Async frame for coroutine support
pub const AsyncFrame = struct {
    allocator: std.mem.Allocator,
    frame: anyframe,
    completion_callback: ?*const fn (*AsyncFrame, anyerror!void) void = null,
    user_data: ?*anyopaque = null,
    state: State = .pending,

    const State = enum {
        pending,
        running,
        completed,
        cancelled,
    };

    pub fn init(allocator: std.mem.Allocator, frame: anyframe) AsyncFrame {
        return AsyncFrame{
            .allocator = allocator,
            .frame = frame,
        };
    }

    pub fn complete(self: *AsyncFrame, result: anyerror!void) void {
        self.state = .completed;
        if (self.completion_callback) |callback| {
            callback(self, result);
        }
    }

    pub fn cancel(self: *AsyncFrame) void {
        self.state = .cancelled;
        if (self.completion_callback) |callback| {
            callback(self, error.Cancelled);
        }
    }
};

/// Async I/O operation result
pub const AsyncResult = union(enum) {
    pending,
    ready: struct {
        bytes_transferred: usize,
        error_code: ?anyerror = null,
    },
    cancelled,
};

/// Async operation context
pub const AsyncOperation = struct {
    operation_type: OperationType,
    fd: i32,
    buffer: []u8,
    offset: usize = 0,
    result: AsyncResult = .pending,
    frame: ?*AsyncFrame = null,
    callback: ?*const fn (*AsyncOperation) void = null,
    timer_callback: ?*const fn () void = null,
    timer: ?@import("root.zig").Timer = null,
    watch: ?*const Watch = null,
    runtime: ?*AsyncRuntime = null,

    const OperationType = enum {
        read,
        write,
        accept,
        connect,
        timer,
    };

    pub fn init(op_type: OperationType, fd: i32, buffer: []u8) AsyncOperation {
        return AsyncOperation{
            .operation_type = op_type,
            .fd = fd,
            .buffer = buffer,
        };
    }

    pub fn complete(self: *AsyncOperation, bytes: usize, err: ?anyerror) void {
        self.result = .{ .ready = .{
            .bytes_transferred = bytes,
            .error_code = err,
        } };

        if (self.callback) |callback| {
            callback(self);
        }

        if (self.frame) |frame| {
            frame.complete(if (err) |e| e else {});
        }
    }

    pub fn cancel(self: *AsyncOperation) void {
        self.result = .cancelled;
        if (self.frame) |frame| {
            frame.cancel();
        }
    }
};

/// Async runtime for managing coroutines and async operations
pub const AsyncRuntime = struct {
    allocator: std.mem.Allocator,
    event_loop: *EventLoop,
    pending_operations: std.ArrayList(*AsyncOperation),
    active_frames: std.ArrayList(*AsyncFrame),
    executor: if (build_options.enable_zsync) ?zsync.Executor else void,

    pub fn init(allocator: std.mem.Allocator, event_loop: *EventLoop) !AsyncRuntime {
        var pending_operations = std.ArrayList(*AsyncOperation).init(allocator);
        errdefer pending_operations.deinit();

        var active_frames = std.ArrayList(*AsyncFrame).init(allocator);
        errdefer active_frames.deinit();

        return AsyncRuntime{
            .allocator = allocator,
            .event_loop = event_loop,
            .pending_operations = pending_operations,
            .active_frames = active_frames,
            .executor = if (build_options.enable_zsync) try zsync.Executor.init(allocator) else {},
        };
    }

    pub fn deinit(self: *AsyncRuntime) void {
        // Cancel all pending operations
        for (self.pending_operations.items) |op| {
            op.cancel();
            self.cleanupOperation(op);
        }

        // Cancel all active frames
        for (self.active_frames.items) |frame| {
            frame.cancel();
        }

        self.pending_operations.deinit();
        self.active_frames.deinit();

        if (build_options.enable_zsync) {
            if (self.executor) |*executor| {
                executor.deinit();
            }
        }
    }

    fn cleanupOperation(self: *AsyncRuntime, operation: *AsyncOperation) void {
        if (operation.watch) |watch| {
            self.event_loop.removeFd(watch);
            operation.watch = null;
        }
        if (operation.timer) |*timer| {
            self.event_loop.cancelTimer(timer);
            operation.timer = null;
        }
        self.allocator.destroy(operation);
    }

    /// Submit an async operation
    pub fn submitOperation(self: *AsyncRuntime, operation: *AsyncOperation) !void {
        operation.runtime = self;
        try self.pending_operations.append(operation);

        // Add to event loop based on operation type
        switch (operation.operation_type) {
            .read => {
                const watch = try self.event_loop.addFd(operation.fd, .{ .read = true });
                operation.watch = watch;
                self.event_loop.setUserData(watch, operation);
                self.event_loop.setCallback(watch, asyncReadCallback);
            },
            .write => {
                const watch = try self.event_loop.addFd(operation.fd, .{ .write = true });
                operation.watch = watch;
                self.event_loop.setUserData(watch, operation);
                self.event_loop.setCallback(watch, asyncWriteCallback);
            },
            .timer => {
                const timer_callback = struct {
                    pub fn onTimer(user_data: ?*anyopaque) void {
                        if (user_data) |data| {
                            const op = @as(*AsyncOperation, @ptrCast(@alignCast(data)));
                            if (op.timer_callback) |callback| {
                                callback();
                            }
                            op.complete(0, null);
                        }
                    }
                }.onTimer;

                operation.timer = try self.event_loop.addTimerWithUserData(operation.offset, timer_callback, operation);
            },
            else => {
                return error.UnsupportedOperation;
            }
        }
    }

    /// Process completed operations
    pub fn processCompletions(self: *AsyncRuntime) !void {
        var i: usize = 0;
        while (i < self.pending_operations.items.len) {
            const op = self.pending_operations.items[i];
            switch (op.result) {
                .ready, .cancelled => {
                    // Remove completed operation
                    const completed = self.pending_operations.swapRemove(i);
                    self.cleanupOperation(completed);
                },
                .pending => {
                    i += 1;
                },
            }
        }

        // Process active frames
        i = 0;
        while (i < self.active_frames.items.len) {
            const frame = self.active_frames.items[i];
            switch (frame.state) {
                .completed, .cancelled => {
                    _ = self.active_frames.swapRemove(i);
                },
                else => {
                    i += 1;
                },
            }
        }
    }

    /// Spawn an async function
    pub fn spawn(self: *AsyncRuntime, comptime func: anytype, args: anytype) !*AsyncFrame {
        const frame = try self.allocator.create(AsyncFrame);
        errdefer self.allocator.destroy(frame);

        // Create the async frame
        frame.* = AsyncFrame.init(self.allocator, @call(.auto, func, args));
        try self.active_frames.append(frame);

        return frame;
    }

    /// Run async tasks with zsync integration
    pub fn runWithZsync(self: *AsyncRuntime) !void {
        if (!build_options.enable_zsync) {
            return error.ZsyncNotEnabled;
        }

        if (build_options.enable_zsync) {
            // Integration with zsync executor
            while (self.active_frames.items.len > 0 or self.pending_operations.items.len > 0) {
                // Run event loop iteration
                _ = try self.event_loop.tick();

                // Process completions
                try self.processCompletions();

                // Run zsync tasks
                if (self.executor) |*executor| {
                    try executor.tick();
                }

                // Small delay to prevent busy waiting
                if (self.active_frames.items.len == 0 and self.pending_operations.items.len == 0) {
                    break;
                }
            }
        }
    }

    /// Async read operation
    pub fn asyncRead(self: *AsyncRuntime, fd: i32, buffer: []u8) !AsyncResult {
        const operation = try self.allocator.create(AsyncOperation);
        operation.* = AsyncOperation.init(.read, fd, buffer);
        try self.submitOperation(operation);
        return AsyncResult.pending;
    }

    /// Async write operation
    pub fn asyncWrite(self: *AsyncRuntime, fd: i32, buffer: []u8) !AsyncResult {
        const operation = try self.allocator.create(AsyncOperation);
        operation.* = AsyncOperation.init(.write, fd, buffer);
        try self.submitOperation(operation);
        return AsyncResult.pending;
    }

    /// Yield control to other async tasks
    pub fn yield(self: *AsyncRuntime) void {
        _ = self;
        // In a real implementation, this would yield to the async runtime
        // For now, just return
    }
};

/// Async callbacks for event loop integration
fn asyncReadCallback(watch: *const Watch, event: Event) void {
    if (event.type != .read_ready and event.type != .hangup and event.type != .io_error) {
        return;
    }

    const user_data = watch.user_data orelse return;
    const operation = @as(*AsyncOperation, @ptrCast(@alignCast(user_data)));
    if (operation.result != .pending) return;

    switch (event.type) {
        .hangup => operation.complete(0, error.EndOfStream),
        .io_error => operation.complete(0, error.InputOutput),
        .read_ready => {
            const bytes_read = std.posix.read(operation.fd, operation.buffer) catch |err| {
                if (err == error.WouldBlock) return;
                operation.complete(0, err);
                return;
            };
            operation.complete(bytes_read, null);
        },
        else => unreachable,
    }
}

fn asyncWriteCallback(watch: *const Watch, event: Event) void {
    if (event.type != .write_ready and event.type != .hangup and event.type != .io_error) {
        return;
    }

    const user_data = watch.user_data orelse return;
    const operation = @as(*AsyncOperation, @ptrCast(@alignCast(user_data)));
    if (operation.result != .pending) return;

    switch (event.type) {
        .hangup => operation.complete(0, error.BrokenPipe),
        .io_error => operation.complete(0, error.InputOutput),
        .write_ready => {
            const bytes_written = std.posix.write(operation.fd, operation.buffer) catch |err| {
                if (err == error.WouldBlock) return;
                operation.complete(0, err);
                return;
            };
            operation.complete(bytes_written, null);
        },
        else => unreachable,
    }
}

/// Async-friendly timer implementation
pub const AsyncTimer = struct {
    runtime: *AsyncRuntime,
    duration_ms: u64,
    callback: ?*const fn () void = null,

    pub fn init(runtime: *AsyncRuntime, duration_ms: u64) AsyncTimer {
        return AsyncTimer{
            .runtime = runtime,
            .duration_ms = duration_ms,
        };
    }

    /// Sleep for specified duration (async)
    pub fn sleep(self: *AsyncTimer) !void {
        const operation = try self.runtime.allocator.create(AsyncOperation);
        operation.* = AsyncOperation.init(.timer, -1, &[_]u8{});
        operation.offset = self.duration_ms;
        operation.timer_callback = self.callback;
        try self.runtime.submitOperation(operation);
    }

    /// Set a callback timer
    pub fn setCallback(self: *AsyncTimer, callback: *const fn () void) void {
        self.callback = callback;
    }
};

/// Async-friendly file I/O
pub const AsyncFile = struct {
    fd: i32,
    runtime: *AsyncRuntime,

    pub fn init(fd: i32, runtime: *AsyncRuntime) AsyncFile {
        return AsyncFile{
            .fd = fd,
            .runtime = runtime,
        };
    }

    /// Async read from file
    pub fn read(self: *AsyncFile, buffer: []u8) !AsyncResult {
        return try self.runtime.asyncRead(self.fd, buffer);
    }

    /// Async write to file
    pub fn write(self: *AsyncFile, buffer: []u8) !AsyncResult {
        return try self.runtime.asyncWrite(self.fd, buffer);
    }
};

/// High-level async utilities
pub const AsyncUtils = struct {
    /// Race multiple async operations
    pub fn race(runtime: *AsyncRuntime, operations: []*AsyncOperation) !*AsyncOperation {
        // Submit all operations
        for (operations) |op| {
            try runtime.submitOperation(op);
        }

        // Wait for first to complete
        while (true) {
            for (operations) |op| {
                switch (op.result) {
                    .ready, .cancelled => return op,
                    .pending => {},
                }
            }

            // Process event loop
            _ = try runtime.event_loop.tick();
            try runtime.processCompletions();
        }
    }

    /// Wait for all async operations to complete
    pub fn all(runtime: *AsyncRuntime, operations: []*AsyncOperation) !void {
        // Submit all operations
        for (operations) |op| {
            try runtime.submitOperation(op);
        }

        // Wait for all to complete
        while (true) {
            var all_complete = true;
            for (operations) |op| {
                switch (op.result) {
                    .pending => {
                        all_complete = false;
                        break;
                    },
                    else => {},
                }
            }

            if (all_complete) break;

            // Process event loop
            _ = try runtime.event_loop.tick();
            try runtime.processCompletions();
        }
    }
};

test "Async runtime basic operations" {
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, .{});
    defer loop.deinit();

    var runtime = try AsyncRuntime.init(allocator, &loop);
    defer runtime.deinit();

    // Test basic initialization
    try std.testing.expect(runtime.pending_operations.items.len == 0);
    try std.testing.expect(runtime.active_frames.items.len == 0);
}

test "Async operation lifecycle" {
    var operation = AsyncOperation.init(.read, 1, &[_]u8{0} ** 1024);
    try std.testing.expect(operation.operation_type == .read);
    try std.testing.expect(operation.fd == 1);

    // Test completion
    operation.complete(100, null);
    switch (operation.result) {
        .ready => |result| {
            try std.testing.expectEqual(@as(usize, 100), result.bytes_transferred);
            try std.testing.expect(result.error_code == null);
        },
        else => try std.testing.expect(false),
    }

    // Test cancellation
    var cancelled_op = AsyncOperation.init(.write, 2, &[_]u8{0} ** 512);
    cancelled_op.cancel();
    try std.testing.expect(cancelled_op.result == .cancelled);
}

test "Async timer" {
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator, .{});
    defer loop.deinit();

    var runtime = try AsyncRuntime.init(allocator, &loop);
    defer runtime.deinit();

    const timer = AsyncTimer.init(&runtime, 100);
    try std.testing.expectEqual(@as(u64, 100), timer.duration_ms);
}
