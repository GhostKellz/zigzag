//! Centralized logging module for zigzag event loop
//!
//! Provides structured logging using std.log with scoped loggers
//! optimized for event loop operations.
//!
//! ## Features
//! - Scoped loggers for each subsystem
//! - Performance metrics logging
//! - Backend-specific logging
//! - Event trace logging for debugging

const std = @import("std");
const builtin = @import("builtin");

fn isVerboseLoggingEnabled() bool {
    return builtin.is_test or std.log.default_level == .debug;
}

/// Scoped loggers for different subsystems
pub const backend = std.log.scoped(.zigzag_backend);
pub const timer = std.log.scoped(.zigzag_timer);
pub const events = std.log.scoped(.zigzag_events);
pub const perf = std.log.scoped(.zigzag_perf);
pub const file_watch = std.log.scoped(.zigzag_filewatch);
pub const async_log = std.log.scoped(.zigzag_async);
pub const general = std.log.scoped(.zigzag);

/// Log backend initialization
pub fn logBackendInit(backend_name: []const u8) void {
    if (isVerboseLoggingEnabled()) {
        backend.info("Initializing backend: {s}", .{backend_name});
    }
}

/// Log backend error
pub fn logBackendError(backend_name: []const u8, err: anyerror) void {
    backend.err("Backend {s} error: {}", .{ backend_name, err });
}

/// Log event processing
pub fn logEventProcessed(backend_name: []const u8, event_count: usize, duration_ns: u64) void {
    events.debug("Events processed: backend={s} count={d} duration_ns={d}", .{
        backend_name,
        event_count,
        duration_ns,
    });
}

/// Log timer creation
pub fn logTimerCreated(timer_id: usize, interval_ms: u64, recurring: bool) void {
    timer.debug("Timer created: id={d} interval_ms={d} recurring={}", .{
        timer_id,
        interval_ms,
        recurring,
    });
}

/// Log file descriptor watch
pub fn logFdWatchAdded(fd: i32, event_types: []const u8) void {
    events.debug("Watching FD {d} for events: {s}", .{ fd, event_types });
}

/// Log performance metrics
pub fn logPerformanceMetrics(
    backend_name: []const u8,
    avg_latency_ns: u64,
    throughput_eps: u64,
    memory_mb: f64,
) void {
    perf.info("Performance: backend={s} latency_ns={d} throughput={d}/s memory_mb={d:.2}", .{
        backend_name,
        avg_latency_ns,
        throughput_eps,
        memory_mb,
    });
}

/// Log file watching event
pub fn logFileWatchEvent(path: []const u8, event_type: []const u8) void {
    file_watch.debug("File watch event: {s} - {s}", .{ path, event_type });
}

/// Log async operation
pub fn logAsyncOp(operation: []const u8, status: []const u8) void {
    async_log.debug("Async operation: {s} - {s}", .{ operation, status });
}

/// Log error with context
pub fn logError(context: []const u8, err: anyerror) void {
    general.err("{s}: {}", .{ context, err });
}

/// Log warning with context
pub fn logWarning(context: []const u8, message: []const u8) void {
    general.warn("{s}: {s}", .{ context, message });
}

/// Log debug message
pub fn logDebug(message: []const u8) void {
    general.debug("{s}", .{message});
}

/// Log info message
pub fn logInfo(message: []const u8) void {
    general.info("{s}", .{message});
}
