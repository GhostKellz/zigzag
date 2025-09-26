//! Performance optimization and real-world usage pattern tuning
//! Provides automatic optimization based on usage patterns and workload analysis

const std = @import("std");
const builtin = @import("builtin");
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;
const Backend = @import("root.zig").Backend;

/// Usage pattern analyzer
pub const UsagePatternAnalyzer = struct {
    allocator: std.mem.Allocator,
    event_samples: std.ArrayList(EventSample),
    analysis_window_ms: u64,
    last_analysis: i64,
    current_pattern: UsagePattern,

    const EventSample = struct {
        timestamp: i64,
        event_type: EventType,
        processing_time_ns: u64,
        fd: i32,
        data_size: usize,
    };

    const UsagePattern = enum {
        unknown,
        terminal_emulator,
        network_server,
        file_monitor,
        gaming_app,
        data_processing,
        mixed_workload,
    };

    pub fn init(allocator: std.mem.Allocator, window_ms: u64) UsagePatternAnalyzer {
        return UsagePatternAnalyzer{
            .allocator = allocator,
            .event_samples = std.ArrayList(EventSample).init(allocator),
            .analysis_window_ms = window_ms,
            .last_analysis = std.time.milliTimestamp(),
            .current_pattern = .unknown,
        };
    }

    pub fn deinit(self: *UsagePatternAnalyzer) void {
        self.event_samples.deinit();
    }

    /// Record an event for pattern analysis
    pub fn recordEvent(self: *UsagePatternAnalyzer, event_type: EventType, processing_time: u64, fd: i32, data_size: usize) !void {
        const sample = EventSample{
            .timestamp = std.time.milliTimestamp(),
            .event_type = event_type,
            .processing_time_ns = processing_time,
            .fd = fd,
            .data_size = data_size,
        };

        try self.event_samples.append(sample);

        // Clean old samples
        const cutoff = sample.timestamp - @as(i64, @intCast(self.analysis_window_ms));
        var i: usize = 0;
        while (i < self.event_samples.items.len) {
            if (self.event_samples.items[i].timestamp < cutoff) {
                _ = self.event_samples.orderedRemove(i);
            } else {
                break;
            }
        }

        // Analyze pattern if enough time has passed
        if ((sample.timestamp - self.last_analysis) > @as(i64, @intCast(self.analysis_window_ms / 4))) {
            self.current_pattern = self.analyzePattern();
            self.last_analysis = sample.timestamp;
        }
    }

    /// Analyze current usage pattern
    fn analyzePattern(self: *UsagePatternAnalyzer) UsagePattern {
        if (self.event_samples.items.len < 10) return .unknown;

        var stdin_events: u32 = 0;
        var network_events: u32 = 0;
        var file_events: u32 = 0;
        var high_frequency_events: u32 = 0;
        var large_data_events: u32 = 0;

        var total_processing_time: u64 = 0;
        var max_processing_time: u64 = 0;

        for (self.event_samples.items) |sample| {
            total_processing_time += sample.processing_time_ns;
            max_processing_time = @max(max_processing_time, sample.processing_time_ns);

            // Classify event types
            if (sample.fd == 0) { // stdin
                stdin_events += 1;
            } else if (sample.fd > 2 and sample.data_size > 0) {
                if (sample.data_size > 8192) {
                    network_events += 1;
                } else {
                    file_events += 1;
                }
            }

            if (sample.processing_time_ns < 1000) { // < 1μs
                high_frequency_events += 1;
            }

            if (sample.data_size > 64 * 1024) { // > 64KB
                large_data_events += 1;
            }
        }

        const total_events = @as(f32, @floatFromInt(self.event_samples.items.len));
        const stdin_ratio = @as(f32, @floatFromInt(stdin_events)) / total_events;
        const network_ratio = @as(f32, @floatFromInt(network_events)) / total_events;
        const file_ratio = @as(f32, @floatFromInt(file_events)) / total_events;
        const high_freq_ratio = @as(f32, @floatFromInt(high_frequency_events)) / total_events;
        const large_data_ratio = @as(f32, @floatFromInt(large_data_events)) / total_events;

        // Pattern classification logic
        if (stdin_ratio > 0.4 and high_freq_ratio > 0.6) {
            return .terminal_emulator;
        } else if (network_ratio > 0.7 and large_data_ratio > 0.3) {
            return .network_server;
        } else if (file_ratio > 0.8) {
            return .file_monitor;
        } else if (high_freq_ratio > 0.8 and max_processing_time < 5000) {
            return .gaming_app;
        } else if (large_data_ratio > 0.5) {
            return .data_processing;
        } else if (stdin_ratio + network_ratio + file_ratio > 0.3) {
            return .mixed_workload;
        }

        return .unknown;
    }

    pub fn getCurrentPattern(self: UsagePatternAnalyzer) UsagePattern {
        return self.current_pattern;
    }

    pub fn getPatternMetrics(self: UsagePatternAnalyzer) PatternMetrics {
        if (self.event_samples.items.len == 0) {
            return PatternMetrics{};
        }

        var total_processing_time: u64 = 0;
        var min_processing_time: u64 = std.math.maxInt(u64);
        var max_processing_time: u64 = 0;
        var total_data_size: u64 = 0;

        for (self.event_samples.items) |sample| {
            total_processing_time += sample.processing_time_ns;
            min_processing_time = @min(min_processing_time, sample.processing_time_ns);
            max_processing_time = @max(max_processing_time, sample.processing_time_ns);
            total_data_size += sample.data_size;
        }

        const event_count = self.event_samples.items.len;
        const avg_processing_time = total_processing_time / @as(u64, @intCast(event_count));
        const avg_data_size = total_data_size / @as(u64, @intCast(event_count));

        return PatternMetrics{
            .event_count = @intCast(event_count),
            .avg_processing_time_ns = avg_processing_time,
            .min_processing_time_ns = min_processing_time,
            .max_processing_time_ns = max_processing_time,
            .avg_data_size = avg_data_size,
            .events_per_second = @as(u32, @intCast(event_count * 1000 / self.analysis_window_ms)),
        };
    }

    const PatternMetrics = struct {
        event_count: u32 = 0,
        avg_processing_time_ns: u64 = 0,
        min_processing_time_ns: u64 = 0,
        max_processing_time_ns: u64 = 0,
        avg_data_size: u64 = 0,
        events_per_second: u32 = 0,
    };
};

/// Automatic optimizer that adjusts settings based on usage patterns
pub const AutoOptimizer = struct {
    allocator: std.mem.Allocator,
    pattern_analyzer: UsagePatternAnalyzer,
    current_config: OptimizationConfig,
    last_optimization: i64,
    optimization_interval_ms: u64,

    pub const OptimizationConfig = struct {
        max_events: u32 = 256,
        timeout_ms: u32 = 1,
        coalescing_enabled: bool = false,
        coalescing_window_ms: u32 = 10,
        buffer_size: u32 = 8192,
        thread_count: u32 = 1,
        memory_pool_size: u32 = 1024 * 1024, // 1MB
        preferred_backend: ?Backend = null,
    };

    pub fn init(allocator: std.mem.Allocator) AutoOptimizer {
        return AutoOptimizer{
            .allocator = allocator,
            .pattern_analyzer = UsagePatternAnalyzer.init(allocator, 30000), // 30 second window
            .current_config = OptimizationConfig{},
            .last_optimization = std.time.milliTimestamp(),
            .optimization_interval_ms = 5000, // Re-optimize every 5 seconds
        };
    }

    pub fn deinit(self: *AutoOptimizer) void {
        self.pattern_analyzer.deinit();
    }

    /// Record an event and potentially trigger optimization
    pub fn recordEvent(self: *AutoOptimizer, event_type: EventType, processing_time: u64, fd: i32, data_size: usize) !bool {
        try self.pattern_analyzer.recordEvent(event_type, processing_time, fd, data_size);

        const now = std.time.milliTimestamp();
        if ((now - self.last_optimization) >= @as(i64, @intCast(self.optimization_interval_ms))) {
            const old_config = self.current_config;
            self.optimize();
            self.last_optimization = now;

            // Return true if configuration changed significantly
            return !std.meta.eql(old_config, self.current_config);
        }

        return false;
    }

    /// Optimize configuration based on current usage pattern
    fn optimize(self: *AutoOptimizer) void {
        const pattern = self.pattern_analyzer.getCurrentPattern();
        const metrics = self.pattern_analyzer.getPatternMetrics();

        self.current_config = switch (pattern) {
            .terminal_emulator => OptimizationConfig{
                .max_events = 64,
                .timeout_ms = 1,
                .coalescing_enabled = true,
                .coalescing_window_ms = 16, // ~60fps
                .buffer_size = 4096,
                .thread_count = 1,
                .memory_pool_size = 512 * 1024, // 512KB
                .preferred_backend = if (builtin.os.tag == .linux) .epoll else null,
            },
            .network_server => OptimizationConfig{
                .max_events = 1024,
                .timeout_ms = 0, // Non-blocking
                .coalescing_enabled = false,
                .coalescing_window_ms = 1,
                .buffer_size = 64 * 1024, // 64KB
                .thread_count = @max(1, std.Thread.getCpuCount() catch 1),
                .memory_pool_size = 8 * 1024 * 1024, // 8MB
                .preferred_backend = if (builtin.os.tag == .linux) .io_uring else .epoll,
            },
            .file_monitor => OptimizationConfig{
                .max_events = 256,
                .timeout_ms = 100, // Allow some batching
                .coalescing_enabled = true,
                .coalescing_window_ms = 50,
                .buffer_size = 16 * 1024, // 16KB
                .thread_count = 1,
                .memory_pool_size = 2 * 1024 * 1024, // 2MB
                .preferred_backend = null, // Use default
            },
            .gaming_app => OptimizationConfig{
                .max_events = 128,
                .timeout_ms = 0, // Ultra-low latency
                .coalescing_enabled = false,
                .coalescing_window_ms = 1,
                .buffer_size = 4096,
                .thread_count = 1, // Deterministic single-threaded
                .memory_pool_size = 1 * 1024 * 1024, // 1MB
                .preferred_backend = if (builtin.os.tag == .linux) .epoll else null,
            },
            .data_processing => OptimizationConfig{
                .max_events = 512,
                .timeout_ms = 10, // Allow batching
                .coalescing_enabled = true,
                .coalescing_window_ms = 20,
                .buffer_size = 128 * 1024, // 128KB
                .thread_count = @max(1, std.Thread.getCpuCount() catch 1),
                .memory_pool_size = 16 * 1024 * 1024, // 16MB
                .preferred_backend = if (builtin.os.tag == .linux) .io_uring else null,
            },
            .mixed_workload => self.optimizeForMixed(metrics),
            .unknown => self.current_config, // Keep current config
        };
    }

    /// Optimize for mixed workload based on metrics
    fn optimizeForMixed(self: *AutoOptimizer, metrics: UsagePatternAnalyzer.PatternMetrics) OptimizationConfig {
        _ = self;
        var config = OptimizationConfig{};

        // Adjust based on event frequency
        if (metrics.events_per_second > 10000) {
            config.max_events = 1024;
            config.timeout_ms = 0;
            config.coalescing_enabled = false;
        } else if (metrics.events_per_second > 1000) {
            config.max_events = 512;
            config.timeout_ms = 1;
            config.coalescing_enabled = true;
            config.coalescing_window_ms = 5;
        } else {
            config.max_events = 256;
            config.timeout_ms = 10;
            config.coalescing_enabled = true;
            config.coalescing_window_ms = 20;
        }

        // Adjust buffer size based on data size
        if (metrics.avg_data_size > 32 * 1024) {
            config.buffer_size = 128 * 1024;
            config.memory_pool_size = 16 * 1024 * 1024;
        } else if (metrics.avg_data_size > 4 * 1024) {
            config.buffer_size = 32 * 1024;
            config.memory_pool_size = 4 * 1024 * 1024;
        } else {
            config.buffer_size = 8 * 1024;
            config.memory_pool_size = 1 * 1024 * 1024;
        }

        // Adjust thread count based on processing time
        if (metrics.avg_processing_time_ns > 10000) { // > 10μs
            config.thread_count = @max(1, std.Thread.getCpuCount() catch 1);
        } else {
            config.thread_count = 1;
        }

        return config;
    }

    pub fn getCurrentConfig(self: AutoOptimizer) OptimizationConfig {
        return self.current_config;
    }

    pub fn getCurrentPattern(self: AutoOptimizer) UsagePatternAnalyzer.UsagePattern {
        return self.pattern_analyzer.getCurrentPattern();
    }

    pub fn getPatternMetrics(self: AutoOptimizer) UsagePatternAnalyzer.PatternMetrics {
        return self.pattern_analyzer.getPatternMetrics();
    }
};

/// Memory pool optimizer for efficient allocation patterns
pub const MemoryPoolOptimizer = struct {
    allocator: std.mem.Allocator,
    allocation_sizes: std.ArrayList(usize),
    pool_configs: std.ArrayList(PoolConfig),
    analysis_threshold: u32,

    const PoolConfig = struct {
        size: usize,
        count: u32,
        hit_rate: f32,
    };

    pub fn init(allocator: std.mem.Allocator) MemoryPoolOptimizer {
        return MemoryPoolOptimizer{
            .allocator = allocator,
            .allocation_sizes = std.ArrayList(usize).init(allocator),
            .pool_configs = std.ArrayList(PoolConfig).init(allocator),
            .analysis_threshold = 1000,
        };
    }

    pub fn deinit(self: *MemoryPoolOptimizer) void {
        self.allocation_sizes.deinit();
        self.pool_configs.deinit();
    }

    pub fn recordAllocation(self: *MemoryPoolOptimizer, size: usize) !void {
        try self.allocation_sizes.append(size);

        if (self.allocation_sizes.items.len >= self.analysis_threshold) {
            try self.analyzeAndOptimize();
            self.allocation_sizes.clearRetainingCapacity();
        }
    }

    fn analyzeAndOptimize(self: *MemoryPoolOptimizer) !void {
        // Sort allocation sizes to find common patterns
        std.mem.sort(usize, self.allocation_sizes.items, {}, comptime std.sort.asc(usize));

        // Find common allocation sizes (within 10% tolerance)
        self.pool_configs.clearRetainingCapacity();

        var i: usize = 0;
        while (i < self.allocation_sizes.items.len) {
            const size = self.allocation_sizes.items[i];
            var count: u32 = 1;
            var j = i + 1;

            // Count similar-sized allocations
            while (j < self.allocation_sizes.items.len) {
                const other_size = self.allocation_sizes.items[j];
                const tolerance = size / 10; // 10% tolerance
                if (other_size <= size + tolerance) {
                    count += 1;
                    j += 1;
                } else {
                    break;
                }
            }

            // If this size appears frequently, consider it for pooling
            const frequency = @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(self.allocation_sizes.items.len));
            if (frequency > 0.05) { // More than 5% of allocations
                try self.pool_configs.append(PoolConfig{
                    .size = size,
                    .count = @max(count / 10, 8), // Pool size based on usage
                    .hit_rate = frequency,
                });
            }

            i = j;
        }
    }

    pub fn getOptimalPoolConfigs(self: MemoryPoolOptimizer) []const PoolConfig {
        return self.pool_configs.items;
    }
};

test "Usage pattern analysis" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var analyzer = UsagePatternAnalyzer.init(allocator, 1000);
    defer analyzer.deinit();

    // Simulate terminal emulator pattern
    var i: u32 = 0;
    while (i < 50) {
        try analyzer.recordEvent(.{ .read = true }, 500, 0, 64); // stdin events
        i += 1;
    }

    // Pattern should be detected as terminal emulator
    try std.testing.expectEqual(UsagePatternAnalyzer.UsagePattern.terminal_emulator, analyzer.getCurrentPattern());
}

test "Auto optimizer configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var optimizer = AutoOptimizer.init(allocator);
    defer optimizer.deinit();

    // Record network server pattern
    var i: u32 = 0;
    while (i < 100) {
        _ = try optimizer.recordEvent(.{ .read = true }, 2000, 10 + @as(i32, @intCast(i % 10)), 16384);
        i += 1;
    }

    const config = optimizer.getCurrentConfig();
    try std.testing.expect(config.max_events > 256); // Should optimize for high throughput
    try std.testing.expect(config.buffer_size >= 32 * 1024); // Larger buffers for network data
}

test "Memory pool optimization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var optimizer = MemoryPoolOptimizer.init(allocator);
    defer optimizer.deinit();

    // Simulate common allocation patterns
    var i: usize = 0;
    while (i < 1000) {
        try optimizer.recordAllocation(64); // Very common
        if (i % 5 == 0) try optimizer.recordAllocation(1024); // Less common
        if (i % 10 == 0) try optimizer.recordAllocation(4096); // Rare
        i += 1;
    }

    const configs = optimizer.getOptimalPoolConfigs();
    try std.testing.expect(configs.len > 0);

    // Should identify 64-byte allocations as very common
    var found_64_byte = false;
    for (configs) |config| {
        if (config.size == 64) {
            found_64_byte = true;
            try std.testing.expect(config.hit_rate > 0.8); // Should be high frequency
        }
    }
    try std.testing.expect(found_64_byte);
}