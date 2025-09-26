//! Error handling for ZigZag event loop
//! Comprehensive error types and recovery mechanisms

const std = @import("std");

/// Core event loop errors
pub const EventLoopError = error{
    // Initialization errors
    BackendNotSupported,
    BackendInitializationFailed,
    BackendNotInitialized,
    InsufficientMemory,
    InvalidConfiguration,

    // File descriptor errors
    FdAlreadyWatched,
    FdNotWatched,
    InvalidFileDescriptor,
    TooManyFileDescriptors,

    // Timer errors
    TimerAlreadyExists,
    TimerNotFound,
    InvalidTimerConfiguration,
    TooManyTimers,

    // Event processing errors
    EventQueueFull,
    EventProcessingFailed,
    InvalidEventType,

    // Backend-specific errors
    EpollError,
    IoUringError,
    KQueueError,
    IOCPError,
    SubmissionQueueFull,

    // System errors
    SystemResourceExhausted,
    PermissionDenied,
    SystemOutdated,

    // Platform errors
    PlatformNotSupported,
    BackendNotImplemented,
};

/// Error context for detailed error reporting
pub const ErrorContext = struct {
    error_type: EventLoopError,
    message: []const u8,
    source_location: ?std.builtin.SourceLocation = null,
    system_error: ?anyerror = null,
    timestamp: i64,

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("EventLoop Error: {s}\n", .{@errorName(self.error_type)});
        try writer.print("  Message: {s}\n", .{self.message});
        if (self.source_location) |loc| {
            try writer.print("  Location: {s}:{d}:{d}\n", .{ loc.file, loc.line, loc.column });
        }
        if (self.system_error) |err| {
            try writer.print("  System Error: {s}\n", .{@errorName(err)});
        }
        try writer.print("  Timestamp: {d}\n", .{self.timestamp});
    }
};

/// Error recovery strategies
pub const RecoveryStrategy = enum {
    retry,
    fallback,
    ignore,
    fatal,
};

/// Error handler interface
pub const ErrorHandler = struct {
    /// Function to handle errors
    handleFn: *const fn (context: ErrorContext) RecoveryStrategy,
    /// User data for the handler
    user_data: ?*anyopaque = null,

    pub fn handle(self: *const ErrorHandler, context: ErrorContext) RecoveryStrategy {
        return self.handleFn(context);
    }
};

/// Default error handler
pub fn defaultErrorHandler(context: ErrorContext) RecoveryStrategy {
    // Log the error
    std.log.err("EventLoop error: {}", .{context});

    // Determine recovery strategy based on error type
    return switch (context.error_type) {
        // Retry for temporary errors
        error.SystemResourceExhausted,
        error.SubmissionQueueFull,
        => .retry,

        // Fallback for backend errors
        error.BackendInitializationFailed,
        error.IoUringError,
        => .fallback,

        // Ignore for non-critical errors
        error.FdAlreadyWatched,
        error.TimerAlreadyExists,
        => .ignore,

        // Fatal for critical errors
        error.InsufficientMemory,
        error.PlatformNotSupported,
        error.BackendNotSupported,
        => .fatal,

        // Default to retry for unknown errors
        else => .retry,
    };
}

/// Error recovery manager
pub const ErrorRecovery = struct {
    allocator: std.mem.Allocator,
    error_handler: ErrorHandler,
    error_history: std.ArrayList(ErrorContext),
    max_retries: u32 = 3,
    retry_counts: std.AutoHashMap(EventLoopError, u32),

    pub fn init(allocator: std.mem.Allocator, handler: ?ErrorHandler) !ErrorRecovery {
        var retry_counts = std.AutoHashMap(EventLoopError, u32).init(allocator);
        errdefer retry_counts.deinit();

        return ErrorRecovery{
            .allocator = allocator,
            .error_handler = handler orelse ErrorHandler{
                .handleFn = defaultErrorHandler,
            },
            .error_history = std.ArrayList(ErrorContext){
                .items = &.{},
                .capacity = 0,
            },
            .retry_counts = retry_counts,
        };
    }

    pub fn deinit(self: *ErrorRecovery) void {
        self.error_history.deinit(self.allocator);
        self.retry_counts.deinit();
    }

    /// Handle an error with recovery
    pub fn handleError(self: *ErrorRecovery, err: EventLoopError, message: []const u8) !RecoveryStrategy {
        const context = ErrorContext{
            .error_type = err,
            .message = message,
            .timestamp = std.time.milliTimestamp(),
            .source_location = @src(),
            .system_error = null,
        };

        // Add to history
        try self.error_history.append(self.allocator, context);

        // Get recovery strategy
        var strategy = self.error_handler.handle(context);

        // Check retry limits
        if (strategy == .retry) {
            const retry_count = self.retry_counts.get(err) orelse 0;
            if (retry_count >= self.max_retries) {
                std.log.warn("Max retries ({d}) exceeded for error: {s}", .{ self.max_retries, @errorName(err) });
                strategy = .fatal;
            } else {
                try self.retry_counts.put(err, retry_count + 1);
            }
        }

        return strategy;
    }

    /// Reset retry counts for an error
    pub fn resetRetries(self: *ErrorRecovery, err: EventLoopError) void {
        _ = self.retry_counts.remove(err);
    }

    /// Get error statistics
    pub fn getStatistics(self: *ErrorRecovery) ErrorStatistics {
        var stats = ErrorStatistics{
            .total_errors = self.error_history.items.len,
            .unique_errors = self.retry_counts.count(),
            .most_common_error = null,
            .last_error_time = null,
        };

        if (self.error_history.items.len > 0) {
            stats.last_error_time = self.error_history.items[self.error_history.items.len - 1].timestamp;
        }

        // Find most common error
        var max_count: u32 = 0;
        var iter = self.retry_counts.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* > max_count) {
                max_count = entry.value_ptr.*;
                stats.most_common_error = entry.key_ptr.*;
            }
        }

        return stats;
    }
};

/// Error statistics
pub const ErrorStatistics = struct {
    total_errors: usize,
    unique_errors: usize,
    most_common_error: ?EventLoopError,
    last_error_time: ?i64,
};

/// Result type with error context
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: ErrorContext,

        pub fn isOk(self: @This()) bool {
            return self == .ok;
        }

        pub fn isErr(self: @This()) bool {
            return self == .err;
        }

        pub fn unwrap(self: @This()) T {
            return switch (self) {
                .ok => |val| val,
                .err => |ctx| std.debug.panic("Unwrapped error result: {}", .{ctx}),
            };
        }

        pub fn unwrapOr(self: @This(), default: T) T {
            return switch (self) {
                .ok => |val| val,
                .err => default,
            };
        }
    };
}

test "ErrorRecovery basic operations" {
    const allocator = std.testing.allocator;

    var recovery = try ErrorRecovery.init(allocator, null);
    defer recovery.deinit();

    // Handle an error
    const strategy = try recovery.handleError(error.FdAlreadyWatched, "Test error");
    try std.testing.expect(strategy == .ignore);

    // Check statistics
    const stats = recovery.getStatistics();
    try std.testing.expectEqual(@as(usize, 1), stats.total_errors);
}

test "ErrorRecovery retry limits" {
    const allocator = std.testing.allocator;

    var recovery = try ErrorRecovery.init(allocator, null);
    defer recovery.deinit();
    recovery.max_retries = 2;

    // First retry should work
    var strategy = try recovery.handleError(error.SystemResourceExhausted, "Test error 1");
    try std.testing.expect(strategy == .retry);

    // Second retry should work
    strategy = try recovery.handleError(error.SystemResourceExhausted, "Test error 2");
    try std.testing.expect(strategy == .retry);

    // Third retry should hit limit and become fatal
    strategy = try recovery.handleError(error.SystemResourceExhausted, "Test error 3");
    try std.testing.expect(strategy == .fatal);
}

test "Result type operations" {
    const MyResult = Result(i32);

    // Test ok result
    const ok_result = MyResult{ .ok = 42 };
    try std.testing.expect(ok_result.isOk());
    try std.testing.expect(!ok_result.isErr());
    try std.testing.expectEqual(@as(i32, 42), ok_result.unwrapOr(0));

    // Test error result
    const err_result = MyResult{
        .err = ErrorContext{
            .error_type = error.InvalidConfiguration,
            .message = "Test error",
            .timestamp = 0,
        },
    };
    try std.testing.expect(!err_result.isOk());
    try std.testing.expect(err_result.isErr());
    try std.testing.expectEqual(@as(i32, -1), err_result.unwrapOr(-1));
}