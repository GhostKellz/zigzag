//! Centralized logging module for zigzag event loop
//!
//! Provides structured logging using zlog library with performance-focused
//! configuration optimized for event loop operations.
//!
//! ## Features
//! - Structured logging with typed fields
//! - Performance metrics tracking
//! - Backend-specific logging
//! - Event trace logging for debugging
//! - Configurable log levels per subsystem

const std = @import("std");
const build_options = @import("build_options");

/// Logger instance (conditionally compiled)
pub const Logger = if (build_options.enable_zlog)
    @import("zlog").Logger
else
    NoOpLogger;

/// No-op logger for when zlog is disabled
const NoOpLogger = struct {
    pub fn init(_: std.mem.Allocator, _: anytype) !NoOpLogger {
        return NoOpLogger{};
    }

    pub fn deinit(_: *NoOpLogger) void {}

    pub fn debug(_: *NoOpLogger, comptime _: []const u8, _: anytype) void {}
    pub fn info(_: *NoOpLogger, comptime _: []const u8, _: anytype) void {}
    pub fn warn(_: *NoOpLogger, comptime _: []const u8, _: anytype) void {}
    pub fn err(_: *NoOpLogger, comptime _: []const u8, _: anytype) void {}

    pub fn logWithFields(_: *NoOpLogger, _: anytype, _: []const u8, _: anytype) void {}
};

/// Global logger instance (optional)
var global_logger: ?Logger = null;
var global_logger_mutex: std.Thread.Mutex = .{};

/// Initialize the global logger
pub fn initGlobalLogger(allocator: std.mem.Allocator) !void {
    if (!build_options.enable_zlog) return;

    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger != null) return error.AlreadyInitialized;

    const zlog = @import("zlog");
    global_logger = try zlog.Logger.init(allocator, .{
        .level = .debug,
        .format = .text,
        .output_target = .stderr,
        .async_io = false, // Sync for now to avoid event loop conflicts
    });
}

/// Deinitialize the global logger
pub fn deinitGlobalLogger() void {
    if (!build_options.enable_zlog) return;

    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |*logger| {
        logger.deinit();
        global_logger = null;
    }
}

/// Get the global logger
fn getGlobalLogger() ?*Logger {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |*logger| {
        return logger;
    }
    return null;
}

/// Log backend initialization
pub fn logBackendInit(backend_name: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.info("Initializing backend: {s}", .{backend_name});
    }
}

/// Log backend error
pub fn logBackendError(backend_name: []const u8, err: anyerror) void {
    if (getGlobalLogger()) |logger| {
        logger.err("Backend {s} error: {}", .{ backend_name, err });
    }
}

/// Log event processing
pub fn logEventProcessed(backend_name: []const u8, event_count: usize, duration_ns: u64) void {
    if (!build_options.enable_zlog) return;

    if (getGlobalLogger()) |logger| {
        const zlog = @import("zlog");
        const fields = [_]zlog.Field{
            .{ .key = "backend", .value = .{ .string = backend_name } },
            .{ .key = "events", .value = .{ .uint = event_count } },
            .{ .key = "duration_ns", .value = .{ .uint = duration_ns } },
        };
        logger.logWithFields(.debug, "Events processed", &fields);
    }
}

/// Log timer creation
pub fn logTimerCreated(timer_id: usize, interval_ms: u64, recurring: bool) void {
    if (!build_options.enable_zlog) return;

    if (getGlobalLogger()) |logger| {
        const zlog = @import("zlog");
        const fields = [_]zlog.Field{
            .{ .key = "timer_id", .value = .{ .uint = timer_id } },
            .{ .key = "interval_ms", .value = .{ .uint = interval_ms } },
            .{ .key = "recurring", .value = .{ .boolean = recurring } },
        };
        logger.logWithFields(.debug, "Timer created", &fields);
    }
}

/// Log file descriptor watch
pub fn logFdWatchAdded(fd: i32, events: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.debug("Watching FD {d} for events: {s}", .{ fd, events });
    }
}

/// Log performance metrics
pub fn logPerformanceMetrics(
    backend: []const u8,
    avg_latency_ns: u64,
    throughput_eps: u64,
    memory_mb: f64,
) void {
    if (!build_options.enable_zlog) return;

    if (getGlobalLogger()) |logger| {
        const zlog = @import("zlog");
        const fields = [_]zlog.Field{
            .{ .key = "backend", .value = .{ .string = backend } },
            .{ .key = "avg_latency_ns", .value = .{ .uint = avg_latency_ns } },
            .{ .key = "throughput_eps", .value = .{ .uint = throughput_eps } },
            .{ .key = "memory_mb", .value = .{ .float = memory_mb } },
        };
        logger.logWithFields(.info, "Performance metrics", &fields);
    }
}

/// Log file watching event
pub fn logFileWatchEvent(path: []const u8, event_type: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.debug("File watch event: {s} - {s}", .{ path, event_type });
    }
}

/// Log async operation
pub fn logAsyncOp(operation: []const u8, status: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.debug("Async operation: {s} - {s}", .{ operation, status });
    }
}

/// Log error with context
pub fn logError(context: []const u8, err: anyerror) void {
    if (getGlobalLogger()) |logger| {
        logger.err("{s}: {}", .{ context, err });
    }
}

/// Log warning with context
pub fn logWarning(context: []const u8, message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.warn("{s}: {s}", .{ context, message });
    }
}

/// Log debug message
pub fn logDebug(message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.debug("{s}", .{message});
    }
}

/// Log info message
pub fn logInfo(message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.info("{s}", .{message});
    }
}
