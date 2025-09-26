//! Zero-copy I/O implementation for maximum performance
//! Provides direct buffer management and ring buffer support

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Ring buffer for zero-copy I/O
pub const RingBuffer = struct {
    data: []u8,
    read_pos: usize,
    write_pos: usize,
    capacity: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuffer {
        const data = try allocator.alloc(u8, capacity);
        return RingBuffer{
            .data = data,
            .read_pos = 0,
            .write_pos = 0,
            .capacity = capacity,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.data);
    }

    /// Get available space for writing
    pub fn availableWrite(self: *const RingBuffer) usize {
        if (self.write_pos >= self.read_pos) {
            return self.capacity - self.write_pos + self.read_pos - 1;
        } else {
            return self.read_pos - self.write_pos - 1;
        }
    }

    /// Get available data for reading
    pub fn availableRead(self: *const RingBuffer) usize {
        if (self.write_pos >= self.read_pos) {
            return self.write_pos - self.read_pos;
        } else {
            return self.capacity - self.read_pos + self.write_pos;
        }
    }

    /// Get contiguous write buffer
    pub fn getWriteBuffer(self: *RingBuffer) []u8 {
        const end = if (self.write_pos >= self.read_pos) self.capacity else self.read_pos - 1;
        return self.data[self.write_pos..end];
    }

    /// Commit written data
    pub fn commitWrite(self: *RingBuffer, bytes: usize) void {
        self.write_pos = (self.write_pos + bytes) % self.capacity;
    }

    /// Get contiguous read buffer
    pub fn getReadBuffer(self: *const RingBuffer) []const u8 {
        const end = if (self.write_pos >= self.read_pos) self.write_pos else self.capacity;
        return self.data[self.read_pos..end];
    }

    /// Consume read data
    pub fn commitRead(self: *RingBuffer, bytes: usize) void {
        self.read_pos = (self.read_pos + bytes) % self.capacity;
    }

    /// Clear the buffer
    pub fn clear(self: *RingBuffer) void {
        self.read_pos = 0;
        self.write_pos = 0;
    }
};

/// Buffer pool for efficient allocation
pub const BufferPool = struct {
    const BufferNode = struct {
        buffer: []u8,
        next: ?*BufferNode,
    };

    allocator: std.mem.Allocator,
    buffer_size: usize,
    free_list: ?*BufferNode,
    allocated_count: usize,
    max_buffers: usize,

    pub fn init(allocator: std.mem.Allocator, buffer_size: usize, max_buffers: usize) BufferPool {
        return BufferPool{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .free_list = null,
            .allocated_count = 0,
            .max_buffers = max_buffers,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        // Free all buffers in free list
        var current = self.free_list;
        while (current) |node| {
            const next = node.next;
            self.allocator.free(node.buffer);
            self.allocator.destroy(node);
            current = next;
        }
    }

    /// Acquire a buffer from the pool
    pub fn acquire(self: *BufferPool) ![]u8 {
        // Try to get from free list first
        if (self.free_list) |node| {
            self.free_list = node.next;
            const buffer = node.buffer;
            self.allocator.destroy(node);
            return buffer;
        }

        // Allocate new buffer if under limit
        if (self.allocated_count < self.max_buffers) {
            self.allocated_count += 1;
            return try self.allocator.alloc(u8, self.buffer_size);
        }

        return error.BufferPoolExhausted;
    }

    /// Release a buffer back to the pool
    pub fn release(self: *BufferPool, buffer: []u8) !void {
        if (buffer.len != self.buffer_size) {
            return error.InvalidBufferSize;
        }

        const node = try self.allocator.create(BufferNode);
        node.* = .{
            .buffer = buffer,
            .next = self.free_list,
        };
        self.free_list = node;
    }
};

/// Zero-copy I/O operations for Linux
pub const ZeroCopyIO = struct {
    /// Splice data between file descriptors (Linux only)
    pub fn splice(fd_in: i32, fd_out: i32, len: usize) !usize {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedPlatform;
        }

        const flags = std.os.linux.SPLICE.F_MOVE | std.os.linux.SPLICE.F_MORE;
        return std.os.linux.splice(fd_in, null, fd_out, null, len, flags);
    }

    /// Send file using sendfile (Linux/BSD)
    pub fn sendFile(out_fd: i32, in_fd: i32, offset: ?*i64, count: usize) !usize {
        return posix.sendfile(out_fd, in_fd, offset orelse null, count);
    }

    /// Memory map a file for zero-copy access
    pub fn mmap(fd: i32, length: usize, offset: usize, writable: bool) ![]align(std.mem.page_size) u8 {
        const prot = if (writable)
            posix.PROT.READ | posix.PROT.WRITE
        else
            posix.PROT.READ;

        const flags = posix.MAP{ .TYPE = .SHARED };

        return try posix.mmap(
            null,
            length,
            prot,
            flags,
            fd,
            offset,
        );
    }

    /// Unmap memory
    pub fn munmap(memory: []align(std.mem.page_size) u8) void {
        posix.munmap(memory);
    }
};

/// Vectored I/O for scatter-gather operations
pub const VectoredIO = struct {
    /// Read into multiple buffers
    pub fn readv(fd: i32, iovecs: []const std.posix.iovec) !usize {
        return posix.readv(fd, iovecs);
    }

    /// Write from multiple buffers
    pub fn writev(fd: i32, iovecs: []const std.posix.iovec_const) !usize {
        return posix.writev(fd, iovecs);
    }

    /// Create iovec from buffer slice
    pub fn makeIovec(buffers: [][]u8) ![]std.posix.iovec {
        var iovecs = try std.heap.page_allocator.alloc(std.posix.iovec, buffers.len);
        for (buffers, 0..) |buf, i| {
            iovecs[i] = .{
                .base = buf.ptr,
                .len = buf.len,
            };
        }
        return iovecs;
    }
};

test "RingBuffer operations" {
    const allocator = std.testing.allocator;

    var ring = try RingBuffer.init(allocator, 1024);
    defer ring.deinit();

    // Test initial state
    try std.testing.expectEqual(@as(usize, 0), ring.availableRead());
    try std.testing.expectEqual(@as(usize, 1023), ring.availableWrite()); // -1 for full detection

    // Write some data
    const write_buf = ring.getWriteBuffer();
    @memcpy(write_buf[0..5], "hello");
    ring.commitWrite(5);

    try std.testing.expectEqual(@as(usize, 5), ring.availableRead());

    // Read the data
    const read_buf = ring.getReadBuffer();
    try std.testing.expectEqualStrings("hello", read_buf[0..5]);
    ring.commitRead(5);

    try std.testing.expectEqual(@as(usize, 0), ring.availableRead());
}

test "BufferPool operations" {
    const allocator = std.testing.allocator;

    var pool = BufferPool.init(allocator, 4096, 10);
    defer pool.deinit();

    // Acquire buffer
    const buf1 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 4096), buf1.len);

    // Release buffer
    try pool.release(buf1);

    // Acquire again should reuse
    const buf2 = try pool.acquire();
    try std.testing.expectEqual(buf1.ptr, buf2.ptr);

    // Clean up
    allocator.free(buf2);
}