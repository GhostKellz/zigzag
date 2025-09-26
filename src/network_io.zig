//! High-performance network I/O with connection pooling and async operations
//! Provides efficient socket management, connection reuse, and bandwidth monitoring

const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const os = std.os;
const print = std.debug.print;

const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const EventType = @import("root.zig").EventType;
const Backend = @import("root.zig").Backend;

/// Network connection state
pub const ConnectionState = enum {
    idle,
    connecting,
    connected,
    disconnecting,
    failed,
    closed,
};

/// Connection pool statistics
pub const PoolStats = struct {
    total_connections: u32 = 0,
    active_connections: u32 = 0,
    idle_connections: u32 = 0,
    failed_connections: u32 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    connect_time_ms: u64 = 0,
    last_activity: i64 = 0,

    pub fn getActiveRatio(self: PoolStats) f32 {
        if (self.total_connections == 0) return 0.0;
        return @as(f32, @floatFromInt(self.active_connections)) / @as(f32, @floatFromInt(self.total_connections));
    }

    pub fn getThroughputMBps(self: PoolStats, duration_ms: u64) f32 {
        if (duration_ms == 0) return 0.0;
        const total_bytes = self.bytes_sent + self.bytes_received;
        const bytes_per_ms = @as(f32, @floatFromInt(total_bytes)) / @as(f32, @floatFromInt(duration_ms));
        return bytes_per_ms / 1024.0; // Convert to MB/s
    }
};

/// Network connection wrapper
pub const NetworkConnection = struct {
    fd: os.fd_t,
    address: net.Address,
    state: ConnectionState,
    created_at: i64,
    last_activity: i64,
    bytes_sent: u64,
    bytes_received: u64,
    user_data: ?*anyopaque,

    pub fn init(fd: os.fd_t, address: net.Address) NetworkConnection {
        const now = std.time.milliTimestamp();
        return NetworkConnection{
            .fd = fd,
            .address = address,
            .state = .connecting,
            .created_at = now,
            .last_activity = now,
            .bytes_sent = 0,
            .bytes_received = 0,
            .user_data = null,
        };
    }

    pub fn isExpired(self: NetworkConnection, timeout_ms: i64) bool {
        const now = std.time.milliTimestamp();
        return (now - self.last_activity) > timeout_ms;
    }

    pub fn updateActivity(self: *NetworkConnection) void {
        self.last_activity = std.time.milliTimestamp();
    }

    pub fn addBytesSent(self: *NetworkConnection, bytes: u64) void {
        self.bytes_sent += bytes;
        self.updateActivity();
    }

    pub fn addBytesReceived(self: *NetworkConnection, bytes: u64) void {
        self.bytes_received += bytes;
        self.updateActivity();
    }
};

/// Connection pool configuration
pub const PoolConfig = struct {
    max_connections: u32 = 100,
    idle_timeout_ms: i64 = 30000, // 30 seconds
    connect_timeout_ms: i64 = 5000, // 5 seconds
    keep_alive: bool = true,
    tcp_nodelay: bool = true,
    reuse_address: bool = true,
    buffer_size: u32 = 8192,
};

/// High-performance connection pool
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    connections: std.AutoHashMap(os.fd_t, NetworkConnection),
    idle_connections: std.ArrayList(os.fd_t),
    connecting_connections: std.AutoHashMap(os.fd_t, i64),
    stats: PoolStats,
    event_loop: *EventLoop,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig, event_loop: *EventLoop) !ConnectionPool {
        return ConnectionPool{
            .allocator = allocator,
            .config = config,
            .connections = std.AutoHashMap(os.fd_t, NetworkConnection).init(allocator),
            .idle_connections = std.ArrayList(os.fd_t).init(allocator),
            .connecting_connections = std.AutoHashMap(os.fd_t, i64).init(allocator),
            .stats = PoolStats{},
            .event_loop = event_loop,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        // Close all connections
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            os.close(entry.value_ptr.fd);
        }

        self.connections.deinit();
        self.idle_connections.deinit();
        self.connecting_connections.deinit();
    }

    /// Connect to a remote address
    pub fn connect(self: *ConnectionPool, address: net.Address) !os.fd_t {
        if (self.stats.total_connections >= self.config.max_connections) {
            return error.PoolExhausted;
        }

        // Try to reuse an idle connection to the same address
        for (self.idle_connections.items, 0..) |fd, i| {
            if (self.connections.get(fd)) |conn| {
                if (std.meta.eql(conn.address, address) and !conn.isExpired(self.config.idle_timeout_ms)) {
                    // Reuse this connection
                    _ = self.idle_connections.swapRemove(i);
                    var mutable_conn = self.connections.getPtr(fd).?;
                    mutable_conn.state = .connected;
                    mutable_conn.updateActivity();
                    self.stats.active_connections += 1;
                    return fd;
                }
            }
        }

        // Create new connection
        const fd = try os.socket(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
        errdefer os.close(fd);

        // Set socket options
        if (self.config.tcp_nodelay) {
            try os.setsockopt(fd, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
        }

        if (self.config.reuse_address) {
            try os.setsockopt(fd, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        }

        // Set non-blocking
        const flags = try os.fcntl(fd, os.F.GETFL, 0);
        _ = try os.fcntl(fd, os.F.SETFL, flags | os.O.NONBLOCK);

        // Attempt connection
        const connect_result = os.connect(fd, &address.any, address.getOsSockLen());

        var conn = NetworkConnection.init(fd, address);

        if (connect_result) {
            // Connected immediately
            conn.state = .connected;
            self.stats.active_connections += 1;
        } else |err| switch (err) {
            error.WouldBlock => {
                // Connection in progress
                conn.state = .connecting;
                try self.connecting_connections.put(fd, std.time.milliTimestamp());

                // Register for write events to detect connection completion
                try self.event_loop.addWatch(fd, .{ .write = true });
            },
            else => return err,
        }

        try self.connections.put(fd, conn);
        self.stats.total_connections += 1;

        return fd;
    }

    /// Release a connection back to the pool
    pub fn release(self: *ConnectionPool, fd: os.fd_t) !void {
        if (self.connections.getPtr(fd)) |conn| {
            if (conn.state == .connected and self.config.keep_alive) {
                // Return to idle pool
                conn.state = .idle;
                conn.updateActivity();
                try self.idle_connections.append(fd);
                self.stats.active_connections -= 1;
            } else {
                // Close the connection
                try self.closeConnection(fd);
            }
        }
    }

    /// Close a specific connection
    pub fn closeConnection(self: *ConnectionPool, fd: os.fd_t) !void {
        if (self.connections.get(fd)) |conn| {
            os.close(fd);
            _ = self.connections.remove(fd);

            // Remove from other collections
            for (self.idle_connections.items, 0..) |idle_fd, i| {
                if (idle_fd == fd) {
                    _ = self.idle_connections.swapRemove(i);
                    break;
                }
            }
            _ = self.connecting_connections.remove(fd);

            if (conn.state == .connected) {
                self.stats.active_connections -= 1;
            }
            self.stats.total_connections -= 1;
        }
    }

    /// Clean up expired connections
    pub fn cleanup(self: *ConnectionPool) !void {
        var expired_fds = std.ArrayList(os.fd_t).init(self.allocator);
        defer expired_fds.deinit();

        // Check idle connections for expiration
        var i: usize = 0;
        while (i < self.idle_connections.items.len) {
            const fd = self.idle_connections.items[i];
            if (self.connections.get(fd)) |conn| {
                if (conn.isExpired(self.config.idle_timeout_ms)) {
                    try expired_fds.append(fd);
                    _ = self.idle_connections.swapRemove(i);
                    continue;
                }
            }
            i += 1;
        }

        // Check connecting connections for timeout
        var connecting_iter = self.connecting_connections.iterator();
        while (connecting_iter.next()) |entry| {
            const fd = entry.key_ptr.*;
            const connect_time = entry.value_ptr.*;
            const now = std.time.milliTimestamp();

            if ((now - connect_time) > self.config.connect_timeout_ms) {
                try expired_fds.append(fd);
            }
        }

        // Close expired connections
        for (expired_fds.items) |fd| {
            try self.closeConnection(fd);
        }
    }

    /// Handle connection completion events
    pub fn handleConnectionEvent(self: *ConnectionPool, fd: os.fd_t, event_type: EventType) !void {
        if (self.connecting_connections.contains(fd)) {
            if (event_type.write) {
                // Check if connection succeeded
                var error_code: i32 = 0;
                var len: u32 = @sizeOf(i32);

                const result = os.getsockopt(fd, os.SOL.SOCKET, os.SO.ERROR,
                    std.mem.asBytes(&error_code)[0..len], &len);

                if (result == 0 and error_code == 0) {
                    // Connection successful
                    if (self.connections.getPtr(fd)) |conn| {
                        conn.state = .connected;
                        conn.updateActivity();
                        self.stats.active_connections += 1;
                    }
                } else {
                    // Connection failed
                    if (self.connections.getPtr(fd)) |conn| {
                        conn.state = .failed;
                        self.stats.failed_connections += 1;
                    }
                }

                _ = self.connecting_connections.remove(fd);
            }
        }
    }

    /// Send data on a connection
    pub fn send(self: *ConnectionPool, fd: os.fd_t, data: []const u8) !usize {
        if (self.connections.getPtr(fd)) |conn| {
            if (conn.state != .connected) {
                return error.ConnectionNotReady;
            }

            const bytes_sent = try os.send(fd, data, 0);
            conn.addBytesSent(@intCast(bytes_sent));
            self.stats.bytes_sent += @intCast(bytes_sent);

            return bytes_sent;
        }
        return error.ConnectionNotFound;
    }

    /// Receive data from a connection
    pub fn receive(self: *ConnectionPool, fd: os.fd_t, buffer: []u8) !usize {
        if (self.connections.getPtr(fd)) |conn| {
            if (conn.state != .connected) {
                return error.ConnectionNotReady;
            }

            const bytes_received = try os.recv(fd, buffer, 0);
            conn.addBytesReceived(@intCast(bytes_received));
            self.stats.bytes_received += @intCast(bytes_received);

            return bytes_received;
        }
        return error.ConnectionNotFound;
    }

    pub fn getStats(self: ConnectionPool) PoolStats {
        return self.stats;
    }

    pub fn getConnection(self: ConnectionPool, fd: os.fd_t) ?NetworkConnection {
        return self.connections.get(fd);
    }
};

/// Bandwidth monitoring for network operations
pub const BandwidthMonitor = struct {
    allocator: std.mem.Allocator,
    window_size_ms: u64,
    samples: std.ArrayList(BandwidthSample),
    total_bytes_in: u64,
    total_bytes_out: u64,

    const BandwidthSample = struct {
        timestamp: i64,
        bytes_in: u64,
        bytes_out: u64,
    };

    pub fn init(allocator: std.mem.Allocator, window_size_ms: u64) BandwidthMonitor {
        return BandwidthMonitor{
            .allocator = allocator,
            .window_size_ms = window_size_ms,
            .samples = std.ArrayList(BandwidthSample).init(allocator),
            .total_bytes_in = 0,
            .total_bytes_out = 0,
        };
    }

    pub fn deinit(self: *BandwidthMonitor) void {
        self.samples.deinit();
    }

    pub fn recordTraffic(self: *BandwidthMonitor, bytes_in: u64, bytes_out: u64) !void {
        const now = std.time.milliTimestamp();

        try self.samples.append(BandwidthSample{
            .timestamp = now,
            .bytes_in = bytes_in,
            .bytes_out = bytes_out,
        });

        self.total_bytes_in += bytes_in;
        self.total_bytes_out += bytes_out;

        // Remove old samples outside the window
        const cutoff = now - @as(i64, @intCast(self.window_size_ms));
        var sample_i: usize = 0;
        while (sample_i < self.samples.items.len) {
            if (self.samples.items[sample_i].timestamp < cutoff) {
                _ = self.samples.orderedRemove(sample_i);
            } else {
                break;
            }
        }
    }

    pub fn getCurrentBandwidth(self: BandwidthMonitor) struct { in: f64, out: f64 } {
        if (self.samples.items.len < 2) return .{ .in = 0.0, .out = 0.0 };

        const latest = self.samples.items[self.samples.items.len - 1];
        const oldest = self.samples.items[0];

        const time_diff = @as(f64, @floatFromInt(latest.timestamp - oldest.timestamp)) / 1000.0; // Convert to seconds
        if (time_diff <= 0) return .{ .in = 0.0, .out = 0.0 };

        var total_in: u64 = 0;
        var total_out: u64 = 0;

        for (self.samples.items) |sample| {
            total_in += sample.bytes_in;
            total_out += sample.bytes_out;
        }

        return .{
            .in = @as(f64, @floatFromInt(total_in)) / time_diff,
            .out = @as(f64, @floatFromInt(total_out)) / time_diff,
        };
    }

    pub fn getTotalBytes(self: BandwidthMonitor) struct { in: u64, out: u64 } {
        return .{ .in = self.total_bytes_in, .out = self.total_bytes_out };
    }
};

/// Network I/O manager combining connection pooling and monitoring
pub const NetworkManager = struct {
    allocator: std.mem.Allocator,
    pool: ConnectionPool,
    bandwidth_monitor: BandwidthMonitor,
    event_loop: *EventLoop,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig, event_loop: *EventLoop) !NetworkManager {
        return NetworkManager{
            .allocator = allocator,
            .pool = try ConnectionPool.init(allocator, config, event_loop),
            .bandwidth_monitor = BandwidthMonitor.init(allocator, 10000), // 10 second window
            .event_loop = event_loop,
        };
    }

    pub fn deinit(self: *NetworkManager) void {
        self.pool.deinit();
        self.bandwidth_monitor.deinit();
    }

    pub fn connect(self: *NetworkManager, address: net.Address) !os.fd_t {
        return try self.pool.connect(address);
    }

    pub fn send(self: *NetworkManager, fd: os.fd_t, data: []const u8) !usize {
        const bytes_sent = try self.pool.send(fd, data);
        try self.bandwidth_monitor.recordTraffic(0, @intCast(bytes_sent));
        return bytes_sent;
    }

    pub fn receive(self: *NetworkManager, fd: os.fd_t, buffer: []u8) !usize {
        const bytes_received = try self.pool.receive(fd, buffer);
        try self.bandwidth_monitor.recordTraffic(@intCast(bytes_received), 0);
        return bytes_received;
    }

    pub fn release(self: *NetworkManager, fd: os.fd_t) !void {
        try self.pool.release(fd);
    }

    pub fn cleanup(self: *NetworkManager) !void {
        try self.pool.cleanup();
    }

    pub fn handleEvent(self: *NetworkManager, fd: os.fd_t, event_type: EventType) !void {
        try self.pool.handleConnectionEvent(fd, event_type);
    }

    pub fn getPoolStats(self: NetworkManager) PoolStats {
        return self.pool.getStats();
    }

    pub fn getBandwidth(self: NetworkManager) struct { in: f64, out: f64 } {
        return self.bandwidth_monitor.getCurrentBandwidth();
    }

    pub fn getTotalBytes(self: NetworkManager) struct { in: u64, out: u64 } {
        return self.bandwidth_monitor.getTotalBytes();
    }
};

test "NetworkConnection lifecycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const address = try net.Address.parseIp("127.0.0.1", 8080);
    var conn = NetworkConnection.init(1, address);

    try std.testing.expect(conn.state == .connecting);
    try std.testing.expect(conn.bytes_sent == 0);
    try std.testing.expect(conn.bytes_received == 0);

    conn.addBytesSent(100);
    conn.addBytesReceived(200);

    try std.testing.expectEqual(@as(u64, 100), conn.bytes_sent);
    try std.testing.expectEqual(@as(u64, 200), conn.bytes_received);
}

test "BandwidthMonitor" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var monitor = BandwidthMonitor.init(allocator, 5000); // 5 second window
    defer monitor.deinit();

    try monitor.recordTraffic(1000, 500);
    try monitor.recordTraffic(2000, 1000);

    const totals = monitor.getTotalBytes();
    try std.testing.expectEqual(@as(u64, 3000), totals.in);
    try std.testing.expectEqual(@as(u64, 1500), totals.out);
}

test "PoolStats calculations" {
    var stats = PoolStats{
        .total_connections = 10,
        .active_connections = 7,
        .bytes_sent = 1024 * 1024, // 1 MB
        .bytes_received = 2 * 1024 * 1024, // 2 MB
    };

    try std.testing.expectEqual(@as(f32, 0.7), stats.getActiveRatio());

    const throughput = stats.getThroughputMBps(1000); // 1 second
    try std.testing.expect(throughput > 2.9 and throughput < 3.1); // ~3 MB/s
}