const std = @import("std");
const builtin = @import("builtin");
const zigzag = @import("zigzag");

const io = std.testing.io;

const CaptureState = struct {
    allocator: std.mem.Allocator,
    events: std.array_list.Managed(zigzag.file_watching.FileEventNotification),

    fn init(allocator: std.mem.Allocator) CaptureState {
        return .{
            .allocator = allocator,
            .events = std.array_list.Managed(zigzag.file_watching.FileEventNotification).init(allocator),
        };
    }

    fn deinit(self: *CaptureState) void {
        for (self.events.items) |event| {
            self.allocator.free(event.path);
            if (event.old_path) |old_path| self.allocator.free(old_path);
        }
        self.events.deinit();
    }

    fn clear(self: *CaptureState) void {
        for (self.events.items) |event| {
            self.allocator.free(event.path);
            if (event.old_path) |old_path| self.allocator.free(old_path);
        }
        self.events.clearRetainingCapacity();
    }
};

threadlocal var capture_state: ?*CaptureState = null;

fn captureEvent(notification: zigzag.file_watching.FileEventNotification) void {
    const state = capture_state orelse return;
    const path_copy = state.allocator.dupe(u8, notification.path) catch return;
    errdefer state.allocator.free(path_copy);
    const old_path_copy = if (notification.old_path) |old_path|
        state.allocator.dupe(u8, old_path) catch return
    else
        null;
    errdefer if (old_path_copy) |old_path| state.allocator.free(old_path);

    state.events.append(.{
        .event_type = notification.event_type,
        .path = path_copy,
        .old_path = old_path_copy,
        .timestamp = notification.timestamp,
        .cookie = notification.cookie,
    }) catch {
        state.allocator.free(path_copy);
        if (old_path_copy) |old_path| state.allocator.free(old_path);
    };
}

fn tmpRootPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
}

test "Windows stress - wake flooding drains queued user events" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var loop = try zigzag.EventLoop.init(allocator, .{ .backend = .iocp });
    defer loop.deinit();

    const total_events: usize = 128;
    if (loop.iocp_backend) |*backend| {
        for (0..total_events) |i| {
            backend.postUserEvent(@intCast(i + 1));
        }
    } else {
        return error.BackendNotInitialized;
    }

    var events: [32]zigzag.Event = undefined;
    var received: usize = 0;
    var attempts: usize = 0;
    while (received < total_events and attempts < 16) : (attempts += 1) {
        const count = try loop.poll(&events, 100);
        for (events[0..count]) |event| {
            if (event.type == .user_event) received += 1;
        }
    }

    try std.testing.expectEqual(total_events, received);
}

test "Windows stress - recurring timer churn" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var loop = try zigzag.EventLoop.init(allocator, .{ .backend = .iocp });
    defer loop.deinit();

    const callback = struct {
        fn noop(_: ?*anyopaque) void {}
    }.noop;

    var timers: [32]zigzag.Timer = undefined;
    for (&timers, 0..) |*timer, i| {
        timer.* = try loop.addRecurringTimer(10 + i, callback);
    }

    var events: [64]zigzag.Event = undefined;
    var timer_events: usize = 0;
    var attempts: usize = 0;
    while (timer_events < 16 and attempts < 20) : (attempts += 1) {
        const count = try loop.poll(&events, 100);
        for (events[0..count]) |event| {
            if (event.type == .timer_expired) timer_events += 1;
        }
    }

    for (&timers) |*timer| loop.cancelTimer(timer);
    try std.testing.expect(timer_events >= 16);
}

test "Windows stress - mixed socket timer and filewatch load" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var loop = try zigzag.EventLoop.init(allocator, .{ .backend = .iocp });
    defer loop.deinit();

    const callback = struct {
        fn noop(_: ?*anyopaque) void {}
    }.noop;

    var watcher = try zigzag.FileWatcher.init(allocator, &loop);
    defer watcher.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpRootPath(allocator, &tmp);
    defer allocator.free(dir_path);

    var watch_state = CaptureState.init(allocator);
    defer watch_state.deinit();
    capture_state = &watch_state;
    defer capture_state = null;
    watcher.setCallback(captureEvent);

    try watcher.addWatch(dir_path, .{});
    defer watcher.removeWatch(dir_path) catch {};

    const timer = try loop.addRecurringTimer(15, callback);
    defer loop.cancelTimer(&timer);

    if (loop.iocp_backend == null) return error.BackendNotInitialized;
    const pair = try createSocketPair(&loop);
    defer {
        _ = closesocket(pair.server);
        _ = closesocket(pair.client);
    }

    var recv_buffers: [4][64]u8 = undefined;
    for (&recv_buffers) |*buffer| {
        try loop.recvSocket(pair.server, buffer);
    }

    for (0..4) |i| {
        try loop.sendSocket(pair.client, if (i % 2 == 0) "alpha" else "beta");
    }

    for (0..4) |i| {
        const file_name = try std.fmt.allocPrint(allocator, "file-{d}.txt", .{i});
        defer allocator.free(file_name);
        try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "change" });
    }

    var io_events: [64]zigzag.Event = undefined;
    var timer_events: usize = 0;
    var read_ready_events: usize = 0;
    var file_events: usize = 0;

    var attempts: usize = 0;
    while ((timer_events == 0 or read_ready_events < 4 or file_events < 4) and attempts < 25) : (attempts += 1) {
        const count = try loop.poll(&io_events, 50);
        for (io_events[0..count]) |event| {
            switch (event.type) {
                .timer_expired => timer_events += 1,
                .read_ready => read_ready_events += 1,
                else => {},
            }
        }
        try watcher.processEvents();
        file_events = watch_state.events.items.len;
    }

    try std.testing.expect(timer_events > 0);
    try std.testing.expect(read_ready_events >= 4);
    try std.testing.expect(file_events >= 4);
}

const SOCKET = @import("zigzag").SocketHandle;

const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;

const sockaddr = extern struct {
    sa_family: u16,
    sa_data: [14]u8,
};

const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8,
};

const ws2_socket = @extern(*const fn (
    af: c_int,
    socket_type: c_int,
    protocol: c_int,
) callconv(.winapi) SOCKET, .{
    .name = "socket",
    .library_name = "ws2_32",
});

extern "ws2_32" fn bind(
    s: SOCKET,
    name: *const sockaddr,
    namelen: c_int,
) callconv(.winapi) c_int;

extern "ws2_32" fn listen(
    s: SOCKET,
    backlog: c_int,
) callconv(.winapi) c_int;

extern "ws2_32" fn accept(
    s: SOCKET,
    addr: ?*sockaddr,
    addrlen: ?*c_int,
) callconv(.winapi) SOCKET;

extern "ws2_32" fn connect(
    s: SOCKET,
    name: *const sockaddr,
    namelen: c_int,
) callconv(.winapi) c_int;

extern "ws2_32" fn getsockname(
    s: SOCKET,
    name: *sockaddr,
    namelen: *c_int,
) callconv(.winapi) c_int;

extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;

fn createSocketPair(loop: *zigzag.EventLoop) !struct { server: SOCKET, client: SOCKET } {
    const listener = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) return error.SocketCreationFailed;
    errdefer _ = closesocket(listener);

    var addr = sockaddr_in{
        .sin_family = AF_INET,
        .sin_port = 0,
        .sin_addr = 0x0100007F,
        .sin_zero = [_]u8{0} ** 8,
    };

    if (bind(listener, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) {
        return error.BindFailed;
    }

    var addrlen: c_int = @sizeOf(sockaddr_in);
    if (getsockname(listener, @ptrCast(&addr), &addrlen) != 0) {
        return error.GetSockNameFailed;
    }

    if (listen(listener, 1) != 0) {
        return error.ListenFailed;
    }

    const client = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (client == INVALID_SOCKET) return error.SocketCreationFailed;
    errdefer _ = closesocket(client);

    if (connect(client, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) {
        return error.ConnectFailed;
    }

    const server = accept(listener, null, null);
    _ = closesocket(listener);

    if (server == INVALID_SOCKET) return error.AcceptFailed;
    errdefer _ = closesocket(server);

    try loop.addSocket(server);
    try loop.addSocket(client);

    return .{ .server = server, .client = client };
}
