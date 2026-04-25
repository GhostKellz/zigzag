const std = @import("std");
const builtin = @import("builtin");
const zigzag = @import("zigzag");

test "Windows IOCP smoke - user event" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var loop = try zigzag.EventLoop.init(std.testing.allocator, .{ .backend = .iocp });
    defer loop.deinit();

    if (loop.iocp_backend) |*backend| {
        backend.postUserEvent(321);
    } else {
        return error.BackendNotInitialized;
    }

    var events: [8]zigzag.Event = undefined;
    const count = try loop.poll(&events, 100);

    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(zigzag.EventType.user_event, events[0].type);
    try std.testing.expectEqual(@as(usize, 321), events[0].data.size);
}

test "Windows IOCP smoke - timer delivery" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var loop = try zigzag.EventLoop.init(std.testing.allocator, .{ .backend = .iocp });
    defer loop.deinit();

    const callback = struct {
        fn noop(_: ?*anyopaque) void {}
    }.noop;

    const timer = try loop.addTimer(25, callback);

    var events: [8]zigzag.Event = undefined;
    const count = try loop.poll(&events, 250);

    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(zigzag.EventType.timer_expired, events[0].type);
    try std.testing.expectEqual(timer.id, events[0].data.timer_id);
}

test "Windows IOCP smoke - public socket API unsupported off Windows only" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var loop = try zigzag.EventLoop.init(std.testing.allocator, .{ .backend = .iocp });
    defer loop.deinit();

    const invalid_socket: zigzag.SocketHandle = ~@as(zigzag.SocketHandle, 0);
    try std.testing.expectError(error.InvalidSocket, loop.addSocket(invalid_socket));
}
