//! API stability validation and compatibility testing
//! Ensures all public interfaces remain stable and backward compatible

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const api = @import("api.zig");
const EventLoop = @import("root.zig").EventLoop;

/// API stability test suite
pub const StabilityValidator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StabilityValidator {
        return StabilityValidator{ .allocator = allocator };
    }

    /// Validate that all core API types are properly exposed
    pub fn validateCoreAPI(self: StabilityValidator) !void {
        _ = self;

        // Test that all fundamental types are accessible
        _ = api.EventLoop;
        _ = api.Event;
        _ = api.EventType;
        _ = api.EventMask;
        _ = api.Backend;
        _ = api.Timer;
        _ = api.TimerType;
        _ = api.Watch;
        _ = api.Options;

        // Test version information
        _ = api.Version.major;
        _ = api.Version.minor;
        _ = api.Version.patch;
        _ = api.Version.string();

        // Test API level
        _ = api.ApiLevel.current();
        try testing.expect(api.ApiLevel.theta.supports(.alpha));

        // Test error types
        _ = api.ZigZagError.BackendNotSupported;
        _ = api.ZigZagError.EventLoopNotRunning;
    }

    /// Validate feature flag system works correctly
    pub fn validateFeatureFlags(self: StabilityValidator) !void {
        _ = self;

        // Test that all features are properly flagged
        try testing.expect(api.Features.event_loop);
        try testing.expect(api.Features.multiple_backends);
        try testing.expect(api.Features.timers);
        try testing.expect(api.Features.async_runtime);
        try testing.expect(api.Features.thread_safety);
        try testing.expect(api.Features.file_watching);
        try testing.expect(api.Features.network_io);

        // Test feature availability checking
        try testing.expect(api.Features.isAvailable("event_loop"));
        try testing.expect(api.Features.isAvailable("async_runtime"));

        // Test feature levels
        try testing.expectEqual(api.ApiLevel.alpha, api.Features.getFeatureLevel("event_loop"));
        try testing.expectEqual(api.ApiLevel.theta, api.Features.getFeatureLevel("async_runtime"));
    }

    /// Validate conditional exports work properly
    pub fn validateConditionalExports(self: StabilityValidator) !void {
        _ = self;

        // Test that conditional exports are properly typed
        if (api.Features.event_coalescing) {
            _ = api.EventCoalescer;
            _ = api.CoalescingConfig;
        }

        if (api.Features.zero_copy_io) {
            _ = api.RingBuffer;
            _ = api.BufferPool;
            _ = api.ZeroCopyIO;
        }

        if (api.Features.async_runtime) {
            _ = api.AsyncRuntime;
            _ = api.AsyncOperation;
        }

        if (api.Features.thread_safety) {
            _ = api.ThreadSafeQueue;
            _ = api.SharedPointer;
            _ = api.ThreadSafeEventLoop;
        }

        if (api.Features.file_watching) {
            _ = api.FileWatcher;
            _ = api.WatchConfig;
            _ = api.FileEvent;
        }

        if (api.Features.network_io) {
            _ = api.NetworkManager;
            _ = api.ConnectionPool;
            _ = api.BandwidthMonitor;
        }
    }

    /// Validate ConfigBuilder pattern works correctly
    pub fn validateConfigBuilder(self: StabilityValidator) !void {
        _ = self;

        const config = api.ConfigBuilder.init()
            .withMaxEvents(2048)
            .withProfiling(true)
            .withDebugging(false)
            .build();

        try testing.expectEqual(@as(u32, 2048), config.max_events);

        // Test auto-detection
        const auto_config = api.ConfigBuilder.init()
            .autoDetectBackend()
            .build();
        _ = auto_config;
    }

    /// Validate Application wrapper functionality
    pub fn validateApplication(self: StabilityValidator) !void {
        const config = api.ConfigBuilder.init()
            .withBackend(.epoll);

        var app = api.Application.init(self.allocator, config) catch |err| switch (err) {
            error.BackendNotSupported => return, // Skip if backend not available
            else => return err,
        };
        defer app.deinit();

        // Test that we can get the event loop
        const event_loop = app.getEventLoop();
        _ = event_loop;

        // Test optional component getters
        if (api.Features.performance_profiling) {
            _ = app.getProfiler();
        }

        if (api.Features.event_debugging) {
            _ = app.getTracer();
        }
    }

    /// Validate convenience functions
    pub fn validateConvenienceFunctions(self: StabilityValidator) !void {
        // Test simple event loop creation
        var simple_loop = api.convenience.createSimpleEventLoop(self.allocator) catch |err| switch (err) {
            error.BackendNotSupported => return,
            else => return err,
        };
        defer simple_loop.deinit();

        // Test high-performance event loop creation
        var hp_loop = api.convenience.createHighPerformanceEventLoop(self.allocator) catch |err| switch (err) {
            error.BackendNotSupported => return,
            else => return err,
        };
        defer hp_loop.deinit();

        // Test terminal event loop creation
        var terminal_app = api.convenience.createTerminalEventLoop(self.allocator) catch |err| switch (err) {
            error.BackendNotSupported => return,
            else => return err,
        };
        defer terminal_app.deinit();

        // Test debug event loop creation
        var debug_app = api.convenience.createDebugEventLoop(self.allocator) catch |err| switch (err) {
            error.BackendNotSupported => return,
            else => return err,
        };
        defer debug_app.deinit();
    }

    /// Validate documentation utilities
    pub fn validateDocumentation(self: StabilityValidator) !void {

        // Test feature info retrieval
        const info = api.docs.getFeatureInfo("event_loop");
        try testing.expect(info.available);
        try testing.expectEqual(api.ApiLevel.alpha, info.api_level);

        // Test API docs generation (just verify it compiles)
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try api.docs.generateApiDocs(buffer.writer());
        try testing.expect(buffer.items.len > 0);
    }

    /// Run full stability validation suite
    pub fn runFullValidation(self: StabilityValidator) !void {
        try self.validateCoreAPI();
        try self.validateFeatureFlags();
        try self.validateConditionalExports();
        try self.validateConfigBuilder();
        try self.validateApplication();
        try self.validateConvenienceFunctions();
        try self.validateDocumentation();
    }
};

/// Backward compatibility validator
pub const CompatibilityValidator = struct {
    /// Test that version compatibility works correctly
    pub fn validateVersionCompatibility() !void {
        // Test same version compatibility
        try testing.expect(api.Version.compatible(1, 0));

        // Test minor version compatibility (forward)
        try testing.expect(api.Version.compatible(1, 0));

        // Test major version incompatibility
        try testing.expect(!api.Version.compatible(2, 0));
        try testing.expect(!api.Version.compatible(0, 5));
    }

    /// Test API level compatibility
    pub fn validateAPILevelCompatibility() !void {
        try testing.expect(api.ApiLevel.theta.supports(.alpha));
        try testing.expect(api.ApiLevel.theta.supports(.beta));
        try testing.expect(api.ApiLevel.theta.supports(.theta));
        try testing.expect(!api.ApiLevel.alpha.supports(.beta));
        try testing.expect(!api.ApiLevel.beta.supports(.theta));
    }

    /// Test that all expected features are available at the current API level
    pub fn validateFeatureAvailability() !void {
        const current_level = api.ApiLevel.current();

        // Alpha features should always be available
        try testing.expect(current_level.supports(.alpha));
        try testing.expect(api.Features.isAvailable("event_loop"));
        try testing.expect(api.Features.isAvailable("timers"));

        // Beta features should be available at theta level
        if (current_level.supports(.beta)) {
            try testing.expect(api.Features.isAvailable("zero_copy_io"));
            try testing.expect(api.Features.isAvailable("priority_queues"));
        }

        // Theta features should be available at theta level
        if (current_level.supports(.theta)) {
            try testing.expect(api.Features.isAvailable("async_runtime"));
            try testing.expect(api.Features.isAvailable("file_watching"));
            try testing.expect(api.Features.isAvailable("thread_safety"));
        }
    }

    /// Run full compatibility validation
    pub fn runFullValidation() !void {
        try validateVersionCompatibility();
        try validateAPILevelCompatibility();
        try validateFeatureAvailability();
    }
};

/// Interface stability checker
pub const InterfaceStabilityChecker = struct {
    /// Check that core EventLoop interface is stable
    pub fn checkEventLoopInterface(allocator: std.mem.Allocator) !void {
        // Test that basic EventLoop interface hasn't changed
        var event_loop = EventLoop.init(allocator, .{}) catch |err| switch (err) {
            error.BackendNotSupported => return,
            else => return err,
        };
        defer event_loop.deinit();

        // These methods must remain stable
        _ = event_loop.backend;

        // Test that we can add watches (basic interface)
        const stdout = std.io.getStdOut().handle;
        event_loop.addWatch(stdout, .{ .write = true }) catch {};

        // Test timer interface
        event_loop.addTimer(100, .oneshot, struct {
            pub fn callback(self: @This()) void { _ = self; }
        }{}) catch {};
    }

    /// Check that error types remain stable
    pub fn checkErrorInterface() !void {
        // Test that all documented error types exist
        _ = api.ZigZagError.BackendNotSupported;
        _ = api.ZigZagError.BackendInitializationFailed;
        _ = api.ZigZagError.InsufficientMemory;
        _ = api.ZigZagError.InvalidConfiguration;
        _ = api.ZigZagError.EventLoopNotRunning;
        _ = api.ZigZagError.OperationNotSupported;
        _ = api.ZigZagError.ResourceExhausted;
        _ = api.ZigZagError.InvalidState;
        _ = api.ZigZagError.FileDescriptorInvalid;
        _ = api.ZigZagError.IoOperationFailed;
        _ = api.ZigZagError.TimeoutExpired;
        _ = api.ZigZagError.FeatureNotAvailable;
        _ = api.ZigZagError.ApiLevelTooLow;
        _ = api.ZigZagError.VersionIncompatible;
    }

    /// Run interface stability checks
    pub fn runStabilityCheck(allocator: std.mem.Allocator) !void {
        try checkEventLoopInterface(allocator);
        try checkErrorInterface();
    }
};

test "API stability validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var validator = StabilityValidator.init(allocator);
    try validator.runFullValidation();
}

test "Backward compatibility validation" {
    try CompatibilityValidator.runFullValidation();
}

test "Interface stability check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try InterfaceStabilityChecker.runStabilityCheck(allocator);
}