//! Thread safety utilities for ZigZag
//! Provides optional multi-threading support and thread-safe utilities

const std = @import("std");
const builtin = @import("builtin");
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;

/// Thread-safe event queue using lock-free techniques where possible
pub const ThreadSafeEventQueue = struct {
    allocator: std.mem.Allocator,
    buffer: []Event,
    capacity: usize,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !ThreadSafeEventQueue {
        // Ensure capacity is power of 2 for efficient modulo
        const actual_capacity = std.math.ceilPowerOfTwo(usize, capacity) catch return error.CapacityTooLarge;
        const buffer = try allocator.alloc(Event, actual_capacity);

        return ThreadSafeEventQueue{
            .allocator = allocator,
            .buffer = buffer,
            .capacity = actual_capacity,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *ThreadSafeEventQueue) void {
        self.allocator.free(self.buffer);
    }

    /// Try to push an event (non-blocking)
    pub fn tryPush(self: *ThreadSafeEventQueue, event: Event) bool {
        const tail = self.tail.load(.acquire);
        const next_tail = (tail + 1) & (self.capacity - 1);
        const head = self.head.load(.acquire);

        // Check if queue is full
        if (next_tail == head) {
            return false;
        }

        // Store the event
        self.buffer[tail] = event;

        // Update tail atomically
        self.tail.store(next_tail, .release);
        return true;
    }

    /// Try to pop an event (non-blocking)
    pub fn tryPop(self: *ThreadSafeEventQueue) ?Event {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);

        // Check if queue is empty
        if (head == tail) {
            return null;
        }

        // Load the event
        const event = self.buffer[head];

        // Update head atomically
        const next_head = (head + 1) & (self.capacity - 1);
        self.head.store(next_head, .release);

        return event;
    }

    /// Push with blocking (uses mutex for simplicity)
    pub fn push(self: *ThreadSafeEventQueue, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Spin until we can push
        while (!self.tryPush(event)) {
            // Yield to other threads
            std.Thread.yield() catch {};
        }
    }

    /// Pop with blocking
    pub fn pop(self: *ThreadSafeEventQueue) Event {
        while (true) {
            if (self.tryPop()) |event| {
                return event;
            }
            // Yield to other threads
            std.Thread.yield() catch {};
        }
    }

    /// Get current queue size (approximate)
    pub fn size(self: *const ThreadSafeEventQueue) usize {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return (tail - head) & (self.capacity - 1);
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *const ThreadSafeEventQueue) bool {
        return self.head.load(.acquire) == self.tail.load(.acquire);
    }

    /// Check if queue is full
    pub fn isFull(self: *const ThreadSafeEventQueue) bool {
        const tail = self.tail.load(.acquire);
        const next_tail = (tail + 1) & (self.capacity - 1);
        return next_tail == self.head.load(.acquire);
    }
};

/// Thread-safe reference counting for shared resources
pub const RefCount = struct {
    count: std.atomic.Value(u32),

    pub fn init(initial_count: u32) RefCount {
        return RefCount{
            .count = std.atomic.Value(u32).init(initial_count),
        };
    }

    /// Increment reference count
    pub fn acquire(self: *RefCount) u32 {
        return self.count.fetchAdd(1, .acq_rel) + 1;
    }

    /// Decrement reference count, returns true if reached zero
    pub fn release(self: *RefCount) bool {
        const old_count = self.count.fetchSub(1, .acq_rel);
        return old_count == 1;
    }

    /// Get current count
    pub fn get(self: *const RefCount) u32 {
        return self.count.load(.acquire);
    }
};

/// Thread-safe shared pointer
pub fn SharedPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: ?*T,
        ref_count: ?*RefCount,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            const ptr = try allocator.create(T);
            ptr.* = value;

            const ref_count = try allocator.create(RefCount);
            ref_count.* = RefCount.init(1);

            return Self{
                .ptr = ptr,
                .ref_count = ref_count,
                .allocator = allocator,
            };
        }

        pub fn clone(self: *const Self) Self {
            if (self.ref_count) |ref_count| {
                _ = ref_count.acquire();
            }
            return Self{
                .ptr = self.ptr,
                .ref_count = self.ref_count,
                .allocator = self.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.ref_count) |ref_count| {
                if (ref_count.release()) {
                    // Last reference, clean up
                    if (self.ptr) |ptr| {
                        self.allocator.destroy(ptr);
                    }
                    self.allocator.destroy(ref_count);
                }
            }
            self.ptr = null;
            self.ref_count = null;
        }

        pub fn get(self: *const Self) ?*T {
            return self.ptr;
        }

        pub fn getRefCount(self: *const Self) u32 {
            if (self.ref_count) |ref_count| {
                return ref_count.get();
            }
            return 0;
        }
    };
}

/// Multi-threaded event loop wrapper
pub const MultiThreadedEventLoop = struct {
    allocator: std.mem.Allocator,
    event_loop: *EventLoop,
    worker_threads: []std.Thread,
    event_queue: ThreadSafeEventQueue,
    should_stop: std.atomic.Value(bool),
    thread_pool_size: usize,

    /// Configuration for multi-threaded setup
    pub const Config = struct {
        thread_pool_size: usize = 4,
        event_queue_size: usize = 4096,
        worker_stack_size: usize = 64 * 1024,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        event_loop: *EventLoop,
        config: Config,
    ) !MultiThreadedEventLoop {
        var event_queue = try ThreadSafeEventQueue.init(allocator, config.event_queue_size);
        errdefer event_queue.deinit();

        const worker_threads = try allocator.alloc(std.Thread, config.thread_pool_size);
        errdefer allocator.free(worker_threads);

        return MultiThreadedEventLoop{
            .allocator = allocator,
            .event_loop = event_loop,
            .worker_threads = worker_threads,
            .event_queue = event_queue,
            .should_stop = std.atomic.Value(bool).init(false),
            .thread_pool_size = config.thread_pool_size,
        };
    }

    pub fn deinit(self: *MultiThreadedEventLoop) void {
        self.stop();
        self.event_queue.deinit();
        self.allocator.free(self.worker_threads);
    }

    /// Start the multi-threaded event loop
    pub fn start(self: *MultiThreadedEventLoop) !void {
        // Spawn worker threads
        for (self.worker_threads, 0..) |*thread, i| {
            const context = WorkerContext{
                .mt_loop = self,
                .worker_id = i,
            };

            thread.* = try std.Thread.spawn(.{}, workerMain, .{context});
        }
    }

    /// Stop the multi-threaded event loop
    pub fn stop(self: *MultiThreadedEventLoop) void {
        self.should_stop.store(true, .release);

        // Wait for all worker threads to finish
        for (self.worker_threads) |*thread| {
            thread.join();
        }
    }

    /// Submit an event for processing
    pub fn submitEvent(self: *MultiThreadedEventLoop, event: Event) !void {
        try self.event_queue.push(event);
    }

    /// Worker thread context
    const WorkerContext = struct {
        mt_loop: *MultiThreadedEventLoop,
        worker_id: usize,
    };

    /// Worker thread main function
    fn workerMain(context: WorkerContext) void {
        const mt_loop = context.mt_loop;

        while (!mt_loop.should_stop.load(.acquire)) {
            // Try to get events from queue
            if (mt_loop.event_queue.tryPop()) |event| {
                processEventInWorker(event, context.worker_id);
            } else {
                // No events, yield to other threads
                std.Thread.yield() catch {};
            }
        }
    }

    /// Process an event in a worker thread
    fn processEventInWorker(event: Event, worker_id: usize) void {
        _ = worker_id;
        // Process the event
        // This is where actual event handling would occur
        // For now, just a placeholder
        _ = event;
    }
};

/// Thread-safe utilities
pub const ThreadSafeUtils = struct {
    /// Thread-safe counter
    pub const Counter = struct {
        value: std.atomic.Value(u64),

        pub fn init(initial: u64) Counter {
            return Counter{
                .value = std.atomic.Value(u64).init(initial),
            };
        }

        pub fn increment(self: *Counter) u64 {
            return self.value.fetchAdd(1, .acq_rel) + 1;
        }

        pub fn decrement(self: *Counter) u64 {
            return self.value.fetchSub(1, .acq_rel) - 1;
        }

        pub fn get(self: *const Counter) u64 {
            return self.value.load(.acquire);
        }

        pub fn set(self: *Counter, new_value: u64) void {
            self.value.store(new_value, .release);
        }
    };

    /// Thread-safe flag
    pub const Flag = struct {
        value: std.atomic.Value(bool),

        pub fn init(initial: bool) Flag {
            return Flag{
                .value = std.atomic.Value(bool).init(initial),
            };
        }

        pub fn set(self: *Flag) void {
            self.value.store(true, .release);
        }

        pub fn clear(self: *Flag) void {
            self.value.store(false, .release);
        }

        pub fn isSet(self: *const Flag) bool {
            return self.value.load(.acquire);
        }

        pub fn testAndSet(self: *Flag) bool {
            return self.value.swap(true, .acq_rel);
        }
    };

    /// Thread-safe statistics collector
    pub const StatsCollector = struct {
        total_events: Counter,
        processing_time_ns: std.atomic.Value(u64),
        max_processing_time_ns: std.atomic.Value(u64),
        mutex: std.Thread.Mutex = .{},

        pub fn init() StatsCollector {
            return StatsCollector{
                .total_events = Counter.init(0),
                .processing_time_ns = std.atomic.Value(u64).init(0),
                .max_processing_time_ns = std.atomic.Value(u64).init(0),
            };
        }

        pub fn recordEvent(self: *StatsCollector, processing_time_ns: u64) void {
            _ = self.total_events.increment();
            _ = self.processing_time_ns.fetchAdd(processing_time_ns, .acq_rel);

            // Update max processing time
            var current_max = self.max_processing_time_ns.load(.acquire);
            while (processing_time_ns > current_max) {
                const old_max = self.max_processing_time_ns.compareAndSwap(
                    current_max,
                    processing_time_ns,
                    .acq_rel,
                    .acquire,
                ) orelse break;
                current_max = old_max;
            }
        }

        pub fn getStats(self: *const StatsCollector) Stats {
            const total = self.total_events.get();
            const total_time = self.processing_time_ns.load(.acquire);
            const max_time = self.max_processing_time_ns.load(.acquire);

            return Stats{
                .total_events = total,
                .avg_processing_time_ns = if (total > 0) total_time / total else 0,
                .max_processing_time_ns = max_time,
            };
        }

        const Stats = struct {
            total_events: u64,
            avg_processing_time_ns: u64,
            max_processing_time_ns: u64,
        };
    };
};

/// Lock-free circular buffer for single producer, single consumer
pub fn SPSCQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        capacity: usize,
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            // Ensure capacity is power of 2
            const actual_capacity = std.math.ceilPowerOfTwo(usize, capacity) catch return error.CapacityTooLarge;
            const buffer = try allocator.alloc(T, actual_capacity);

            return Self{
                .buffer = buffer,
                .capacity = actual_capacity,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Producer: Try to push an item
        pub fn tryPush(self: *Self, item: T) bool {
            const tail = self.tail.load(.relaxed);
            const next_tail = (tail + 1) & (self.capacity - 1);

            if (next_tail == self.head.load(.acquire)) {
                return false; // Queue is full
            }

            self.buffer[tail] = item;
            self.tail.store(next_tail, .release);
            return true;
        }

        /// Consumer: Try to pop an item
        pub fn tryPop(self: *Self) ?T {
            const head = self.head.load(.relaxed);

            if (head == self.tail.load(.acquire)) {
                return null; // Queue is empty
            }

            const item = self.buffer[head];
            const next_head = (head + 1) & (self.capacity - 1);
            self.head.store(next_head, .release);
            return item;
        }

        pub fn size(self: *const Self) usize {
            const tail = self.tail.load(.acquire);
            const head = self.head.load(.acquire);
            return (tail - head) & (self.capacity - 1);
        }
    };
}

/// Thread-local storage for per-thread state
pub const ThreadLocalStorage = struct {
    var thread_id_counter = std.atomic.Value(u32).init(1);

    /// Get unique thread ID
    pub fn getThreadId() u32 {
        const thread_local = struct {
            var thread_id: u32 = 0;
        };

        if (thread_local.thread_id == 0) {
            thread_local.thread_id = thread_id_counter.fetchAdd(1, .acq_rel);
        }
        return thread_local.thread_id;
    }

    /// Thread-local event statistics
    pub fn getThreadStats() *ThreadSafeUtils.StatsCollector {
        const thread_local = struct {
            var stats: ?ThreadSafeUtils.StatsCollector = null;
        };

        if (thread_local.stats == null) {
            thread_local.stats = ThreadSafeUtils.StatsCollector.init();
        }
        return &thread_local.stats.?;
    }
};

test "Thread-safe event queue" {
    const allocator = std.testing.allocator;

    var queue = try ThreadSafeEventQueue.init(allocator, 8);
    defer queue.deinit();

    const event = Event{
        .fd = 1,
        .type = .read_ready,
        .data = .{ .size = 100 },
    };

    // Test push/pop
    try std.testing.expect(queue.tryPush(event));
    try std.testing.expectEqual(@as(usize, 1), queue.size());

    const popped = queue.tryPop().?;
    try std.testing.expectEqual(event.fd, popped.fd);
    try std.testing.expectEqual(event.type, popped.type);
    try std.testing.expect(queue.isEmpty());
}

test "Reference counting" {
    var ref_count = RefCount.init(1);

    try std.testing.expectEqual(@as(u32, 1), ref_count.get());

    _ = ref_count.acquire();
    try std.testing.expectEqual(@as(u32, 2), ref_count.get());

    try std.testing.expect(!ref_count.release());
    try std.testing.expectEqual(@as(u32, 1), ref_count.get());

    try std.testing.expect(ref_count.release());
    try std.testing.expectEqual(@as(u32, 0), ref_count.get());
}

test "Shared pointer" {
    const allocator = std.testing.allocator;

    var ptr1 = try SharedPtr(u32).init(allocator, 42);
    defer ptr1.deinit();

    try std.testing.expectEqual(@as(u32, 1), ptr1.getRefCount());
    try std.testing.expectEqual(@as(u32, 42), ptr1.get().?.*);

    var ptr2 = ptr1.clone();
    defer ptr2.deinit();

    try std.testing.expectEqual(@as(u32, 2), ptr1.getRefCount());
    try std.testing.expectEqual(@as(u32, 2), ptr2.getRefCount());
}

test "Thread-safe utilities" {
    var counter = ThreadSafeUtils.Counter.init(0);
    try std.testing.expectEqual(@as(u64, 1), counter.increment());
    try std.testing.expectEqual(@as(u64, 2), counter.increment());
    try std.testing.expectEqual(@as(u64, 1), counter.decrement());

    var flag = ThreadSafeUtils.Flag.init(false);
    try std.testing.expect(!flag.isSet());
    flag.set();
    try std.testing.expect(flag.isSet());
    try std.testing.expect(flag.testAndSet()); // Was already set
    flag.clear();
    try std.testing.expect(!flag.isSet());
}

test "SPSC queue" {
    const allocator = std.testing.allocator;

    var queue = try SPSCQueue(u32).init(allocator, 4);
    defer queue.deinit();

    try std.testing.expect(queue.tryPush(1));
    try std.testing.expect(queue.tryPush(2));
    try std.testing.expectEqual(@as(usize, 2), queue.size());

    try std.testing.expectEqual(@as(u32, 1), queue.tryPop().?);
    try std.testing.expectEqual(@as(u32, 2), queue.tryPop().?);
    try std.testing.expect(queue.tryPop() == null);
}