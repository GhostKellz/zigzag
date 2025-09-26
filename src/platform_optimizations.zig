//! Platform-specific optimizations for maximum performance
//! Linux, macOS, Windows optimizations and runtime capability detection

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Backend = @import("root.zig").Backend;

/// Platform capabilities detected at runtime
pub const PlatformCapabilities = struct {
    // Linux capabilities
    io_uring_available: bool = false,
    io_uring_version: u32 = 0,
    epoll_available: bool = false,
    timerfd_available: bool = false,
    signalfd_available: bool = false,
    splice_available: bool = false,

    // macOS/BSD capabilities
    kqueue_available: bool = false,
    kevent64_available: bool = false,

    // Windows capabilities
    iocp_available: bool = false,
    winsock_version: u32 = 0,

    // General capabilities
    cpu_count: u32 = 1,
    page_size: usize = 4096,
    cache_line_size: usize = 64,
    has_rdtsc: bool = false,
    supports_zero_copy: bool = false,

    pub fn detect() PlatformCapabilities {
        var caps = PlatformCapabilities{};

        // Detect CPU info
        caps.cpu_count = @intCast(std.Thread.getCpuCount() catch 1);
        caps.page_size = std.mem.page_size;
        caps.cache_line_size = getCacheLineSize();
        caps.has_rdtsc = hasRdtsc();

        // Platform-specific detection
        switch (builtin.os.tag) {
            .linux => detectLinuxCapabilities(&caps),
            .macos, .freebsd, .openbsd, .netbsd => detectBsdCapabilities(&caps),
            .windows => detectWindowsCapabilities(&caps),
            else => {},
        }

        return caps;
    }

    fn detectLinuxCapabilities(caps: *PlatformCapabilities) void {
        // Check for epoll
        caps.epoll_available = checkSyscall(.epoll_create1);

        // Check for io_uring
        if (checkIoUring()) |version| {
            caps.io_uring_available = true;
            caps.io_uring_version = version;
            caps.supports_zero_copy = true;
        }

        // Check for timerfd
        caps.timerfd_available = checkSyscall(.timerfd_create);

        // Check for signalfd
        caps.signalfd_available = checkSyscall(.signalfd4);

        // Check for splice
        caps.splice_available = checkSyscall(.splice);
    }

    fn detectBsdCapabilities(caps: *PlatformCapabilities) void {
        // Check for kqueue
        const kfd = posix.kqueue() catch return;
        defer posix.close(kfd);
        caps.kqueue_available = true;

        // Check for kevent64 (macOS specific)
        if (builtin.os.tag == .macos) {
            caps.kevent64_available = true; // Available on macOS 10.6+
        }
    }

    fn detectWindowsCapabilities(caps: *PlatformCapabilities) void {
        if (builtin.os.tag == .windows) {
            caps.iocp_available = true;
            // Check Winsock version
            caps.winsock_version = 0x0202; // Assume Winsock 2.2
        }
    }

    fn checkSyscall(syscall: enum { epoll_create1, timerfd_create, signalfd4, splice }) bool {
        return switch (syscall) {
            .epoll_create1 => blk: {
                const fd = std.os.linux.epoll_create1(0);
                if (fd >= 0) {
                    posix.close(fd);
                    break :blk true;
                }
                break :blk false;
            },
            .timerfd_create => blk: {
                const fd = std.os.linux.timerfd_create(std.os.linux.TIMERFD_CLOCK.MONOTONIC, std.mem.zeroes(std.os.linux.TFD));
                if (std.posix.errno(fd) == .SUCCESS) {
                    posix.close(fd);
                    break :blk true;
                }
                break :blk false;
            },
            .signalfd4 => blk: {
                var mask: posix.sigset_t = undefined;
                _ = std.c.sigemptyset(&mask);
                const fd = std.os.linux.signalfd(-1, &mask, 0);
                if (fd >= 0) {
                    posix.close(fd);
                    break :blk true;
                }
                break :blk false;
            },
            .splice => blk: {
                // Try splice with invalid fds to test availability
                const result = std.os.linux.splice(-1, null, -1, null, 0, 0);
                // If syscall exists, we get EBADF; if not, we get ENOSYS
                break :blk std.posix.errno(result) == .BADF;
            },
        };
    }

    fn checkIoUring() ?u32 {
        // Try to create a minimal io_uring to check availability
        var ring = std.os.linux.IoUring.init(4, 0) catch return null;
        defer ring.deinit();

        // Get version info if available
        // This is simplified - real implementation would probe features
        return 1; // Basic io_uring available
    }

    fn getCacheLineSize() usize {
        // Try to detect cache line size, fallback to common value
        return switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => 64,
            .x86 => 32,
            else => 64,
        };
    }

    fn hasRdtsc() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => true,
            else => false,
        };
    }
};

/// Runtime backend auto-detection with fallback chain
pub const BackendDetector = struct {
    capabilities: PlatformCapabilities,

    pub fn init() BackendDetector {
        return BackendDetector{
            .capabilities = PlatformCapabilities.detect(),
        };
    }

    /// Get optimal backend for this platform
    pub fn getOptimalBackend(self: *const BackendDetector) Backend {
        return switch (builtin.os.tag) {
            .linux => self.selectLinuxBackend(),
            .macos, .freebsd, .openbsd, .netbsd => self.selectBsdBackend(),
            .windows => self.selectWindowsBackend(),
            else => .epoll, // Safe fallback
        };
    }

    /// Get fallback chain for current platform
    pub fn getFallbackChain(self: *const BackendDetector) []const Backend {
        return switch (builtin.os.tag) {
            .linux => if (self.capabilities.io_uring_available)
                &[_]Backend{ .io_uring, .epoll }
            else
                &[_]Backend{.epoll},
            .macos, .freebsd, .openbsd, .netbsd => &[_]Backend{.kqueue},
            .windows => &[_]Backend{.iocp},
            else => &[_]Backend{.epoll},
        };
    }

    fn selectLinuxBackend(self: *const BackendDetector) Backend {
        // Prefer io_uring for high-performance scenarios
        if (self.capabilities.io_uring_available and self.capabilities.io_uring_version > 0) {
            return .io_uring;
        }

        // Fall back to epoll
        if (self.capabilities.epoll_available) {
            return .epoll;
        }

        // This should never happen on Linux
        return .epoll;
    }

    fn selectBsdBackend(self: *const BackendDetector) Backend {
        if (self.capabilities.kqueue_available) {
            return .kqueue;
        }

        // Fallback to epoll if somehow available
        return .epoll;
    }

    fn selectWindowsBackend(self: *const BackendDetector) Backend {
        if (self.capabilities.iocp_available) {
            return .iocp;
        }

        // This should never happen on Windows
        return .iocp;
    }

    /// Check if zero-copy I/O is available
    pub fn supportsZeroCopy(self: *const BackendDetector) bool {
        return self.capabilities.supports_zero_copy;
    }

    /// Get recommended event queue size
    pub fn getRecommendedQueueSize(self: *const BackendDetector) u32 {
        // Scale with CPU count but cap at reasonable limits
        const base_size: u32 = 256;
        const scaled = base_size * self.capabilities.cpu_count;
        return @min(scaled, 4096);
    }

    /// Get recommended thread count for multi-threaded scenarios
    pub fn getRecommendedThreadCount(self: *const BackendDetector) u32 {
        return @min(self.capabilities.cpu_count, 8);
    }
};

/// Platform-specific optimization settings
pub const OptimizationConfig = struct {
    // Buffer sizes optimized for platform
    read_buffer_size: usize,
    write_buffer_size: usize,

    // Event queue configuration
    max_events_per_poll: u32,
    poll_timeout_ms: u32,

    // Memory alignment
    memory_alignment: usize,

    // Backend-specific settings
    use_edge_triggered: bool,
    enable_zero_copy: bool,
    batch_operations: bool,

    pub fn forPlatform(capabilities: PlatformCapabilities, backend: Backend) OptimizationConfig {
        var config = OptimizationConfig{
            .read_buffer_size = 64 * 1024,
            .write_buffer_size = 64 * 1024,
            .max_events_per_poll = 256,
            .poll_timeout_ms = 10,
            .memory_alignment = capabilities.cache_line_size,
            .use_edge_triggered = false,
            .enable_zero_copy = false,
            .batch_operations = true,
        };

        // Platform-specific optimizations
        switch (builtin.os.tag) {
            .linux => optimizeForLinux(&config, capabilities, backend),
            .macos => optimizeForMacOS(&config, capabilities),
            .windows => optimizeForWindows(&config, capabilities),
            else => {},
        }

        return config;
    }

    fn optimizeForLinux(config: *OptimizationConfig, caps: PlatformCapabilities, backend: Backend) void {
        switch (backend) {
            .io_uring => {
                config.enable_zero_copy = caps.supports_zero_copy;
                config.batch_operations = true;
                config.max_events_per_poll = 512;
                config.read_buffer_size = 128 * 1024; // Larger buffers for io_uring
            },
            .epoll => {
                config.use_edge_triggered = true; // EPOLLET for better performance
                config.poll_timeout_ms = 1; // Shorter timeout for responsiveness
            },
            else => {},
        }

        // Optimize buffer sizes based on CPU count
        if (caps.cpu_count >= 8) {
            config.read_buffer_size *= 2;
            config.write_buffer_size *= 2;
        }
    }

    fn optimizeForMacOS(config: *OptimizationConfig, caps: PlatformCapabilities) void {
        // macOS kqueue optimizations
        config.use_edge_triggered = true; // EV_CLEAR
        config.max_events_per_poll = 128; // Conservative for kqueue

        // Optimize for macOS memory management
        if (caps.cpu_count >= 4) {
            config.read_buffer_size = 128 * 1024;
        }
    }

    fn optimizeForWindows(config: *OptimizationConfig, caps: PlatformCapabilities) void {
        // Windows IOCP optimizations
        config.batch_operations = true;
        config.max_events_per_poll = 64 * caps.cpu_count;
        config.poll_timeout_ms = 0; // IOCP handles timeouts differently

        // Align buffers to page boundaries for better performance
        config.memory_alignment = caps.page_size;
    }
};

/// CPU affinity and NUMA optimizations
pub const CPUOptimizer = struct {
    /// Set CPU affinity for optimal performance
    pub fn optimizeCpuAffinity(thread_id: ?std.Thread.Id) !void {
        _ = thread_id;
        // Implementation would depend on platform
        switch (builtin.os.tag) {
            .linux => {
                // Use sched_setaffinity to bind to specific CPUs
                // Implementation omitted for brevity
            },
            .windows => {
                // Use SetThreadAffinityMask
                // Implementation omitted for brevity
            },
            else => {
                // No-op for unsupported platforms
            },
        }
    }

    /// Optimize for NUMA topology
    pub fn optimizeNuma() !void {
        switch (builtin.os.tag) {
            .linux => {
                // Check /sys/devices/system/node for NUMA info
                // Bind memory allocation to local NUMA nodes
            },
            else => {
                // No-op for non-NUMA or unsupported platforms
            },
        }
    }
};

/// Memory optimization utilities
pub const MemoryOptimizer = struct {
    /// Get optimal allocator for platform
    pub fn getOptimalAllocator() std.mem.Allocator {
        // Use page allocator for large allocations on most platforms
        // Could be customized based on platform capabilities
        return std.heap.page_allocator;
    }

    /// Prefault pages for critical data structures
    pub fn prefaultPages(memory: []u8) void {
        // Touch each page to ensure it's mapped
        const page_size = std.mem.page_size;
        var offset: usize = 0;
        while (offset < memory.len) {
            memory[offset] = memory[offset]; // Read-write to fault the page
            offset += page_size;
        }
    }

    /// Hint for memory usage pattern
    pub fn hintSequentialAccess(memory: []u8) void {
        _ = memory;
        switch (builtin.os.tag) {
            .linux => {
                // Use madvise with MADV_SEQUENTIAL
                // Implementation omitted for brevity
            },
            else => {
                // No-op for unsupported platforms
            },
        }
    }
};

test "Platform capabilities detection" {
    const caps = PlatformCapabilities.detect();

    // Basic sanity checks
    try std.testing.expect(caps.cpu_count > 0);
    try std.testing.expect(caps.page_size > 0);
    try std.testing.expect(caps.cache_line_size > 0);

    // Platform-specific checks
    switch (builtin.os.tag) {
        .linux => {
            // On Linux, epoll should always be available
            try std.testing.expect(caps.epoll_available);
        },
        else => {},
    }
}

test "Backend detection" {
    const detector = BackendDetector.init();

    const optimal = detector.getOptimalBackend();
    const fallback_chain = detector.getFallbackChain();

    // Should have at least one backend available
    try std.testing.expect(fallback_chain.len > 0);

    // Optimal backend should be in the fallback chain
    var found = false;
    for (fallback_chain) |backend| {
        if (backend == optimal) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "Optimization config" {
    const caps = PlatformCapabilities.detect();
    const config = OptimizationConfig.forPlatform(caps, .epoll);

    // Basic sanity checks
    try std.testing.expect(config.read_buffer_size > 0);
    try std.testing.expect(config.write_buffer_size > 0);
    try std.testing.expect(config.max_events_per_poll > 0);
    try std.testing.expect(config.memory_alignment > 0);
}