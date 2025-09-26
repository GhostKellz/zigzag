//! Resource management and leak prevention for RC2
//! Comprehensive resource tracking, cleanup, and leak detection

const std = @import("std");
const builtin = @import("builtin");
const EventLoop = @import("root.zig").EventLoop;

/// Comprehensive resource manager
pub const ResourceManager = struct {
    allocator: std.mem.Allocator,
    tracked_resources: std.AutoHashMap(ResourceId, Resource),
    resource_pools: std.ArrayList(ResourcePool),
    cleanup_callbacks: std.ArrayList(CleanupCallback),
    leak_detector: LeakDetector,
    next_id: ResourceId,

    const ResourceId = u64;

    const Resource = struct {
        id: ResourceId,
        type: ResourceType,
        size: usize,
        created_at: i64,
        last_accessed: i64,
        ref_count: u32,
        metadata: ResourceMetadata,
    };

    const ResourceType = enum {
        file_descriptor,
        memory_block,
        timer_handle,
        network_connection,
        event_watch,
        async_frame,
        thread_handle,
    };

    const ResourceMetadata = union(ResourceType) {
        file_descriptor: struct {
            fd: i32,
            path: ?[]const u8 = null,
        },
        memory_block: struct {
            ptr: usize,
            alignment: u32,
        },
        timer_handle: struct {
            timer_id: u32,
            interval_ms: u32,
        },
        network_connection: struct {
            fd: i32,
            remote_addr: []const u8,
        },
        event_watch: struct {
            fd: i32,
            events: u32,
        },
        async_frame: struct {
            frame_ptr: usize,
            state: u32,
        },
        thread_handle: struct {
            thread_id: u32,
            joinable: bool,
        },
    };

    const CleanupCallback = struct {
        resource_type: ResourceType,
        callback: *const fn (ResourceMetadata) void,
    };

    pub fn init(allocator: std.mem.Allocator) ResourceManager {
        return ResourceManager{
            .allocator = allocator,
            .tracked_resources = std.AutoHashMap(ResourceId, Resource).init(allocator),
            .resource_pools = std.ArrayList(ResourcePool).init(allocator),
            .cleanup_callbacks = std.ArrayList(CleanupCallback).init(allocator),
            .leak_detector = LeakDetector.init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *ResourceManager) void {
        // Force cleanup of all tracked resources
        self.forceCleanupAll();

        self.tracked_resources.deinit();
        self.resource_pools.deinit();
        self.cleanup_callbacks.deinit();
        self.leak_detector.deinit();
    }

    /// Register a new resource for tracking
    pub fn registerResource(self: *ResourceManager, resource_type: ResourceType, size: usize, metadata: ResourceMetadata) !ResourceId {
        const id = self.next_id;
        self.next_id += 1;

        const now = std.time.milliTimestamp();
        const resource = Resource{
            .id = id,
            .type = resource_type,
            .size = size,
            .created_at = now,
            .last_accessed = now,
            .ref_count = 1,
            .metadata = metadata,
        };

        try self.tracked_resources.put(id, resource);
        return id;
    }

    /// Release a tracked resource
    pub fn releaseResource(self: *ResourceManager, id: ResourceId) !void {
        if (self.tracked_resources.getPtr(id)) |resource| {
            resource.ref_count -= 1;
            if (resource.ref_count == 0) {
                // Execute cleanup callback if registered
                for (self.cleanup_callbacks.items) |callback| {
                    if (callback.resource_type == resource.type) {
                        callback.callback(resource.metadata);
                    }
                }

                _ = self.tracked_resources.remove(id);
            }
        } else {
            return error.ResourceNotFound;
        }
    }

    /// Increment reference count
    pub fn retainResource(self: *ResourceManager, id: ResourceId) !void {
        if (self.tracked_resources.getPtr(id)) |resource| {
            resource.ref_count += 1;
            resource.last_accessed = std.time.milliTimestamp();
        } else {
            return error.ResourceNotFound;
        }
    }

    /// Register cleanup callback for resource type
    pub fn registerCleanupCallback(self: *ResourceManager, resource_type: ResourceType, callback: *const fn (ResourceMetadata) void) !void {
        try self.cleanup_callbacks.append(CleanupCallback{
            .resource_type = resource_type,
            .callback = callback,
        });
    }

    /// Find and cleanup stale resources
    pub fn cleanupStaleResources(self: *ResourceManager, max_age_ms: i64) !u32 {
        const now = std.time.milliTimestamp();
        const cutoff = now - max_age_ms;
        var cleanup_count: u32 = 0;

        var to_remove = std.ArrayList(ResourceId).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.tracked_resources.iterator();
        while (iter.next()) |entry| {
            const resource = entry.value_ptr.*;
            if (resource.last_accessed < cutoff and resource.ref_count == 1) {
                try to_remove.append(resource.id);
            }
        }

        for (to_remove.items) |id| {
            self.releaseResource(id) catch continue;
            cleanup_count += 1;
        }

        return cleanup_count;
    }

    /// Force cleanup of all resources (for shutdown)
    fn forceCleanupAll(self: *ResourceManager) void {
        var iter = self.tracked_resources.iterator();
        while (iter.next()) |entry| {
            const resource = entry.value_ptr.*;

            // Execute cleanup callbacks
            for (self.cleanup_callbacks.items) |callback| {
                if (callback.resource_type == resource.type) {
                    callback.callback(resource.metadata);
                }
            }
        }

        self.tracked_resources.clearAndFree();
    }

    /// Get resource statistics
    pub fn getResourceStats(self: ResourceManager) ResourceStats {
        var stats = ResourceStats{};
        var total_memory: u64 = 0;

        var iter = self.tracked_resources.iterator();
        while (iter.next()) |entry| {
            const resource = entry.value_ptr.*;
            stats.total_resources += 1;
            total_memory += resource.size;

            switch (resource.type) {
                .file_descriptor => stats.file_descriptors += 1,
                .memory_block => stats.memory_blocks += 1,
                .timer_handle => stats.timer_handles += 1,
                .network_connection => stats.network_connections += 1,
                .event_watch => stats.event_watches += 1,
                .async_frame => stats.async_frames += 1,
                .thread_handle => stats.thread_handles += 1,
            }

            if (resource.ref_count > 1) {
                stats.shared_resources += 1;
            }
        }

        stats.total_memory_bytes = total_memory;
        return stats;
    }

    const ResourceStats = struct {
        total_resources: u32 = 0,
        file_descriptors: u32 = 0,
        memory_blocks: u32 = 0,
        timer_handles: u32 = 0,
        network_connections: u32 = 0,
        event_watches: u32 = 0,
        async_frames: u32 = 0,
        thread_handles: u32 = 0,
        shared_resources: u32 = 0,
        total_memory_bytes: u64 = 0,
    };
};

/// Resource pool for efficient allocation/deallocation
const ResourcePool = struct {
    resource_type: ResourceManager.ResourceType,
    available: std.ArrayList(usize),
    allocated: std.AutoHashMap(usize, PooledResource),
    pool_size: u32,
    resource_size: usize,

    const PooledResource = struct {
        ptr: usize,
        allocated_at: i64,
        in_use: bool,
    };

    pub fn init(allocator: std.mem.Allocator, resource_type: ResourceManager.ResourceType, pool_size: u32, resource_size: usize) ResourcePool {
        return ResourcePool{
            .resource_type = resource_type,
            .available = std.ArrayList(usize).init(allocator),
            .allocated = std.AutoHashMap(usize, PooledResource).init(allocator),
            .pool_size = pool_size,
            .resource_size = resource_size,
        };
    }

    pub fn deinit(self: *ResourcePool) void {
        self.available.deinit();
        self.allocated.deinit();
    }

    pub fn acquire(self: *ResourcePool) ?usize {
        if (self.available.popOrNull()) |ptr| {
            if (self.allocated.getPtr(ptr)) |resource| {
                resource.in_use = true;
                resource.allocated_at = std.time.milliTimestamp();
                return ptr;
            }
        }
        return null;
    }

    pub fn release(self: *ResourcePool, ptr: usize) !void {
        if (self.allocated.getPtr(ptr)) |resource| {
            resource.in_use = false;
            try self.available.append(ptr);
        }
    }
};

/// Advanced leak detector
const LeakDetector = struct {
    allocator: std.mem.Allocator,
    allocation_map: std.AutoHashMap(usize, AllocationTrace),
    leak_threshold_ms: i64,

    const AllocationTrace = struct {
        size: usize,
        timestamp: i64,
        component: []const u8,
        call_stack: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) LeakDetector {
        return LeakDetector{
            .allocator = allocator,
            .allocation_map = std.AutoHashMap(usize, AllocationTrace).init(allocator),
            .leak_threshold_ms = 60000, // 1 minute
        };
    }

    pub fn deinit(self: *LeakDetector) void {
        self.allocation_map.deinit();
    }

    pub fn trackAllocation(self: *LeakDetector, ptr: usize, size: usize, component: []const u8) !void {
        try self.allocation_map.put(ptr, AllocationTrace{
            .size = size,
            .timestamp = std.time.milliTimestamp(),
            .component = component,
        });
    }

    pub fn trackDeallocation(self: *LeakDetector, ptr: usize) void {
        _ = self.allocation_map.remove(ptr);
    }

    pub fn scanForLeaks(self: *LeakDetector) ![]LeakInfo {
        const now = std.time.milliTimestamp();
        const cutoff = now - self.leak_threshold_ms;

        var leaks = std.ArrayList(LeakInfo).init(self.allocator);
        defer leaks.deinit();

        var iter = self.allocation_map.iterator();
        while (iter.next()) |entry| {
            const trace = entry.value_ptr.*;
            if (trace.timestamp < cutoff) {
                try leaks.append(LeakInfo{
                    .ptr = entry.key_ptr.*,
                    .size = trace.size,
                    .age_ms = now - trace.timestamp,
                    .component = trace.component,
                });
            }
        }

        return try leaks.toOwnedSlice();
    }

    const LeakInfo = struct {
        ptr: usize,
        size: usize,
        age_ms: i64,
        component: []const u8,
    };
};

/// Automatic resource cleanup scheduler
pub const CleanupScheduler = struct {
    allocator: std.mem.Allocator,
    resource_manager: *ResourceManager,
    cleanup_tasks: std.ArrayList(CleanupTask),
    last_cleanup: i64,
    cleanup_interval_ms: i64,

    const CleanupTask = struct {
        name: []const u8,
        interval_ms: i64,
        last_run: i64,
        task_fn: *const fn (*ResourceManager) anyerror!void,
    };

    pub fn init(allocator: std.mem.Allocator, resource_manager: *ResourceManager) CleanupScheduler {
        return CleanupScheduler{
            .allocator = allocator,
            .resource_manager = resource_manager,
            .cleanup_tasks = std.ArrayList(CleanupTask).init(allocator),
            .last_cleanup = std.time.milliTimestamp(),
            .cleanup_interval_ms = 30000, // 30 seconds
        };
    }

    pub fn deinit(self: *CleanupScheduler) void {
        self.cleanup_tasks.deinit();
    }

    pub fn registerTask(self: *CleanupScheduler, name: []const u8, interval_ms: i64, task_fn: *const fn (*ResourceManager) anyerror!void) !void {
        try self.cleanup_tasks.append(CleanupTask{
            .name = name,
            .interval_ms = interval_ms,
            .last_run = 0,
            .task_fn = task_fn,
        });
    }

    pub fn runCleanupCycle(self: *CleanupScheduler) !void {
        const now = std.time.milliTimestamp();

        for (self.cleanup_tasks.items) |*task| {
            if ((now - task.last_run) >= task.interval_ms) {
                try task.task_fn(self.resource_manager);
                task.last_run = now;
            }
        }

        self.last_cleanup = now;
    }

    pub fn forceCleanup(self: *CleanupScheduler) !void {
        for (self.cleanup_tasks.items) |*task| {
            try task.task_fn(self.resource_manager);
            task.last_run = std.time.milliTimestamp();
        }
    }
};

// Standard cleanup tasks
pub fn cleanupStaleFileDescriptors(resource_manager: *ResourceManager) !void {
    _ = try resource_manager.cleanupStaleResources(300000); // 5 minutes
}

pub fn cleanupStaleMemoryBlocks(resource_manager: *ResourceManager) !void {
    _ = try resource_manager.cleanupStaleResources(60000); // 1 minute
}

pub fn cleanupStaleTimers(resource_manager: *ResourceManager) !void {
    _ = try resource_manager.cleanupStaleResources(120000); // 2 minutes
}

test "Resource manager basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rm = ResourceManager.init(allocator);
    defer rm.deinit();

    // Register a file descriptor
    const fd_metadata = ResourceManager.ResourceMetadata{
        .file_descriptor = .{ .fd = 10, .path = "/tmp/test" },
    };
    const id = try rm.registerResource(.file_descriptor, 0, fd_metadata);

    // Check stats
    const stats = rm.getResourceStats();
    try std.testing.expectEqual(@as(u32, 1), stats.total_resources);
    try std.testing.expectEqual(@as(u32, 1), stats.file_descriptors);

    // Release resource
    try rm.releaseResource(id);

    // Should be cleaned up
    const final_stats = rm.getResourceStats();
    try std.testing.expectEqual(@as(u32, 0), final_stats.total_resources);
}

test "Leak detection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var detector = LeakDetector.init(allocator);
    defer detector.deinit();

    // Track an allocation
    try detector.trackAllocation(0x12345, 1024, "test_component");

    // Scan for leaks (should find none with current timestamp)
    const leaks = try detector.scanForLeaks();
    defer allocator.free(leaks);

    // Should not detect leak immediately
    try std.testing.expectEqual(@as(usize, 0), leaks.len);
}

test "Cleanup scheduler" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rm = ResourceManager.init(allocator);
    defer rm.deinit();

    var scheduler = CleanupScheduler.init(allocator, &rm);
    defer scheduler.deinit();

    // Register cleanup task
    try scheduler.registerTask("test_cleanup", 1000, cleanupStaleFileDescriptors);

    // Run cleanup cycle
    try scheduler.runCleanupCycle();

    // Should complete without error
    try std.testing.expect(true);
}