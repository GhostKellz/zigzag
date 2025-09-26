//! Event debugging and monitoring system for ZigZag
//! Provides comprehensive event tracing, debugging utilities, and performance metrics

const std = @import("std");
const builtin = @import("builtin");
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;
const Backend = @import("root.zig").Backend;
const HighResTimer = @import("advanced_timers.zig").HighResTimer;

/// Event trace entry for debugging
pub const EventTrace = struct {
    timestamp: u64,
    sequence_id: u64,
    event: Event,
    processing_time_ns: u64,
    queue_depth: usize,
    backend: Backend,
    thread_id: ?std.Thread.Id = null,
    stack_trace: ?[]const usize = null,

    pub fn format(
        self: EventTrace,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("EventTrace[{d}] @ {d}ns: {s}(fd={d}) processed in {d}μs, queue_depth={d}, backend={s}",
            .{
                self.sequence_id,
                self.timestamp,
                @tagName(self.event.type),
                self.event.fd,
                self.processing_time_ns / 1000,
                self.queue_depth,
                @tagName(self.backend),
            });
        if (self.thread_id) |tid| {
            try writer.print(", thread={d}", .{@intFromPtr(tid)});
        }
    }
};

/// Event filter for selective tracing
pub const EventFilter = struct {
    enabled_types: std.EnumSet(EventType) = std.EnumSet(EventType).initFull(),
    min_processing_time_ns: u64 = 0,
    max_processing_time_ns: u64 = std.math.maxInt(u64),
    enabled_backends: std.EnumSet(Backend) = std.EnumSet(Backend).initFull(),
    fd_filter: ?std.AutoHashMap(i32, void) = null,
    thread_filter: ?std.AutoHashMap(std.Thread.Id, void) = null,

    pub fn init(allocator: std.mem.Allocator) EventFilter {
        return EventFilter{
            .fd_filter = std.AutoHashMap(i32, void).init(allocator),
            .thread_filter = std.AutoHashMap(std.Thread.Id, void).init(allocator),
        };
    }

    pub fn deinit(self: *EventFilter) void {
        if (self.fd_filter) |*filter| {
            filter.deinit();
        }
        if (self.thread_filter) |*filter| {
            filter.deinit();
        }
    }

    pub fn shouldTrace(self: *const EventFilter, trace: *const EventTrace) bool {
        // Check event type
        if (!self.enabled_types.contains(trace.event.type)) {
            return false;
        }

        // Check processing time
        if (trace.processing_time_ns < self.min_processing_time_ns or
            trace.processing_time_ns > self.max_processing_time_ns)
        {
            return false;
        }

        // Check backend
        if (!self.enabled_backends.contains(trace.backend)) {
            return false;
        }

        // Check FD filter
        if (self.fd_filter) |*filter| {
            if (filter.count() > 0 and !filter.contains(trace.event.fd)) {
                return false;
            }
        }

        // Check thread filter
        if (self.thread_filter) |*filter| {
            if (filter.count() > 0 and trace.thread_id != null) {
                if (!filter.contains(trace.thread_id.?)) {
                    return false;
                }
            }
        }

        return true;
    }

    pub fn addFdFilter(self: *EventFilter, fd: i32) !void {
        if (self.fd_filter) |*filter| {
            try filter.put(fd, {});
        }
    }

    pub fn addThreadFilter(self: *EventFilter, thread_id: std.Thread.Id) !void {
        if (self.thread_filter) |*filter| {
            try filter.put(thread_id, {});
        }
    }

    pub fn setEventTypes(self: *EventFilter, types: []const EventType) void {
        self.enabled_types = std.EnumSet(EventType).initEmpty();
        for (types) |event_type| {
            self.enabled_types.insert(event_type);
        }
    }

    pub fn setBackends(self: *EventFilter, backends: []const Backend) void {
        self.enabled_backends = std.EnumSet(Backend).initEmpty();
        for (backends) |backend| {
            self.enabled_backends.insert(backend);
        }
    }
};

/// Event tracer with configurable output
pub const EventTracer = struct {
    allocator: std.mem.Allocator,
    traces: std.ArrayList(EventTrace),
    filter: EventFilter,
    sequence_counter: u64 = 0,
    max_traces: usize = 100000,
    enabled: bool = true,
    output_writer: ?std.io.AnyWriter = null,
    real_time_output: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_traces: usize) !EventTracer {
        var traces = std.ArrayList(EventTrace).init(allocator);
        try traces.ensureTotalCapacity(max_traces);

        return EventTracer{
            .allocator = allocator,
            .traces = traces,
            .filter = EventFilter.init(allocator),
            .max_traces = max_traces,
        };
    }

    pub fn deinit(self: *EventTracer) void {
        self.traces.deinit();
        self.filter.deinit();
    }

    pub fn setEnabled(self: *EventTracer, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn setOutput(self: *EventTracer, writer: std.io.AnyWriter, real_time: bool) void {
        self.output_writer = writer;
        self.real_time_output = real_time;
    }

    pub fn setFilter(self: *EventTracer, filter: EventFilter) void {
        self.filter.deinit();
        self.filter = filter;
    }

    pub fn traceEvent(
        self: *EventTracer,
        event: Event,
        processing_time_ns: u64,
        queue_depth: usize,
        backend: Backend,
    ) !void {
        if (!self.enabled) return;

        const trace = EventTrace{
            .timestamp = HighResTimer.getHighResTime(),
            .sequence_id = self.sequence_counter,
            .event = event,
            .processing_time_ns = processing_time_ns,
            .queue_depth = queue_depth,
            .backend = backend,
            .thread_id = std.Thread.getCurrentId(),
            .stack_trace = null, // TODO: Implement stack trace capture
        };

        self.sequence_counter += 1;

        // Apply filter
        if (!self.filter.shouldTrace(&trace)) {
            return;
        }

        // Store trace
        if (self.traces.items.len >= self.max_traces) {
            // Ring buffer behavior - overwrite oldest
            self.traces.items[self.sequence_counter % self.max_traces] = trace;
        } else {
            try self.traces.append(trace);
        }

        // Real-time output
        if (self.real_time_output) {
            if (self.output_writer) |writer| {
                try writer.print("{}\n", .{trace});
            }
        }
    }

    pub fn dumpTraces(self: *const EventTracer, writer: anytype) !void {
        try writer.print("=== Event Trace Dump ({d} events) ===\n", .{self.traces.items.len});
        for (self.traces.items) |trace| {
            try writer.print("{}\n", .{trace});
        }
    }

    pub fn getTraces(self: *const EventTracer) []const EventTrace {
        return self.traces.items;
    }

    pub fn clearTraces(self: *EventTracer) void {
        self.traces.clearRetainingCapacity();
        self.sequence_counter = 0;
    }

    pub fn analyzeTraces(self: *const EventTracer) TraceAnalysis {
        var analysis = TraceAnalysis{};

        for (self.traces.items) |trace| {
            analysis.total_events += 1;
            analysis.total_processing_time_ns += trace.processing_time_ns;
            analysis.max_processing_time_ns = @max(analysis.max_processing_time_ns, trace.processing_time_ns);
            analysis.min_processing_time_ns = @min(analysis.min_processing_time_ns, trace.processing_time_ns);

            // Count by event type
            const type_index = @intFromEnum(trace.event.type);
            if (type_index < analysis.events_by_type.len) {
                analysis.events_by_type[type_index] += 1;
            }

            // Queue depth analysis
            analysis.total_queue_depth += trace.queue_depth;
            analysis.max_queue_depth = @max(analysis.max_queue_depth, trace.queue_depth);
        }

        return analysis;
    }
};

/// Analysis results from event traces
pub const TraceAnalysis = struct {
    total_events: u64 = 0,
    total_processing_time_ns: u64 = 0,
    max_processing_time_ns: u64 = 0,
    min_processing_time_ns: u64 = std.math.maxInt(u64),
    events_by_type: [8]u64 = [_]u64{0} ** 8,
    total_queue_depth: u64 = 0,
    max_queue_depth: usize = 0,

    pub fn getAverageProcessingTime(self: *const TraceAnalysis) f64 {
        if (self.total_events == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_processing_time_ns)) / @as(f64, @floatFromInt(self.total_events));
    }

    pub fn getAverageQueueDepth(self: *const TraceAnalysis) f64 {
        if (self.total_events == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_queue_depth)) / @as(f64, @floatFromInt(self.total_events));
    }

    pub fn format(
        self: TraceAnalysis,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Trace Analysis:\n", .{});
        try writer.print("  Total events: {d}\n", .{self.total_events});
        try writer.print("  Avg processing time: {d:.2} μs\n", .{self.getAverageProcessingTime() / 1000.0});
        try writer.print("  Max processing time: {d:.2} μs\n", .{@as(f64, @floatFromInt(self.max_processing_time_ns)) / 1000.0});
        try writer.print("  Min processing time: {d:.2} μs\n", .{@as(f64, @floatFromInt(self.min_processing_time_ns)) / 1000.0});
        try writer.print("  Avg queue depth: {d:.1}\n", .{self.getAverageQueueDepth()});
        try writer.print("  Max queue depth: {d}\n", .{self.max_queue_depth});
    }
};

/// Performance monitor for live system monitoring
pub const PerformanceMonitor = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(PerformanceSample),
    sample_interval_ms: u64 = 1000,
    last_sample_time: i64 = 0,
    enabled: bool = true,
    alert_thresholds: AlertThresholds,
    alert_callback: ?*const fn (Alert) void = null,

    const PerformanceSample = struct {
        timestamp: i64,
        events_per_second: f64,
        avg_processing_time_ns: f64,
        queue_depth: usize,
        memory_usage: usize,
        cpu_usage: f64,
    };

    const AlertThresholds = struct {
        max_processing_time_ns: u64 = 10_000_000, // 10ms
        max_queue_depth: usize = 1000,
        min_events_per_second: f64 = 0.1,
        max_events_per_second: f64 = 100000.0,
        max_memory_usage: usize = 100 * 1024 * 1024, // 100MB
    };

    const Alert = struct {
        timestamp: i64,
        alert_type: AlertType,
        value: f64,
        threshold: f64,
        message: []const u8,

        const AlertType = enum {
            high_processing_time,
            high_queue_depth,
            low_throughput,
            high_throughput,
            high_memory_usage,
        };
    };

    pub fn init(allocator: std.mem.Allocator) PerformanceMonitor {
        return PerformanceMonitor{
            .allocator = allocator,
            .samples = std.ArrayList(PerformanceSample).init(allocator),
            .alert_thresholds = AlertThresholds{},
        };
    }

    pub fn deinit(self: *PerformanceMonitor) void {
        self.samples.deinit();
    }

    pub fn setAlertCallback(self: *PerformanceMonitor, callback: *const fn (Alert) void) void {
        self.alert_callback = callback;
    }

    pub fn recordSample(
        self: *PerformanceMonitor,
        events_processed: u64,
        avg_processing_time_ns: f64,
        queue_depth: usize,
        memory_usage: usize,
    ) !void {
        if (!self.enabled) return;

        const now = std.time.milliTimestamp();
        if (now - self.last_sample_time < self.sample_interval_ms) {
            return; // Too soon for next sample
        }

        const time_delta = @as(f64, @floatFromInt(now - self.last_sample_time)) / 1000.0; // seconds
        const events_per_second = @as(f64, @floatFromInt(events_processed)) / time_delta;

        const sample = PerformanceSample{
            .timestamp = now,
            .events_per_second = events_per_second,
            .avg_processing_time_ns = avg_processing_time_ns,
            .queue_depth = queue_depth,
            .memory_usage = memory_usage,
            .cpu_usage = 0.0, // TODO: Implement CPU usage monitoring
        };

        try self.samples.append(sample);
        self.last_sample_time = now;

        // Check for alerts
        try self.checkAlerts(&sample);

        // Keep only recent samples (last hour)
        const max_samples = 3600 / (self.sample_interval_ms / 1000);
        if (self.samples.items.len > max_samples) {
            _ = self.samples.orderedRemove(0);
        }
    }

    fn checkAlerts(self: *PerformanceMonitor, sample: *const PerformanceSample) !void {
        const now = std.time.milliTimestamp();

        // High processing time alert
        if (sample.avg_processing_time_ns > @as(f64, @floatFromInt(self.alert_thresholds.max_processing_time_ns))) {
            const alert = Alert{
                .timestamp = now,
                .alert_type = .high_processing_time,
                .value = sample.avg_processing_time_ns,
                .threshold = @floatFromInt(self.alert_thresholds.max_processing_time_ns),
                .message = "High event processing time detected",
            };
            if (self.alert_callback) |callback| {
                callback(alert);
            }
        }

        // High queue depth alert
        if (sample.queue_depth > self.alert_thresholds.max_queue_depth) {
            const alert = Alert{
                .timestamp = now,
                .alert_type = .high_queue_depth,
                .value = @floatFromInt(sample.queue_depth),
                .threshold = @floatFromInt(self.alert_thresholds.max_queue_depth),
                .message = "High event queue depth detected",
            };
            if (self.alert_callback) |callback| {
                callback(alert);
            }
        }

        // Low throughput alert
        if (sample.events_per_second < self.alert_thresholds.min_events_per_second) {
            const alert = Alert{
                .timestamp = now,
                .alert_type = .low_throughput,
                .value = sample.events_per_second,
                .threshold = self.alert_thresholds.min_events_per_second,
                .message = "Low event throughput detected",
            };
            if (self.alert_callback) |callback| {
                callback(alert);
            }
        }

        // High memory usage alert
        if (sample.memory_usage > self.alert_thresholds.max_memory_usage) {
            const alert = Alert{
                .timestamp = now,
                .alert_type = .high_memory_usage,
                .value = @floatFromInt(sample.memory_usage),
                .threshold = @floatFromInt(self.alert_thresholds.max_memory_usage),
                .message = "High memory usage detected",
            };
            if (self.alert_callback) |callback| {
                callback(alert);
            }
        }
    }

    pub fn getSamples(self: *const PerformanceMonitor) []const PerformanceSample {
        return self.samples.items;
    }

    pub fn getLatestSample(self: *const PerformanceMonitor) ?PerformanceSample {
        if (self.samples.items.len == 0) return null;
        return self.samples.items[self.samples.items.len - 1];
    }

    pub fn generateReport(self: *const PerformanceMonitor, writer: anytype) !void {
        try writer.print("=== Performance Monitor Report ===\n", .{});
        try writer.print("Sample count: {d}\n", .{self.samples.items.len});

        if (self.samples.items.len == 0) {
            try writer.print("No samples available\n", .{});
            return;
        }

        // Calculate statistics
        var total_throughput: f64 = 0;
        var max_throughput: f64 = 0;
        var min_throughput: f64 = std.math.floatMax(f64);
        var total_processing_time: f64 = 0;
        var max_queue_depth: usize = 0;

        for (self.samples.items) |sample| {
            total_throughput += sample.events_per_second;
            max_throughput = @max(max_throughput, sample.events_per_second);
            min_throughput = @min(min_throughput, sample.events_per_second);
            total_processing_time += sample.avg_processing_time_ns;
            max_queue_depth = @max(max_queue_depth, sample.queue_depth);
        }

        const avg_throughput = total_throughput / @as(f64, @floatFromInt(self.samples.items.len));
        const avg_processing_time = total_processing_time / @as(f64, @floatFromInt(self.samples.items.len));

        try writer.print("Throughput: avg={d:.1} events/s, max={d:.1}, min={d:.1}\n", .{
            avg_throughput,
            max_throughput,
            min_throughput,
        });
        try writer.print("Processing time: avg={d:.2} μs\n", .{avg_processing_time / 1000.0});
        try writer.print("Max queue depth: {d}\n", .{max_queue_depth});

        // Latest sample
        if (self.getLatestSample()) |latest| {
            try writer.print("Latest: {d:.1} events/s, {d:.2} μs processing, queue depth {d}\n", .{
                latest.events_per_second,
                latest.avg_processing_time_ns / 1000.0,
                latest.queue_depth,
            });
        }
    }
};

/// Debug utilities for event loop inspection
pub const DebugUtils = struct {
    /// Print detailed event information
    pub fn printEvent(event: Event, writer: anytype) !void {
        try writer.print("Event {{\n", .{});
        try writer.print("  fd: {d}\n", .{event.fd});
        try writer.print("  type: {s}\n", .{@tagName(event.type)});
        try writer.print("  data: ", .{});
        switch (event.data) {
            .size => |size| try writer.print("size={d}", .{size}),
            .signal => |sig| try writer.print("signal={d}", .{sig}),
            .timer_id => |id| try writer.print("timer_id={d}", .{id}),
            .user_data => |ptr| try writer.print("user_data={*}", .{ptr}),
        }
        try writer.print("\n}}\n", .{});
    }

    /// Validate event consistency
    pub fn validateEvent(event: Event) bool {
        // Basic validation rules
        switch (event.type) {
            .read_ready, .write_ready => {
                return event.fd >= 0; // Valid file descriptor
            },
            .timer_expired => {
                return event.fd == -1; // Timers don't have FDs
            },
            .child_exit => {
                return event.fd >= 0; // Should have a process ID
            },
            else => return true, // Other events are generally valid
        }
    }

    /// Memory usage analyzer
    pub fn analyzeMemoryUsage(allocator: std.mem.Allocator) !void {
        _ = allocator;
        // TODO: Implement memory usage analysis
        // This would typically involve:
        // - Tracking allocations/deallocations
        // - Memory leak detection
        // - Peak usage analysis
        std.log.info("Memory usage analysis not yet implemented", .{});
    }

    /// Event loop health check
    pub fn healthCheck(event_tracer: *const EventTracer) HealthStatus {
        const analysis = event_tracer.analyzeTraces();
        var status = HealthStatus{};

        // Check for performance issues
        const avg_time = analysis.getAverageProcessingTime();
        if (avg_time > 1_000_000) { // > 1ms
            status.issues.append("High average processing time") catch {};
        }

        if (analysis.max_queue_depth > 1000) {
            status.issues.append("High queue depth detected") catch {};
        }

        if (analysis.total_events == 0) {
            status.issues.append("No events processed") catch {};
        }

        status.healthy = status.issues.items.len == 0;
        return status;
    }

    const HealthStatus = struct {
        healthy: bool = true,
        issues: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(std.heap.page_allocator),

        pub fn deinit(self: *HealthStatus) void {
            self.issues.deinit();
        }
    };
};

test "Event tracer basic operations" {
    const allocator = std.testing.allocator;

    var tracer = try EventTracer.init(allocator, 1000);
    defer tracer.deinit();

    const event = Event{
        .fd = 1,
        .type = .read_ready,
        .data = .{ .size = 1024 },
    };

    try tracer.traceEvent(event, 5000, 10, .epoll);

    const traces = tracer.getTraces();
    try std.testing.expectEqual(@as(usize, 1), traces.len);
    try std.testing.expectEqual(event.fd, traces[0].event.fd);
    try std.testing.expectEqual(event.type, traces[0].event.type);
}

test "Event filter functionality" {
    const allocator = std.testing.allocator;

    var filter = EventFilter.init(allocator);
    defer filter.deinit();

    // Set up filter for read events only
    filter.setEventTypes(&[_]EventType{.read_ready});

    const read_trace = EventTrace{
        .timestamp = 0,
        .sequence_id = 1,
        .event = Event{ .fd = 1, .type = .read_ready, .data = .{ .size = 100 } },
        .processing_time_ns = 1000,
        .queue_depth = 5,
        .backend = .epoll,
    };

    const write_trace = EventTrace{
        .timestamp = 0,
        .sequence_id = 2,
        .event = Event{ .fd = 1, .type = .write_ready, .data = .{ .size = 100 } },
        .processing_time_ns = 1000,
        .queue_depth = 5,
        .backend = .epoll,
    };

    try std.testing.expect(filter.shouldTrace(&read_trace));
    try std.testing.expect(!filter.shouldTrace(&write_trace));
}

test "Performance monitor basic operations" {
    const allocator = std.testing.allocator;

    var monitor = PerformanceMonitor.init(allocator);
    defer monitor.deinit();

    try monitor.recordSample(100, 5000.0, 10, 1024 * 1024);

    const samples = monitor.getSamples();
    try std.testing.expectEqual(@as(usize, 1), samples.len);
    try std.testing.expect(samples[0].events_per_second > 0);
}

test "Debug utilities" {
    const event = Event{
        .fd = 5,
        .type = .read_ready,
        .data = .{ .size = 1024 },
    };

    try std.testing.expect(DebugUtils.validateEvent(event));

    const invalid_event = Event{
        .fd = -5, // Invalid fd for read event
        .type = .read_ready,
        .data = .{ .size = 1024 },
    };

    try std.testing.expect(!DebugUtils.validateEvent(invalid_event));
}