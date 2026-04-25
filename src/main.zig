const std = @import("std");
const zigzag = @import("zigzag");

pub fn main() !void {
    // Initialize allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // Create event loop with auto-detected backend
    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    std.debug.print("ZigZag event loop initialized with backend: {}\n", .{loop.backend});
}

// Smoke tests for zigzag library
test "EventLoop init/deinit" {
    const allocator = std.testing.allocator;
    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();
    try std.testing.expect(!loop.should_stop);
}

test "Backend autodetection" {
    const backend = zigzag.Backend.autoDetect();
    // Should return a valid backend for the current platform
    switch (@import("builtin").os.tag) {
        .linux => try std.testing.expect(backend == .io_uring or backend == .epoll),
        .macos, .freebsd, .openbsd, .netbsd => try std.testing.expectEqual(zigzag.Backend.kqueue, backend),
        .windows => try std.testing.expectEqual(zigzag.Backend.iocp, backend),
        else => {},
    }
}

test "EventMask operations" {
    const mask = zigzag.EventMask{ .read = true, .write = false };
    try std.testing.expect(mask.any());
    try std.testing.expect(mask.read);
    try std.testing.expect(!mask.write);

    const empty = zigzag.EventMask{};
    try std.testing.expect(!empty.any());
}
