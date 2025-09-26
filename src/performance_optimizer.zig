//! Performance optimization suite for RC3
//! Critical path optimization, memory usage reduction, and system call minimization

const std = @import("std");
const builtin = @import("builtin");
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;
const Backend = @import("root.zig").Backend;

/// Critical path optimizer
pub const CriticalPathOptimizer = struct {
    allocator: std.mem.Allocator,
    hotpath_analytics: HotpathAnalytics,
    optimization_cache: std.AutoHashMap(u64, OptimizationRecord),
    performance_counters: PerformanceCounters,

    const HotpathAnalytics = struct {
        call_counts: std.AutoHashMap([]const u8, u64),
        execution_times: std.AutoHashMap([]const u8, u64),
        cache_hits: u64,
        cache_misses: u64,

        pub fn init(allocator: std.mem.Allocator) HotpathAnalytics {
            return HotpathAnalytics{
                .call_counts = std.AutoHashMap([]const u8, u64).init(allocator),
                .execution_times = std.AutoHashMap([]const u8, u64).init(allocator),
                .cache_hits = 0,
                .cache_misses = 0,
            };
        }

        pub fn deinit(self: *HotpathAnalytics) void {
            self.call_counts.deinit();
            self.execution_times.deinit();
        }

        pub fn recordCall(self: *HotpathAnalytics, function_name: []const u8, execution_time_ns: u64) !void {
            // Update call count
            const count = self.call_counts.get(function_name) orelse 0;
            try self.call_counts.put(function_name, count + 1);

            // Update total execution time
            const total_time = self.execution_times.get(function_name) orelse 0;
            try self.execution_times.put(function_name, total_time + execution_time_ns);
        }

        pub fn getHotpaths(self: HotpathAnalytics, allocator: std.mem.Allocator) ![]HotpathInfo {
            var hotpaths = std.ArrayList(HotpathInfo).init(allocator);
            defer hotpaths.deinit();

            var iter = self.call_counts.iterator();
            while (iter.next()) |entry| {
                const function_name = entry.key_ptr.*;
                const call_count = entry.value_ptr.*;
                const total_time = self.execution_times.get(function_name) orelse 0;

                if (call_count > 1000 or total_time > 1_000_000) { // Hot if >1000 calls or >1ms total
                    try hotpaths.append(HotpathInfo{
                        .function_name = function_name,
                        .call_count = call_count,
                        .total_time_ns = total_time,
                        .avg_time_ns = if (call_count > 0) total_time / call_count else 0,
                    });
                }
            }

            return try hotpaths.toOwnedSlice();
        }

        const HotpathInfo = struct {
            function_name: []const u8,
            call_count: u64,
            total_time_ns: u64,
            avg_time_ns: u64,
        };
    };

    const OptimizationRecord = struct {
        optimization_type: OptimizationType,
        applied_at: i64,
        performance_gain: f64,
        validation_status: ValidationStatus,
    };

    const OptimizationType = enum {
        inlining,
        loop_unrolling,
        branch_prediction,
        cache_optimization,
        memory_prefetch,
        vectorization,
        syscall_batching,
    };

    const ValidationStatus = enum {
        pending,
        validated,
        failed,
        reverted,
    };

    const PerformanceCounters = struct {
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
        syscalls_avoided: u64 = 0,
        memory_allocations: u64 = 0,
        memory_deallocations: u64 = 0,
        context_switches: u64 = 0,

        pub fn getCacheHitRatio(self: PerformanceCounters) f64 {
            const total = self.cache_hits + self.cache_misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total));
        }

        pub fn getAllocationRatio(self: PerformanceCounters) f64 {
            if (self.memory_allocations == 0) return 0.0;
            return @as(f64, @floatFromInt(self.memory_deallocations)) / @as(f64, @floatFromInt(self.memory_allocations));
        }
    };

    pub fn init(allocator: std.mem.Allocator) CriticalPathOptimizer {
        return CriticalPathOptimizer{
            .allocator = allocator,
            .hotpath_analytics = HotpathAnalytics.init(allocator),
            .optimization_cache = std.AutoHashMap(u64, OptimizationRecord).init(allocator),
            .performance_counters = PerformanceCounters{},
        };
    }

    pub fn deinit(self: *CriticalPathOptimizer) void {
        self.hotpath_analytics.deinit();
        self.optimization_cache.deinit();
    }

    /// Record function execution for optimization analysis
    pub fn recordExecution(self: *CriticalPathOptimizer, function_name: []const u8, execution_time_ns: u64) !void {
        try self.hotpath_analytics.recordCall(function_name, execution_time_ns);
    }

    /// Apply critical path optimizations
    pub fn optimizeCriticalPaths(self: *CriticalPathOptimizer) !OptimizationResults {
        const hotpaths = try self.hotpath_analytics.getHotpaths(self.allocator);
        defer self.allocator.free(hotpaths);

        var results = OptimizationResults{
            .optimizations_applied = 0,
            .performance_improvement = 0.0,
            .memory_reduction = 0,
        };

        for (hotpaths) |hotpath| {
            const optimization_hash = std.hash_map.hashString(hotpath.function_name);

            // Skip if already optimized
            if (self.optimization_cache.contains(optimization_hash)) {
                continue;
            }

            // Apply optimization based on characteristics
            const optimization = try self.selectOptimization(hotpath);
            const gain = try self.applyOptimization(hotpath.function_name, optimization);

            try self.optimization_cache.put(optimization_hash, OptimizationRecord{
                .optimization_type = optimization,
                .applied_at = std.time.milliTimestamp(),
                .performance_gain = gain,
                .validation_status = .pending,
            });

            results.optimizations_applied += 1;
            results.performance_improvement += gain;
        }

        return results;
    }

    fn selectOptimization(self: *CriticalPathOptimizer, hotpath: HotpathAnalytics.HotpathInfo) !OptimizationType {
        _ = self;

        // Choose optimization based on hotpath characteristics
        if (hotpath.avg_time_ns < 100) {
            return .inlining; // Very fast functions benefit from inlining
        } else if (hotpath.call_count > 10000) {
            return .cache_optimization; // Frequently called functions benefit from caching
        } else if (hotpath.avg_time_ns > 10000) {
            return .vectorization; // Slow functions might benefit from vectorization
        } else {
            return .branch_prediction; // Default optimization
        }
    }

    fn applyOptimization(self: *CriticalPathOptimizer, function_name: []const u8, optimization: OptimizationType) !f64 {
        _ = self;
        _ = function_name;

        // Simulate optimization application and return estimated gain
        return switch (optimization) {
            .inlining => 15.0, // 15% improvement
            .loop_unrolling => 12.0,
            .branch_prediction => 8.0,
            .cache_optimization => 25.0,
            .memory_prefetch => 18.0,
            .vectorization => 30.0,
            .syscall_batching => 40.0,
        };
    }

    const OptimizationResults = struct {
        optimizations_applied: u32,
        performance_improvement: f64,
        memory_reduction: u64,
    };
};

/// Memory usage optimizer
pub const MemoryOptimizer = struct {
    allocator: std.mem.Allocator,
    allocation_tracker: AllocationTracker,
    memory_pools: std.ArrayList(MemoryPool),
    fragmentation_analyzer: FragmentationAnalyzer,

    const AllocationTracker = struct {
        size_histogram: [64]u64, // Track allocation sizes (powers of 2)
        peak_usage: u64,
        current_usage: u64,
        allocation_count: u64,
        deallocation_count: u64,

        pub fn init() AllocationTracker {
            return AllocationTracker{
                .size_histogram = [_]u64{0} ** 64,
                .peak_usage = 0,
                .current_usage = 0,
                .allocation_count = 0,
                .deallocation_count = 0,
            };
        }

        pub fn recordAllocation(self: *AllocationTracker, size: usize) void {
            self.allocation_count += 1;
            self.current_usage += size;
            self.peak_usage = @max(self.peak_usage, self.current_usage);

            // Update size histogram
            const bucket = @min(63, std.math.log2_int(u64, @max(1, size)));
            self.size_histogram[bucket] += 1;
        }

        pub fn recordDeallocation(self: *AllocationTracker, size: usize) void {
            self.deallocation_count += 1;
            self.current_usage = if (self.current_usage >= size) self.current_usage - size else 0;
        }

        pub fn getOptimalPoolSizes(self: AllocationTracker, allocator: std.mem.Allocator) ![]usize {
            var pool_sizes = std.ArrayList(usize).init(allocator);
            defer pool_sizes.deinit();

            // Find most common allocation sizes
            for (self.size_histogram, 0..) |count, bucket| {
                if (count > 100) { // Threshold for pool creation
                    const size = @as(usize, 1) << @intCast(bucket);
                    try pool_sizes.append(size);
                }
            }

            return try pool_sizes.toOwnedSlice();
        }
    };

    const MemoryPool = struct {
        block_size: usize,
        total_blocks: u32,
        free_blocks: u32,
        blocks: []u8,
        free_list: std.ArrayList(usize),

        pub fn init(allocator: std.mem.Allocator, block_size: usize, block_count: u32) !MemoryPool {
            const total_size = block_size * block_count;
            const blocks = try allocator.alloc(u8, total_size);

            var free_list = std.ArrayList(usize).init(allocator);
            try free_list.ensureTotalCapacity(block_count);

            // Initialize free list
            var i: u32 = 0;
            while (i < block_count) : (i += 1) {
                free_list.appendAssumeCapacity(i * block_size);
            }

            return MemoryPool{
                .block_size = block_size,
                .total_blocks = block_count,
                .free_blocks = block_count,
                .blocks = blocks,
                .free_list = free_list,
            };
        }

        pub fn deinit(self: *MemoryPool, allocator: std.mem.Allocator) void {
            allocator.free(self.blocks);
            self.free_list.deinit();
        }

        pub fn allocate(self: *MemoryPool) ?[]u8 {
            if (self.free_list.popOrNull()) |offset| {
                self.free_blocks -= 1;
                return self.blocks[offset..offset + self.block_size];
            }
            return null;
        }

        pub fn deallocate(self: *MemoryPool, ptr: []u8) !void {
            const offset = @intFromPtr(ptr.ptr) - @intFromPtr(self.blocks.ptr);
            try self.free_list.append(offset);
            self.free_blocks += 1;
        }

        pub fn getUtilization(self: MemoryPool) f64 {
            const used_blocks = self.total_blocks - self.free_blocks;
            return @as(f64, @floatFromInt(used_blocks)) / @as(f64, @floatFromInt(self.total_blocks));
        }
    };

    const FragmentationAnalyzer = struct {
        free_chunks: std.ArrayList(ChunkInfo),
        allocated_chunks: std.ArrayList(ChunkInfo),

        const ChunkInfo = struct {
            address: usize,
            size: usize,
        };

        pub fn init(allocator: std.mem.Allocator) FragmentationAnalyzer {
            return FragmentationAnalyzer{
                .free_chunks = std.ArrayList(ChunkInfo).init(allocator),
                .allocated_chunks = std.ArrayList(ChunkInfo).init(allocator),
            };
        }

        pub fn deinit(self: *FragmentationAnalyzer) void {
            self.free_chunks.deinit();
            self.allocated_chunks.deinit();
        }

        pub fn calculateFragmentation(self: FragmentationAnalyzer) f64 {
            if (self.free_chunks.items.len <= 1) return 0.0;

            var total_free: usize = 0;
            var largest_chunk: usize = 0;

            for (self.free_chunks.items) |chunk| {
                total_free += chunk.size;
                largest_chunk = @max(largest_chunk, chunk.size);
            }

            if (total_free == 0) return 0.0;

            return 1.0 - (@as(f64, @floatFromInt(largest_chunk)) / @as(f64, @floatFromInt(total_free)));
        }
    };

    pub fn init(allocator: std.mem.Allocator) MemoryOptimizer {
        return MemoryOptimizer{
            .allocator = allocator,
            .allocation_tracker = AllocationTracker.init(),
            .memory_pools = std.ArrayList(MemoryPool).init(allocator),
            .fragmentation_analyzer = FragmentationAnalyzer.init(allocator),
        };
    }

    pub fn deinit(self: *MemoryOptimizer) void {
        for (self.memory_pools.items) |*pool| {
            pool.deinit(self.allocator);
        }
        self.memory_pools.deinit();
        self.fragmentation_analyzer.deinit();
    }

    /// Create optimized memory pools based on usage patterns
    pub fn createOptimizedPools(self: *MemoryOptimizer) !void {
        const optimal_sizes = try self.allocation_tracker.getOptimalPoolSizes(self.allocator);
        defer self.allocator.free(optimal_sizes);

        for (optimal_sizes) |size| {
            // Create pool with size-dependent block count
            const block_count = @min(1000, @max(10, 1024 * 1024 / size));
            const pool = try MemoryPool.init(self.allocator, size, @intCast(block_count));
            try self.memory_pools.append(pool);
        }
    }

    /// Get memory optimization statistics
    pub fn getMemoryStats(self: MemoryOptimizer) MemoryStats {
        var total_pool_memory: u64 = 0;
        var total_utilization: f64 = 0;

        for (self.memory_pools.items) |pool| {
            total_pool_memory += pool.total_blocks * pool.block_size;
            total_utilization += pool.getUtilization();
        }

        const avg_utilization = if (self.memory_pools.items.len > 0)
            total_utilization / @as(f64, @floatFromInt(self.memory_pools.items.len))
        else
            0.0;

        return MemoryStats{
            .peak_usage = self.allocation_tracker.peak_usage,
            .current_usage = self.allocation_tracker.current_usage,
            .total_allocations = self.allocation_tracker.allocation_count,
            .total_deallocations = self.allocation_tracker.deallocation_count,
            .pool_memory = total_pool_memory,
            .average_pool_utilization = avg_utilization,
            .fragmentation = self.fragmentation_analyzer.calculateFragmentation(),
        };
    }

    const MemoryStats = struct {
        peak_usage: u64,
        current_usage: u64,
        total_allocations: u64,
        total_deallocations: u64,
        pool_memory: u64,
        average_pool_utilization: f64,
        fragmentation: f64,
    };
};

/// System call minimizer
pub const SyscallMinimizer = struct {
    allocator: std.mem.Allocator,
    syscall_tracker: SyscallTracker,
    batching_buffer: BatchingBuffer,
    optimization_strategies: std.ArrayList(OptimizationStrategy),

    const SyscallTracker = struct {
        call_counts: std.AutoHashMap(SyscallType, u64),
        total_syscalls: u64,
        batched_syscalls: u64,

        const SyscallType = enum {
            read,
            write,
            poll,
            epoll_wait,
            io_uring_enter,
            kevent,
            close,
            socket,
            accept,
            connect,
        };

        pub fn init(allocator: std.mem.Allocator) SyscallTracker {
            return SyscallTracker{
                .call_counts = std.AutoHashMap(SyscallType, u64).init(allocator),
                .total_syscalls = 0,
                .batched_syscalls = 0,
            };
        }

        pub fn deinit(self: *SyscallTracker) void {
            self.call_counts.deinit();
        }

        pub fn recordSyscall(self: *SyscallTracker, syscall_type: SyscallType, was_batched: bool) !void {
            const count = self.call_counts.get(syscall_type) orelse 0;
            try self.call_counts.put(syscall_type, count + 1);
            self.total_syscalls += 1;
            if (was_batched) self.batched_syscalls += 1;
        }

        pub fn getBatchingRatio(self: SyscallTracker) f64 {
            if (self.total_syscalls == 0) return 0.0;
            return @as(f64, @floatFromInt(self.batched_syscalls)) / @as(f64, @floatFromInt(self.total_syscalls));
        }
    };

    const BatchingBuffer = struct {
        read_operations: std.ArrayList(BatchedOperation),
        write_operations: std.ArrayList(BatchedOperation),
        max_batch_size: u32,
        batch_timeout_ms: u32,

        const BatchedOperation = struct {
            fd: i32,
            buffer: []u8,
            timestamp: i64,
        };

        pub fn init(allocator: std.mem.Allocator, max_batch: u32, timeout_ms: u32) BatchingBuffer {
            return BatchingBuffer{
                .read_operations = std.ArrayList(BatchedOperation).init(allocator),
                .write_operations = std.ArrayList(BatchedOperation).init(allocator),
                .max_batch_size = max_batch,
                .batch_timeout_ms = timeout_ms,
            };
        }

        pub fn deinit(self: *BatchingBuffer) void {
            self.read_operations.deinit();
            self.write_operations.deinit();
        }

        pub fn shouldFlush(self: BatchingBuffer) bool {
            const now = std.time.milliTimestamp();

            // Flush if batch is full or timeout reached
            if (self.read_operations.items.len >= self.max_batch_size or
                self.write_operations.items.len >= self.max_batch_size)
            {
                return true;
            }

            // Check timeout for oldest operation
            for (self.read_operations.items) |op| {
                if ((now - op.timestamp) > self.batch_timeout_ms) return true;
            }

            for (self.write_operations.items) |op| {
                if ((now - op.timestamp) > self.batch_timeout_ms) return true;
            }

            return false;
        }
    };

    const OptimizationStrategy = struct {
        name: []const u8,
        syscall_types: []const SyscallTracker.SyscallType,
        optimization_fn: *const fn (*SyscallMinimizer) anyerror!u32,
        enabled: bool,
    };

    pub fn init(allocator: std.mem.Allocator) SyscallMinimizer {
        return SyscallMinimizer{
            .allocator = allocator,
            .syscall_tracker = SyscallTracker.init(allocator),
            .batching_buffer = BatchingBuffer.init(allocator, 32, 5),
            .optimization_strategies = std.ArrayList(OptimizationStrategy).init(allocator),
        };
    }

    pub fn deinit(self: *SyscallMinimizer) void {
        self.syscall_tracker.deinit();
        self.batching_buffer.deinit();
        self.optimization_strategies.deinit();
    }

    /// Apply syscall optimizations
    pub fn optimizeSyscalls(self: *SyscallMinimizer) !SyscallOptimizationResults {
        var results = SyscallOptimizationResults{
            .syscalls_avoided = 0,
            .batching_improvement = 0.0,
            .strategies_applied = 0,
        };

        // Apply each enabled optimization strategy
        for (self.optimization_strategies.items) |strategy| {
            if (strategy.enabled) {
                const avoided = try strategy.optimization_fn(self);
                results.syscalls_avoided += avoided;
                results.strategies_applied += 1;
            }
        }

        results.batching_improvement = self.syscall_tracker.getBatchingRatio() * 100.0;
        return results;
    }

    const SyscallOptimizationResults = struct {
        syscalls_avoided: u32,
        batching_improvement: f64,
        strategies_applied: u32,
    };
};

test "Critical path optimization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var optimizer = CriticalPathOptimizer.init(allocator);
    defer optimizer.deinit();

    // Record some hotpath executions
    try optimizer.recordExecution("event_wait", 1500); // 1.5μs
    try optimizer.recordExecution("event_wait", 1600);
    try optimizer.recordExecution("timer_check", 500); // 0.5μs
    try optimizer.recordExecution("timer_check", 450);

    // Simulate many calls to make it a hotpath
    var i: u32 = 0;
    while (i < 2000) : (i += 1) {
        try optimizer.recordExecution("event_wait", 1500);
    }

    const results = try optimizer.optimizeCriticalPaths();
    try std.testing.expect(results.optimizations_applied > 0);
}

test "Memory optimization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var optimizer = MemoryOptimizer.init(allocator);
    defer optimizer.deinit();

    // Simulate allocation patterns
    var j: u32 = 0;
    while (j < 1000) : (j += 1) {
        optimizer.allocation_tracker.recordAllocation(64); // Common size
        if (j % 10 == 0) optimizer.allocation_tracker.recordAllocation(1024);
    }

    try optimizer.createOptimizedPools();

    const stats = optimizer.getMemoryStats();
    try std.testing.expect(stats.total_allocations == 1100);
}

test "Syscall minimization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var minimizer = SyscallMinimizer.init(allocator);
    defer minimizer.deinit();

    // Record syscalls
    try minimizer.syscall_tracker.recordSyscall(.read, false);
    try minimizer.syscall_tracker.recordSyscall(.write, true);
    try minimizer.syscall_tracker.recordSyscall(.epoll_wait, false);

    const batching_ratio = minimizer.syscall_tracker.getBatchingRatio();
    try std.testing.expect(batching_ratio > 0.0 and batching_ratio <= 1.0);
}