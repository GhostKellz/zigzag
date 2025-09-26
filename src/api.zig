//! ZigZag stable API design and version compatibility
//! Provides stable public interfaces and backward compatibility

const std = @import("std");
const builtin = @import("builtin");

/// ZigZag version information
pub const Version = struct {
    pub const major: u32 = 1;
    pub const minor: u32 = 0;
    pub const patch: u32 = 0;
    pub const pre_release: ?[]const u8 = "theta";

    pub fn string() []const u8 {
        return if (pre_release) |pre|
            std.fmt.comptimePrint("{d}.{d}.{d}-{s}", .{ major, minor, patch, pre })
        else
            std.fmt.comptimePrint("{d}.{d}.{d}", .{ major, minor, patch });
    }

    pub fn compatible(other_major: u32, other_minor: u32) bool {
        // Semantic versioning compatibility
        return major == other_major and minor >= other_minor;
    }
};

/// API level for feature detection
pub const ApiLevel = enum(u32) {
    /// Alpha: Core functionality
    alpha = 1,
    /// Beta: Stability and performance
    beta = 2,
    /// Theta: Feature complete
    theta = 3,
    /// RC: Release candidate
    rc = 4,
    /// Stable: Production ready
    stable = 5,

    pub fn current() ApiLevel {
        return .theta;
    }

    pub fn supports(self: ApiLevel, required: ApiLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(required);
    }
};

/// Feature flags for conditional compilation and runtime detection
pub const Features = struct {
    // Core features (always available)
    pub const event_loop = true;
    pub const multiple_backends = true;
    pub const timers = true;

    // Alpha features
    pub const event_coalescing = true;
    pub const memory_management = true;
    pub const error_recovery = true;

    // Beta features
    pub const zero_copy_io = true;
    pub const priority_queues = true;
    pub const pty_management = true;
    pub const signal_handling = true;
    pub const performance_profiling = true;
    pub const platform_optimization = true;

    // Theta features
    pub const async_runtime = true;
    pub const advanced_timers = true;
    pub const event_debugging = true;
    pub const thread_safety = true;
    pub const file_watching = true;
    pub const network_io = true;

    /// Check if a feature is available at runtime
    pub fn isAvailable(comptime feature_name: []const u8) bool {
        return @field(Features, feature_name);
    }

    /// Get feature level for a specific feature
    pub fn getFeatureLevel(comptime feature_name: []const u8) ApiLevel {
        // Alpha features
        if (std.mem.eql(u8, feature_name, "event_loop") or
            std.mem.eql(u8, feature_name, "timers") or
            std.mem.eql(u8, feature_name, "event_coalescing"))
        {
            return .alpha;
        }

        // Beta features
        if (std.mem.eql(u8, feature_name, "zero_copy_io") or
            std.mem.eql(u8, feature_name, "priority_queues") or
            std.mem.eql(u8, feature_name, "performance_profiling"))
        {
            return .beta;
        }

        // Theta features
        if (std.mem.eql(u8, feature_name, "async_runtime") or
            std.mem.eql(u8, feature_name, "event_debugging") or
            std.mem.eql(u8, feature_name, "file_watching"))
        {
            return .theta;
        }

        return .stable; // Default for unknown features
    }
};

/// Stable public API re-exports
pub const EventLoop = @import("root.zig").EventLoop;
pub const Event = @import("root.zig").Event;
pub const EventType = @import("root.zig").EventType;
pub const EventMask = @import("root.zig").EventMask;
pub const Backend = @import("root.zig").Backend;
pub const Timer = @import("root.zig").Timer;
pub const TimerType = @import("root.zig").TimerType;
pub const Watch = @import("root.zig").Watch;
pub const Options = @import("root.zig").Options;

// Conditional exports based on feature availability
pub const EventCoalescer = if (Features.event_coalescing) @import("event_coalescing.zig").EventCoalescer else void;
pub const CoalescingConfig = if (Features.event_coalescing) @import("event_coalescing.zig").CoalescingConfig else void;

pub const RingBuffer = if (Features.zero_copy_io) @import("zero_copy.zig").RingBuffer else void;
pub const BufferPool = if (Features.zero_copy_io) @import("zero_copy.zig").BufferPool else void;
pub const ZeroCopyIO = if (Features.zero_copy_io) @import("zero_copy.zig").ZeroCopyIO else void;

pub const EventPriorityQueue = if (Features.priority_queues) @import("priority_queue.zig").EventPriorityQueue else void;
pub const Priority = if (Features.priority_queues) @import("priority_queue.zig").Priority else void;

pub const PtyManager = if (Features.pty_management) @import("pty.zig").PtyManager else void;
pub const PtyConfig = if (Features.pty_management) @import("pty.zig").PtyConfig else void;

pub const SignalHandler = if (Features.signal_handling) @import("signals.zig").SignalHandler else void;
pub const ChildMonitor = if (Features.signal_handling) @import("signals.zig").ChildMonitor else void;

pub const Profiler = if (Features.performance_profiling) @import("profiling.zig").Profiler else void;
pub const Metrics = if (Features.performance_profiling) @import("profiling.zig").Metrics else void;

pub const BackendDetector = if (Features.platform_optimization) @import("platform_optimizations.zig").BackendDetector else void;
pub const PlatformCapabilities = if (Features.platform_optimization) @import("platform_optimizations.zig").PlatformCapabilities else void;

pub const AsyncRuntime = if (Features.async_runtime) @import("async_runtime.zig").AsyncRuntime else void;
pub const AsyncOperation = if (Features.async_runtime) @import("async_runtime.zig").AsyncOperation else void;

pub const AdvancedTimer = if (Features.advanced_timers) @import("advanced_timers.zig").AdvancedTimer else void;
pub const TimerStats = if (Features.advanced_timers) @import("advanced_timers.zig").TimerStats else void;
pub const HighResTimer = if (Features.advanced_timers) @import("advanced_timers.zig").HighResTimer else void;

pub const EventTracer = if (Features.event_debugging) @import("event_debugging.zig").EventTracer else void;
pub const PerformanceMonitor = if (Features.event_debugging) @import("event_debugging.zig").PerformanceMonitor else void;

pub const ThreadSafeQueue = if (Features.thread_safety) @import("thread_safety.zig").ThreadSafeQueue else void;
pub const SharedPointer = if (Features.thread_safety) @import("thread_safety.zig").SharedPointer else void;
pub const ThreadSafeEventLoop = if (Features.thread_safety) @import("thread_safety.zig").ThreadSafeEventLoop else void;

pub const FileWatcher = if (Features.file_watching) @import("file_watching.zig").FileWatcher else void;
pub const WatchConfig = if (Features.file_watching) @import("file_watching.zig").WatchConfig else void;
pub const FileEvent = if (Features.file_watching) @import("file_watching.zig").FileEvent else void;

pub const NetworkManager = if (Features.network_io) @import("network_io.zig").NetworkManager else void;
pub const ConnectionPool = if (Features.network_io) @import("network_io.zig").ConnectionPool else void;
pub const BandwidthMonitor = if (Features.network_io) @import("network_io.zig").BandwidthMonitor else void;

/// Configuration builder for easy setup
pub const ConfigBuilder = struct {
    options: Options = .{},
    coalescing_config: ?CoalescingConfig = null,
    profiling_enabled: bool = false,
    debugging_enabled: bool = false,
    async_enabled: bool = false,

    pub fn init() ConfigBuilder {
        return ConfigBuilder{};
    }

    pub fn withBackend(self: ConfigBuilder, backend: Backend) ConfigBuilder {
        var result = self;
        result.options.backend = backend;
        return result;
    }

    pub fn withMaxEvents(self: ConfigBuilder, max_events: u32) ConfigBuilder {
        var result = self;
        result.options.max_events = max_events;
        return result;
    }

    pub fn withCoalescing(self: ConfigBuilder, config: CoalescingConfig) ConfigBuilder {
        var result = self;
        result.options.coalescing = config;
        result.coalescing_config = config;
        return result;
    }

    pub fn withProfiling(self: ConfigBuilder, enabled: bool) ConfigBuilder {
        var result = self;
        result.profiling_enabled = enabled;
        return result;
    }

    pub fn withDebugging(self: ConfigBuilder, enabled: bool) ConfigBuilder {
        var result = self;
        result.debugging_enabled = enabled;
        return result;
    }

    pub fn withAsync(self: ConfigBuilder, enabled: bool) ConfigBuilder {
        var result = self;
        result.async_enabled = enabled;
        return result;
    }

    pub fn autoDetectBackend(self: ConfigBuilder) ConfigBuilder {
        if (Features.platform_optimization) {
            const detector = BackendDetector.init();
            return self.withBackend(detector.getOptimalBackend());
        } else {
            return self.withBackend(.epoll); // Safe fallback
        }
    }

    pub fn build(self: ConfigBuilder) Options {
        return self.options;
    }
};

/// High-level application setup
pub const Application = struct {
    allocator: std.mem.Allocator,
    event_loop: EventLoop,
    profiler: if (Features.performance_profiling) ?Profiler else void,
    tracer: if (Features.event_debugging) ?EventTracer else void,
    async_runtime: if (Features.async_runtime) ?AsyncRuntime else void,

    pub fn init(allocator: std.mem.Allocator, config: ConfigBuilder) !Application {
        const options = config.build();
        var event_loop = try EventLoop.init(allocator, options);
        errdefer event_loop.deinit();

        var app = Application{
            .allocator = allocator,
            .event_loop = event_loop,
            .profiler = if (Features.performance_profiling) null else {},
            .tracer = if (Features.event_debugging) null else {},
            .async_runtime = if (Features.async_runtime) null else {},
        };

        // Initialize optional components
        if (Features.performance_profiling and config.profiling_enabled) {
            app.profiler = Profiler.init(allocator, event_loop.backend);
        }

        if (Features.event_debugging and config.debugging_enabled) {
            app.tracer = try EventTracer.init(allocator, 10000);
        }

        if (Features.async_runtime and config.async_enabled) {
            app.async_runtime = try AsyncRuntime.init(allocator, &app.event_loop);
        }

        return app;
    }

    pub fn deinit(self: *Application) void {
        if (Features.async_runtime) {
            if (self.async_runtime) |*runtime| {
                runtime.deinit();
            }
        }

        if (Features.event_debugging) {
            if (self.tracer) |*tracer| {
                tracer.deinit();
            }
        }

        if (Features.performance_profiling) {
            if (self.profiler) |*profiler| {
                profiler.deinit();
            }
        }

        self.event_loop.deinit();
    }

    pub fn run(self: *Application) !void {
        if (Features.async_runtime) {
            if (self.async_runtime) |*runtime| {
                return try runtime.runWithZsync();
            }
        }

        return try self.event_loop.run();
    }

    pub fn stop(self: *Application) void {
        self.event_loop.stop();
    }

    pub fn getEventLoop(self: *Application) *EventLoop {
        return &self.event_loop;
    }

    pub fn getProfiler(self: *Application) if (Features.performance_profiling) ?*Profiler else void {
        if (Features.performance_profiling) {
            if (self.profiler) |*profiler| {
                return profiler;
            }
            return null;
        } else {
            return {};
        }
    }

    pub fn getTracer(self: *Application) if (Features.event_debugging) ?*EventTracer else void {
        if (Features.event_debugging) {
            if (self.tracer) |*tracer| {
                return tracer;
            }
            return null;
        } else {
            return {};
        }
    }
};

/// Error types used throughout the API
pub const ZigZagError = error{
    // Initialization errors
    BackendNotSupported,
    BackendInitializationFailed,
    InsufficientMemory,
    InvalidConfiguration,

    // Operation errors
    EventLoopNotRunning,
    OperationNotSupported,
    ResourceExhausted,
    InvalidState,

    // I/O errors
    FileDescriptorInvalid,
    IoOperationFailed,
    TimeoutExpired,

    // Feature errors
    FeatureNotAvailable,
    ApiLevelTooLow,
    VersionIncompatible,
};

/// Convenience functions for common operations
pub const convenience = struct {
    /// Create a simple event loop with auto-detected backend
    pub fn createSimpleEventLoop(allocator: std.mem.Allocator) !EventLoop {
        const config = ConfigBuilder.init().autoDetectBackend();
        return EventLoop.init(allocator, config.build());
    }

    /// Create a high-performance event loop with all optimizations
    pub fn createHighPerformanceEventLoop(allocator: std.mem.Allocator) !EventLoop {
        const config = ConfigBuilder.init()
            .autoDetectBackend()
            .withCoalescing(.{
            .coalesce_resize = true,
            .max_coalesce_time_ms = 5,
            .max_batch_size = 32,
        });

        return EventLoop.init(allocator, config.build());
    }

    /// Create a terminal emulator event loop
    pub fn createTerminalEventLoop(allocator: std.mem.Allocator) !Application {
        const config = ConfigBuilder.init()
            .autoDetectBackend()
            .withCoalescing(.{
            .coalesce_resize = true,
            .max_coalesce_time_ms = 10,
        })
            .withProfiling(false) // Disable for production
            .withDebugging(false);

        return Application.init(allocator, config);
    }

    /// Create a development event loop with debugging
    pub fn createDebugEventLoop(allocator: std.mem.Allocator) !Application {
        const config = ConfigBuilder.init()
            .withBackend(.epoll) // Predictable for debugging
            .withProfiling(true)
            .withDebugging(true);

        return Application.init(allocator, config);
    }
};

/// Documentation utilities
pub const docs = struct {
    /// Get feature documentation
    pub fn getFeatureInfo(comptime feature_name: []const u8) FeatureInfo {
        return FeatureInfo{
            .name = feature_name,
            .available = Features.isAvailable(feature_name),
            .api_level = Features.getFeatureLevel(feature_name),
            .description = getFeatureDescription(feature_name),
        };
    }

    const FeatureInfo = struct {
        name: []const u8,
        available: bool,
        api_level: ApiLevel,
        description: []const u8,
    };

    fn getFeatureDescription(comptime feature_name: []const u8) []const u8 {
        return switch (std.meta.stringToEnum(enum {
            event_loop,
            zero_copy_io,
            priority_queues,
            async_runtime,
            event_debugging,
        }, feature_name) orelse return "Unknown feature") {
            .event_loop => "Core event loop functionality with multi-backend support",
            .zero_copy_io => "High-performance zero-copy I/O operations",
            .priority_queues => "Event prioritization for optimal processing order",
            .async_runtime => "Async/await support with coroutine integration",
            .event_debugging => "Comprehensive event tracing and performance monitoring",
        };
    }

    /// Generate API documentation
    pub fn generateApiDocs(writer: anytype) !void {
        try writer.print("# ZigZag API Documentation\n\n", .{});
        try writer.print("Version: {s}\n", .{Version.string()});
        try writer.print("API Level: {s}\n\n", .{@tagName(ApiLevel.current())});

        try writer.print("## Available Features\n\n", .{});

        inline for (@typeInfo(Features).Struct.decls) |decl| {
            if (@TypeOf(@field(Features, decl.name)) == bool) {
                const info = getFeatureInfo(decl.name);
                try writer.print("- **{s}**: {s} (API Level: {s})\n", .{
                    info.name,
                    info.description,
                    @tagName(info.api_level),
                });
            }
        }
    }
};

test "Version compatibility" {
    try std.testing.expect(Version.compatible(1, 0));
    try std.testing.expect(Version.compatible(1, 0));
    try std.testing.expect(!Version.compatible(2, 0));
}

test "API level support" {
    try std.testing.expect(ApiLevel.theta.supports(.alpha));
    try std.testing.expect(ApiLevel.theta.supports(.beta));
    try std.testing.expect(ApiLevel.theta.supports(.theta));
    try std.testing.expect(!ApiLevel.alpha.supports(.beta));
}

test "Config builder" {
    const config = ConfigBuilder.init()
        .withMaxEvents(2048)
        .withProfiling(true)
        .build();

    try std.testing.expectEqual(@as(u32, 2048), config.max_events);
}

test "Feature availability" {
    try std.testing.expect(Features.isAvailable("event_loop"));
    try std.testing.expect(Features.isAvailable("zero_copy_io"));

    const info = docs.getFeatureInfo("event_loop");
    try std.testing.expect(info.available);
    try std.testing.expectEqual(ApiLevel.alpha, info.api_level);
}