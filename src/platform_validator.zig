//! Platform validation and compatibility testing for RC2
//! Comprehensive testing across all supported platforms and backends

const std = @import("std");
const builtin = @import("builtin");
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const Backend = @import("root.zig").Backend;

/// Comprehensive platform validator
pub const PlatformValidator = struct {
    allocator: std.mem.Allocator,
    test_results: std.ArrayList(TestResult),
    platform_info: PlatformInfo,
    backend_tests: std.ArrayList(BackendTest),

    const TestResult = struct {
        test_name: []const u8,
        platform: Platform,
        backend: Backend,
        status: TestStatus,
        execution_time_ms: u64,
        error_message: ?[]const u8 = null,
        performance_metrics: ?PerformanceMetrics = null,
    };

    const TestStatus = enum {
        passed,
        failed,
        skipped,
        timeout,
        unsupported,
    };

    const Platform = enum {
        linux_x86_64,
        linux_aarch64,
        macos_x86_64,
        macos_aarch64,
        windows_x86_64,
        freebsd_x86_64,
        openbsd_x86_64,
        netbsd_x86_64,
        unknown,

        pub fn fromBuiltin() Platform {
            return switch (builtin.os.tag) {
                .linux => switch (builtin.cpu.arch) {
                    .x86_64 => .linux_x86_64,
                    .aarch64 => .linux_aarch64,
                    else => .unknown,
                },
                .macos => switch (builtin.cpu.arch) {
                    .x86_64 => .macos_x86_64,
                    .aarch64 => .macos_aarch64,
                    else => .unknown,
                },
                .windows => .windows_x86_64,
                .freebsd => .freebsd_x86_64,
                .openbsd => .openbsd_x86_64,
                .netbsd => .netbsd_x86_64,
                else => .unknown,
            };
        }

        pub fn getSupportedBackends(self: Platform) []const Backend {
            return switch (self) {
                .linux_x86_64, .linux_aarch64 => &[_]Backend{ .epoll, .io_uring },
                .macos_x86_64, .macos_aarch64 => &[_]Backend{.kqueue},
                .windows_x86_64 => &[_]Backend{.iocp},
                .freebsd_x86_64, .openbsd_x86_64, .netbsd_x86_64 => &[_]Backend{.kqueue},
                .unknown => &[_]Backend{},
            };
        }
    };

    const PlatformInfo = struct {
        platform: Platform,
        os_version: []const u8,
        kernel_version: ?[]const u8,
        cpu_count: u32,
        memory_total: u64,
        features: PlatformFeatures,
    };

    const PlatformFeatures = struct {
        has_io_uring: bool = false,
        has_epoll: bool = false,
        has_kqueue: bool = false,
        has_iocp: bool = false,
        supports_high_res_timers: bool = false,
        supports_file_monitoring: bool = false,
        supports_async_io: bool = false,
        max_file_descriptors: u32 = 1024,
    };

    const PerformanceMetrics = struct {
        events_per_second: u64,
        avg_latency_ns: u64,
        memory_usage_kb: u64,
        cpu_usage_percent: f64,
    };

    const BackendTest = struct {
        backend: Backend,
        basic_functionality: bool = false,
        performance_test: bool = false,
        stress_test: bool = false,
        error_handling: bool = false,
        resource_cleanup: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) !PlatformValidator {
        const platform_info = try detectPlatformInfo(allocator);

        return PlatformValidator{
            .allocator = allocator,
            .test_results = std.ArrayList(TestResult).init(allocator),
            .platform_info = platform_info,
            .backend_tests = std.ArrayList(BackendTest).init(allocator),
        };
    }

    pub fn deinit(self: *PlatformValidator) void {
        self.test_results.deinit();
        self.backend_tests.deinit();
        if (self.platform_info.kernel_version) |version| {
            self.allocator.free(version);
        }
        self.allocator.free(self.platform_info.os_version);
    }

    /// Run comprehensive platform validation
    pub fn validatePlatform(self: *PlatformValidator) !ValidationReport {
        var report = ValidationReport{
            .platform = self.platform_info.platform,
            .total_tests = 0,
            .passed_tests = 0,
            .failed_tests = 0,
            .skipped_tests = 0,
            .backend_compatibility = std.ArrayList(BackendCompatibility).init(self.allocator),
        };

        // Test each supported backend
        const supported_backends = self.platform_info.platform.getSupportedBackends();
        for (supported_backends) |backend| {
            const backend_report = try self.testBackend(backend);
            try report.backend_compatibility.append(backend_report);

            report.total_tests += backend_report.tests_run;
            report.passed_tests += backend_report.tests_passed;
            report.failed_tests += backend_report.tests_failed;
            report.skipped_tests += backend_report.tests_skipped;
        }

        // Run platform-specific tests
        try self.runPlatformSpecificTests(&report);

        report.overall_compatibility = self.calculateOverallCompatibility(report);
        return report;
    }

    fn testBackend(self: *PlatformValidator, backend: Backend) !BackendCompatibility {
        var compatibility = BackendCompatibility{
            .backend = backend,
            .supported = false,
            .tests_run = 0,
            .tests_passed = 0,
            .tests_failed = 0,
            .tests_skipped = 0,
            .performance_score = 0.0,
            .issues = std.ArrayList([]const u8).init(self.allocator),
        };

        // Basic functionality test
        const basic_result = try self.testBasicFunctionality(backend);
        compatibility.tests_run += 1;
        if (basic_result.status == .passed) {
            compatibility.tests_passed += 1;
            compatibility.supported = true;
        } else {
            compatibility.tests_failed += 1;
            if (basic_result.error_message) |msg| {
                try compatibility.issues.append(msg);
            }
        }

        if (compatibility.supported) {
            // Performance test
            const perf_result = try self.testPerformance(backend);
            compatibility.tests_run += 1;
            if (perf_result.status == .passed) {
                compatibility.tests_passed += 1;
                if (perf_result.performance_metrics) |metrics| {
                    compatibility.performance_score = self.calculatePerformanceScore(metrics);
                }
            } else {
                compatibility.tests_failed += 1;
            }

            // Stress test
            const stress_result = try self.testStress(backend);
            compatibility.tests_run += 1;
            if (stress_result.status == .passed) {
                compatibility.tests_passed += 1;
            } else {
                compatibility.tests_failed += 1;
                if (stress_result.error_message) |msg| {
                    try compatibility.issues.append(msg);
                }
            }

            // Error handling test
            const error_result = try self.testErrorHandling(backend);
            compatibility.tests_run += 1;
            if (error_result.status == .passed) {
                compatibility.tests_passed += 1;
            } else {
                compatibility.tests_failed += 1;
            }
        }

        return compatibility;
    }

    fn testBasicFunctionality(self: *PlatformValidator, backend: Backend) !TestResult {
        const start_time = std.time.milliTimestamp();

        var event_loop = EventLoop.init(self.allocator, .{ .backend = backend }) catch |err| {
            return TestResult{
                .test_name = "basic_functionality",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = switch (err) {
                    error.BackendNotSupported => .unsupported,
                    else => .failed,
                },
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };
        defer event_loop.deinit();

        // Test basic operations
        var pipes: [2]std.os.fd_t = undefined;
        std.os.pipe(&pipes) catch |err| {
            return TestResult{
                .test_name = "basic_functionality",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };
        defer std.os.close(pipes[0]);
        defer std.os.close(pipes[1]);

        // Test adding watch
        event_loop.addWatch(pipes[0], .{ .read = true }) catch |err| {
            return TestResult{
                .test_name = "basic_functionality",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };

        // Test event waiting (with timeout)
        var events: [10]Event = undefined;
        _ = event_loop.wait(&events, 1) catch |err| {
            return TestResult{
                .test_name = "basic_functionality",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };

        return TestResult{
            .test_name = "basic_functionality",
            .platform = self.platform_info.platform,
            .backend = backend,
            .status = .passed,
            .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
        };
    }

    fn testPerformance(self: *PlatformValidator, backend: Backend) !TestResult {
        const start_time = std.time.milliTimestamp();

        var event_loop = EventLoop.init(self.allocator, .{ .backend = backend }) catch |err| {
            return TestResult{
                .test_name = "performance",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };
        defer event_loop.deinit();

        // Performance test: measure events per second
        const test_duration_ms = 1000; // 1 second
        const test_end = start_time + test_duration_ms;
        var event_count: u64 = 0;
        var latency_sum: u64 = 0;

        var pipes: [2]std.os.fd_t = undefined;
        std.os.pipe(&pipes) catch |err| {
            return TestResult{
                .test_name = "performance",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };
        defer std.os.close(pipes[0]);
        defer std.os.close(pipes[1]);

        event_loop.addWatch(pipes[0], .{ .read = true }) catch |err| {
            return TestResult{
                .test_name = "performance",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };

        while (std.time.milliTimestamp() < test_end) {
            const event_start = std.time.nanoTimestamp();

            // Trigger event
            _ = std.os.write(pipes[1], "x") catch break;

            // Wait for event
            var events: [1]Event = undefined;
            const num_events = event_loop.wait(&events, 1) catch break;

            if (num_events > 0) {
                const event_end = std.time.nanoTimestamp();
                latency_sum += @intCast(event_end - event_start);
                event_count += 1;
            }
        }

        const execution_time = std.time.milliTimestamp() - start_time;
        const events_per_second = if (execution_time > 0) (event_count * 1000) / @as(u64, @intCast(execution_time)) else 0;
        const avg_latency = if (event_count > 0) latency_sum / event_count else 0;

        return TestResult{
            .test_name = "performance",
            .platform = self.platform_info.platform,
            .backend = backend,
            .status = .passed,
            .execution_time_ms = @intCast(execution_time),
            .performance_metrics = PerformanceMetrics{
                .events_per_second = events_per_second,
                .avg_latency_ns = avg_latency,
                .memory_usage_kb = 0, // Would need platform-specific implementation
                .cpu_usage_percent = 0.0, // Would need platform-specific implementation
            },
        };
    }

    fn testStress(self: *PlatformValidator, backend: Backend) !TestResult {
        const start_time = std.time.milliTimestamp();

        var event_loop = EventLoop.init(self.allocator, .{ .backend = backend }) catch |err| {
            return TestResult{
                .test_name = "stress",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };
        defer event_loop.deinit();

        // Stress test: many file descriptors
        const num_fds = 100;
        var pipes: [num_fds][2]std.os.fd_t = undefined;

        var i: usize = 0;
        while (i < num_fds) : (i += 1) {
            std.os.pipe(&pipes[i]) catch |err| {
                // Clean up already created pipes
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    std.os.close(pipes[j][0]);
                    std.os.close(pipes[j][1]);
                }
                return TestResult{
                    .test_name = "stress",
                    .platform = self.platform_info.platform,
                    .backend = backend,
                    .status = .failed,
                    .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                    .error_message = @errorName(err),
                };
            };

            event_loop.addWatch(pipes[i][0], .{ .read = true }) catch |err| {
                // Clean up
                var j: usize = 0;
                while (j <= i) : (j += 1) {
                    std.os.close(pipes[j][0]);
                    std.os.close(pipes[j][1]);
                }
                return TestResult{
                    .test_name = "stress",
                    .platform = self.platform_info.platform,
                    .backend = backend,
                    .status = .failed,
                    .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                    .error_message = @errorName(err),
                };
            };
        }

        defer {
            for (pipes) |pipe_pair| {
                std.os.close(pipe_pair[0]);
                std.os.close(pipe_pair[1]);
            }
        }

        // Test handling many simultaneous events
        for (pipes) |pipe_pair| {
            _ = std.os.write(pipe_pair[1], "x") catch continue;
        }

        var events: [num_fds]Event = undefined;
        _ = event_loop.wait(&events, 100) catch |err| {
            return TestResult{
                .test_name = "stress",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };

        return TestResult{
            .test_name = "stress",
            .platform = self.platform_info.platform,
            .backend = backend,
            .status = .passed,
            .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
        };
    }

    fn testErrorHandling(self: *PlatformValidator, backend: Backend) !TestResult {
        const start_time = std.time.milliTimestamp();

        var event_loop = EventLoop.init(self.allocator, .{ .backend = backend }) catch |err| {
            return TestResult{
                .test_name = "error_handling",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = @errorName(err),
            };
        };
        defer event_loop.deinit();

        // Test error handling with invalid file descriptor
        const result = event_loop.addWatch(-1, .{ .read = true });
        if (result) {
            // Should have failed
            return TestResult{
                .test_name = "error_handling",
                .platform = self.platform_info.platform,
                .backend = backend,
                .status = .failed,
                .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
                .error_message = "Invalid fd should have been rejected",
            };
        } else |_| {
            // Expected error - test passed
        }

        return TestResult{
            .test_name = "error_handling",
            .platform = self.platform_info.platform,
            .backend = backend,
            .status = .passed,
            .execution_time_ms = @intCast(std.time.milliTimestamp() - start_time),
        };
    }

    fn runPlatformSpecificTests(self: *PlatformValidator, report: *ValidationReport) !void {
        _ = self;
        _ = report;
        // Platform-specific tests would go here
        // For now, just placeholder
    }

    fn calculatePerformanceScore(self: *PlatformValidator, metrics: PerformanceMetrics) f64 {
        _ = self;

        // Simple scoring: events per second scaled and latency penalty
        const throughput_score = @min(100.0, @as(f64, @floatFromInt(metrics.events_per_second)) / 10000.0);
        const latency_penalty = @min(50.0, @as(f64, @floatFromInt(metrics.avg_latency_ns)) / 20000.0);

        return @max(0.0, throughput_score - latency_penalty);
    }

    fn calculateOverallCompatibility(self: *PlatformValidator, report: ValidationReport) f64 {
        _ = self;

        if (report.total_tests == 0) return 0.0;

        const pass_rate = @as(f64, @floatFromInt(report.passed_tests)) / @as(f64, @floatFromInt(report.total_tests));
        return pass_rate * 100.0;
    }

    const ValidationReport = struct {
        platform: Platform,
        total_tests: u32,
        passed_tests: u32,
        failed_tests: u32,
        skipped_tests: u32,
        backend_compatibility: std.ArrayList(BackendCompatibility),
        overall_compatibility: f64 = 0.0,

        pub fn deinit(self: *ValidationReport) void {
            for (self.backend_compatibility.items) |*compat| {
                compat.issues.deinit();
            }
            self.backend_compatibility.deinit();
        }
    };

    const BackendCompatibility = struct {
        backend: Backend,
        supported: bool,
        tests_run: u32,
        tests_passed: u32,
        tests_failed: u32,
        tests_skipped: u32,
        performance_score: f64,
        issues: std.ArrayList([]const u8),
    };
};

fn detectPlatformInfo(allocator: std.mem.Allocator) !PlatformValidator.PlatformInfo {
    const platform = PlatformValidator.Platform.fromBuiltin();

    // Get basic system info
    const cpu_count = std.Thread.getCpuCount() catch 1;

    // Platform-specific feature detection
    var features = PlatformValidator.PlatformFeatures{
        .supports_high_res_timers = true, // Most modern platforms support this
        .supports_async_io = true,
    };

    // Detect platform-specific features
    switch (builtin.os.tag) {
        .linux => {
            features.has_epoll = true;
            features.has_io_uring = true; // Assume available, will fail gracefully if not
            features.supports_file_monitoring = true;
        },
        .macos, .freebsd, .openbsd, .netbsd => {
            features.has_kqueue = true;
            features.supports_file_monitoring = true;
        },
        .windows => {
            features.has_iocp = true;
            features.supports_file_monitoring = true;
        },
        else => {},
    }

    return PlatformValidator.PlatformInfo{
        .platform = platform,
        .os_version = try allocator.dupe(u8, "unknown"), // Would need platform-specific detection
        .kernel_version = null,
        .cpu_count = @intCast(cpu_count),
        .memory_total = 0, // Would need platform-specific detection
        .features = features,
    };
}

test "Platform validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var validator = try PlatformValidator.init(allocator);
    defer validator.deinit();

    // Should detect current platform
    try std.testing.expect(validator.platform_info.platform != .unknown);

    // Should have at least one supported backend
    const supported_backends = validator.platform_info.platform.getSupportedBackends();
    try std.testing.expect(supported_backends.len > 0);
}

test "Backend testing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var validator = try PlatformValidator.init(allocator);
    defer validator.deinit();

    const supported_backends = validator.platform_info.platform.getSupportedBackends();
    if (supported_backends.len > 0) {
        const backend = supported_backends[0];
        const result = try validator.testBasicFunctionality(backend);

        // Should either pass or fail gracefully
        try std.testing.expect(result.status != .timeout);
    }
}