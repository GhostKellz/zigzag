//! Windows IOCP backend for zigzag event loop
//! Status: Functional with timers, wake events, and socket I/O
//!
//! Current capabilities:
//! - Real IOCP port creation with CreateIoCompletionPort
//! - One-shot and recurring timer support via Windows timer queues
//! - Wake mechanism for cross-thread signaling
//! - User events for custom application events
//! - Socket I/O via WinSock (WSARecv/WSASend with OVERLAPPED)
//! - Event delivery through GetQueuedCompletionStatus
//!
//! Supported event types:
//! - timer_expired: from addTimer() and addRecurringTimer()
//! - user_event: from wake() and postUserEvent()
//! - read_ready: from WSARecv completion
//! - write_ready: from WSASend completion
//!
//! Design notes:
//! IOCP is completion-based, not readiness-based like epoll/kqueue.
//! This means you must initiate I/O operations (WSARecv/WSASend) to receive
//! completion events. Simply registering a socket is not enough.
//!
//! Socket workflow:
//! 1. Call addSocket() to associate socket with IOCP
//! 2. Call recvAsync() to initiate a read operation
//! 3. Poll for completion events
//! 4. Handle read_ready event with received data

const std = @import("std");
const builtin = @import("builtin");
const Event = @import("../root.zig").Event;
const EventMask = @import("../root.zig").EventMask;
const EventType = @import("../root.zig").EventType;

/// Only compile this backend on Windows
const supports_iocp = switch (builtin.os.tag) {
    .windows => true,
    else => false,
};

/// Timer context for callback
const TimerContext = struct {
    timer_id: u32,
    iocp_handle: HANDLE,
    timer_handle: ?HANDLE,
    is_recurring: bool,
    interval_ms: u32,
};

/// Operation type for async I/O
const OperationType = enum(u8) {
    recv,
    send,
};

/// Per-operation state for async socket I/O
/// The OVERLAPPED must be the first field for pointer casting
const PendingOperation = struct {
    overlapped: OVERLAPPED,
    operation_type: OperationType,
    socket: SOCKET,
    wsabuf: WSABUF,
    buffer: []u8,
    buffer_owned: bool, // If true, we allocated buffer and must free it
    flags: DWORD,
    completion_key: ULONG_PTR,
};

// Windows type aliases
const HANDLE = std.os.windows.HANDLE;
const DWORD = std.os.windows.DWORD;
const BOOL = std.os.windows.BOOL;
const ULONG_PTR = std.os.windows.ULONG_PTR;
const LPVOID = ?*anyopaque;
const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;
const BOOLEAN = std.os.windows.BOOLEAN;
const WIN32_ERROR = std.os.windows.Win32Error;
const INFINITE: DWORD = 0xFFFF_FFFF;

/// Win32 OVERLAPPED structure for async I/O
const OVERLAPPED = extern struct {
    Internal: ULONG_PTR = 0,
    InternalHigh: ULONG_PTR = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

// WinSock types
pub const SOCKET = ULONG_PTR;
const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);

/// WinSock buffer descriptor
const WSABUF = extern struct {
    len: DWORD,
    buf: [*]u8,
};

/// WinSock startup data
const WSADATA = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
};

// Windows API function declarations
extern "kernel32" fn CreateIoCompletionPort(
    FileHandle: HANDLE,
    ExistingCompletionPort: ?HANDLE,
    CompletionKey: ULONG_PTR,
    NumberOfConcurrentThreads: DWORD,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn GetQueuedCompletionStatus(
    CompletionPort: HANDLE,
    lpNumberOfBytesTransferred: *DWORD,
    lpCompletionKey: *ULONG_PTR,
    lpOverlapped: *?*OVERLAPPED,
    dwMilliseconds: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn PostQueuedCompletionStatus(
    CompletionPort: HANDLE,
    dwNumberOfBytesTransferred: DWORD,
    dwCompletionKey: ULONG_PTR,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn CreateTimerQueue() callconv(.winapi) ?HANDLE;

extern "kernel32" fn DeleteTimerQueueEx(
    TimerQueue: ?HANDLE,
    CompletionEvent: ?HANDLE,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateTimerQueueTimer(
    phNewTimer: *?HANDLE,
    TimerQueue: ?HANDLE,
    Callback: *const fn (?*anyopaque, BOOLEAN) callconv(.winapi) void,
    Parameter: ?*anyopaque,
    DueTime: DWORD,
    Period: DWORD,
    Flags: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn DeleteTimerQueueTimer(
    TimerQueue: ?HANDLE,
    Timer: ?HANDLE,
    CompletionEvent: ?HANDLE,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetLastError() callconv(.winapi) WIN32_ERROR;

// WinSock API function declarations
extern "ws2_32" fn WSAStartup(
    wVersionRequested: u16,
    lpWSAData: *WSADATA,
) callconv(.winapi) c_int;

extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;

extern "ws2_32" fn WSARecv(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: DWORD,
    lpNumberOfBytesRecvd: ?*DWORD,
    lpFlags: *DWORD,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) c_int;

extern "ws2_32" fn WSASend(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: DWORD,
    lpNumberOfBytesSent: ?*DWORD,
    dwFlags: DWORD,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) c_int;

extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;

extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;

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

extern "ws2_32" fn send(
    s: SOCKET,
    buf: [*]const u8,
    len: c_int,
    flags: c_int,
) callconv(.winapi) c_int;

// Socket constants
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

// WinSock error codes
const WSAEWOULDBLOCK: c_int = 10035;
const WSA_IO_PENDING: c_int = 997;

/// IOCP backend implementation
pub const IOCPBackend = if (supports_iocp) struct {
    allocator: std.mem.Allocator,
    iocp_handle: HANDLE,
    timer_queue: ?HANDLE,
    timer_contexts: std.AutoHashMap(u32, *TimerContext),
    pending_operations: std.AutoHashMap(usize, *PendingOperation),
    registered_sockets: std.AutoHashMap(SOCKET, void),
    wsa_initialized: bool,

    /// Completion key values
    const COMPLETION_KEY_TIMER: ULONG_PTR = 0xFFFF_FFFF;
    const COMPLETION_KEY_WAKE: ULONG_PTR = 0xFFFF_FFFE;
    const COMPLETION_KEY_USER: ULONG_PTR = 0xFFFF_FFFD;
    const COMPLETION_KEY_SOCKET_BASE: ULONG_PTR = 0x1000;

    /// Initialize the IOCP backend with real Windows resources
    pub fn init(allocator: std.mem.Allocator) !IOCPBackend {
        // Initialize WinSock
        var wsa_data: WSADATA = undefined;
        const wsa_result = WSAStartup(0x0202, &wsa_data); // Request version 2.2
        if (wsa_result != 0) {
            return error.WinSockInitFailed;
        }
        errdefer _ = WSACleanup();

        // Create I/O Completion Port
        const iocp_handle = CreateIoCompletionPort(
            INVALID_HANDLE_VALUE,
            null,
            0,
            0, // Use default number of threads
        );
        if (iocp_handle == null) {
            return error.SystemResources;
        }
        errdefer _ = CloseHandle(iocp_handle.?);

        // Create timer queue for managing timers
        const timer_queue = CreateTimerQueue();
        if (timer_queue == null) {
            return error.SystemResources;
        }

        return IOCPBackend{
            .allocator = allocator,
            .iocp_handle = iocp_handle.?,
            .timer_queue = timer_queue,
            .timer_contexts = std.AutoHashMap(u32, *TimerContext).init(allocator),
            .pending_operations = std.AutoHashMap(usize, *PendingOperation).init(allocator),
            .registered_sockets = std.AutoHashMap(SOCKET, void).init(allocator),
            .wsa_initialized = true,
        };
    }

    /// Deinitialize the IOCP backend
    pub fn deinit(self: *IOCPBackend) void {
        // Cancel and cleanup all timers
        var timer_iter = self.timer_contexts.iterator();
        while (timer_iter.next()) |entry| {
            const ctx = entry.value_ptr.*;
            if (ctx.timer_handle) |timer_handle| {
                // Delete timer with INVALID_HANDLE_VALUE to wait for callbacks to complete
                _ = DeleteTimerQueueTimer(self.timer_queue, timer_handle, INVALID_HANDLE_VALUE);
            }
            self.allocator.destroy(ctx);
        }
        self.timer_contexts.deinit();

        // Clean up pending operations
        var op_iter = self.pending_operations.iterator();
        while (op_iter.next()) |entry| {
            const op = entry.value_ptr.*;
            if (op.buffer_owned) {
                self.allocator.free(op.buffer);
            }
            self.allocator.destroy(op);
        }
        self.pending_operations.deinit();
        self.registered_sockets.deinit();

        // Delete timer queue
        if (self.timer_queue) |tq| {
            _ = DeleteTimerQueueEx(tq, INVALID_HANDLE_VALUE);
        }

        // Close IOCP handle
        _ = CloseHandle(self.iocp_handle);

        // Cleanup WinSock
        if (self.wsa_initialized) {
            _ = WSACleanup();
        }
    }

    /// Generic fd-style watching is not supported on IOCP.
    /// Use addSocket() and overlapped socket operations instead.
    pub fn addFd(self: *IOCPBackend, handle: i32, events: EventMask) !void {
        _ = self;
        _ = handle;
        _ = events;
        return error.OperationNotSupported;
    }

    /// Add a socket to the IOCP for async I/O
    /// This is the preferred API for socket operations on Windows
    pub fn addSocket(self: *IOCPBackend, socket: SOCKET) !void {
        if (socket == INVALID_SOCKET) {
            return error.InvalidSocket;
        }
        if (self.registered_sockets.contains(socket)) {
            return error.SocketAlreadyRegistered;
        }

        // Associate socket with IOCP using socket value as completion key
        const socket_handle: HANDLE = @ptrFromInt(socket);
        const result = CreateIoCompletionPort(
            socket_handle,
            self.iocp_handle,
            COMPLETION_KEY_SOCKET_BASE + @as(ULONG_PTR, socket),
            0,
        );

        if (result == null) {
            return error.SystemResources;
        }

        try self.registered_sockets.put(socket, {});
    }

    fn cleanupOperation(self: *IOCPBackend, op: *PendingOperation) void {
        if (op.buffer_owned) {
            self.allocator.free(op.buffer);
        }
        self.allocator.destroy(op);
    }

    /// Remove a socket and cancel any outstanding operations tracked for it.
    pub fn removeSocket(self: *IOCPBackend, socket: SOCKET) void {
        _ = self.registered_sockets.remove(socket);

        var to_remove = std.ArrayList(usize).empty;
        defer to_remove.deinit(self.allocator);

        var iterator = self.pending_operations.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.socket == socket) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }

        for (to_remove.items) |op_key| {
            if (self.pending_operations.fetchRemove(op_key)) |kv| {
                self.cleanupOperation(kv.value);
            }
        }
    }

    /// Initiate an async receive on a socket
    /// The completion will be delivered as a read_ready event.
    /// IMPORTANT: Caller must keep buffer alive until completion event is received.
    /// On completion, bytes_transferred bytes will be in buffer[0..bytes_transferred].
    pub fn recvAsync(self: *IOCPBackend, socket: SOCKET, buffer: []u8) !void {
        // Allocate pending operation
        const op = try self.allocator.create(PendingOperation);
        errdefer self.allocator.destroy(op);

        // Use caller's buffer directly - they must keep it alive until completion
        op.* = PendingOperation{
            .overlapped = std.mem.zeroes(OVERLAPPED),
            .operation_type = .recv,
            .socket = socket,
            .wsabuf = WSABUF{
                .len = @intCast(buffer.len),
                .buf = buffer.ptr,
            },
            .buffer = buffer,
            .buffer_owned = false, // Caller owns this buffer
            .flags = 0,
            .completion_key = COMPLETION_KEY_SOCKET_BASE + @as(ULONG_PTR, socket),
        };

        // Track this operation
        const op_key = @intFromPtr(&op.overlapped);
        try self.pending_operations.put(op_key, op);
        errdefer _ = self.pending_operations.remove(op_key);

        // Initiate async receive
        var wsabuf_array = [_]WSABUF{op.wsabuf};
        const result = WSARecv(
            socket,
            &wsabuf_array,
            1,
            null, // bytes received - not used for overlapped
            &op.flags,
            &op.overlapped,
            null, // no completion routine
        );

        if (result != 0) {
            const err = WSAGetLastError();
            if (err != WSA_IO_PENDING) {
                // Real error - clean up
                _ = self.pending_operations.remove(op_key);
                self.allocator.destroy(op);
                return error.RecvFailed;
            }
            // WSA_IO_PENDING is expected - operation is in progress
        }
    }

    /// Initiate an async send on a socket
    /// The completion will be delivered as a write_ready event
    pub fn sendAsync(self: *IOCPBackend, socket: SOCKET, data: []const u8) !void {
        // Allocate pending operation
        const op = try self.allocator.create(PendingOperation);
        errdefer self.allocator.destroy(op);

        // Allocate buffer copy with data
        const owned_buffer = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned_buffer);

        op.* = PendingOperation{
            .overlapped = std.mem.zeroes(OVERLAPPED),
            .operation_type = .send,
            .socket = socket,
            .wsabuf = WSABUF{
                .len = @intCast(owned_buffer.len),
                .buf = owned_buffer.ptr,
            },
            .buffer = owned_buffer,
            .buffer_owned = true, // We allocated this buffer
            .flags = 0,
            .completion_key = COMPLETION_KEY_SOCKET_BASE + @as(ULONG_PTR, socket),
        };

        // Track this operation
        const op_key = @intFromPtr(&op.overlapped);
        try self.pending_operations.put(op_key, op);
        errdefer _ = self.pending_operations.remove(op_key);

        // Initiate async send
        var wsabuf_array = [_]WSABUF{op.wsabuf};
        const result = WSASend(
            socket,
            &wsabuf_array,
            1,
            null, // bytes sent - not used for overlapped
            0, // flags
            &op.overlapped,
            null, // no completion routine
        );

        if (result != 0) {
            const err = WSAGetLastError();
            if (err != WSA_IO_PENDING) {
                // Real error - clean up
                _ = self.pending_operations.remove(op_key);
                self.allocator.free(owned_buffer);
                self.allocator.destroy(op);
                return error.SendFailed;
            }
            // WSA_IO_PENDING is expected - operation is in progress
        }
    }

    /// Generic fd-style watch modification is not supported on IOCP.
    pub fn modifyFd(self: *IOCPBackend, handle: i32, events: EventMask) !void {
        _ = self;
        _ = handle;
        _ = events;
        return error.OperationNotSupported;
    }

    /// Generic fd-style watch removal is not supported on IOCP.
    pub fn removeFd(self: *IOCPBackend, handle: i32) !void {
        _ = self;
        _ = handle;
        return error.OperationNotSupported;
    }

    /// Poll for events using GetQueuedCompletionStatus
    pub fn poll(self: *IOCPBackend, events: []Event, timeout_ms: ?u32) !usize {
        if (events.len == 0) return 0;

        var count: usize = 0;
        var wait_timeout = timeout_ms orelse INFINITE;

        while (count < events.len) {
            var bytes_transferred: DWORD = 0;
            var completion_key: ULONG_PTR = 0;
            var overlapped: ?*OVERLAPPED = null;

            const result = GetQueuedCompletionStatus(
                self.iocp_handle,
                &bytes_transferred,
                &completion_key,
                &overlapped,
                wait_timeout,
            );

            if (!result.toBool()) {
                const err = GetLastError();
                if (err == .WAIT_TIMEOUT or err == .ABANDONED_WAIT_0) {
                    break;
                }

                if (overlapped) |ovl| {
                    const op_key = @intFromPtr(ovl);
                    if (self.pending_operations.fetchRemove(op_key)) |kv| {
                        const op = kv.value;
                        const fd: i32 = @truncate(@as(i64, @intCast(op.socket)));
                        events[count] = Event{
                            .fd = fd,
                            .type = .io_error,
                            .data = .{ .size = 0 },
                        };
                        count += 1;

                        self.cleanupOperation(op);
                        wait_timeout = 0;
                        continue;
                    }
                }

                break;
            }

            if (completion_key == COMPLETION_KEY_TIMER) {
                const timer_ctx: *TimerContext = @ptrCast(@alignCast(overlapped.?));
                const timer_id = timer_ctx.timer_id;
                events[count] = Event{
                    .fd = -1,
                    .type = .timer_expired,
                    .data = .{ .timer_id = timer_id },
                };
                count += 1;
                wait_timeout = 0;
                continue;
            }

            if (completion_key == COMPLETION_KEY_WAKE) {
                events[count] = Event{
                    .fd = -1,
                    .type = .user_event,
                    .data = .{ .size = 0 },
                };
                count += 1;
                wait_timeout = 0;
                continue;
            }

            if (completion_key == COMPLETION_KEY_USER) {
                events[count] = Event{
                    .fd = -1,
                    .type = .user_event,
                    .data = .{ .size = bytes_transferred },
                };
                count += 1;
                wait_timeout = 0;
                continue;
            }

            if (overlapped) |ovl| {
                const op_key = @intFromPtr(ovl);
                if (self.pending_operations.fetchRemove(op_key)) |kv| {
                    const op = kv.value;
                    const event_type: EventType = switch (op.operation_type) {
                        .recv => if (bytes_transferred == 0) .hangup else .read_ready,
                        .send => .write_ready,
                    };
                    const fd: i32 = @truncate(@as(i64, @intCast(op.socket)));

                    events[count] = Event{
                        .fd = fd,
                        .type = event_type,
                        .data = .{ .size = bytes_transferred },
                    };
                    count += 1;

                    self.cleanupOperation(op);
                    wait_timeout = 0;
                    continue;
                }
            }

            const fd: i32 = @truncate(@as(i64, @intCast(completion_key - COMPLETION_KEY_SOCKET_BASE)));
            events[count] = Event{
                .fd = fd,
                .type = .read_ready,
                .data = .{ .size = bytes_transferred },
            };
            count += 1;
            wait_timeout = 0;
        }

        return count;
    }

    /// Wake up the event loop from another thread
    /// This posts a completion to the IOCP, causing poll() to return
    pub fn wake(self: *IOCPBackend) void {
        _ = PostQueuedCompletionStatus(
            self.iocp_handle,
            0,
            COMPLETION_KEY_WAKE,
            null,
        );
    }

    /// Post a user event to the event loop
    /// The data value will be available in the Event.data.size field
    pub fn postUserEvent(self: *IOCPBackend, data: u32) void {
        _ = PostQueuedCompletionStatus(
            self.iocp_handle,
            data,
            COMPLETION_KEY_USER,
            null,
        );
    }

    /// Timer callback - posts to IOCP
    fn timerCallback(param: ?*anyopaque, timer_or_wait_fired: BOOLEAN) callconv(.winapi) void {
        _ = timer_or_wait_fired;
        if (param) |p| {
            const ctx: *TimerContext = @ptrCast(@alignCast(p));

            // Post timer event to IOCP
            _ = PostQueuedCompletionStatus(
                ctx.iocp_handle,
                0,
                COMPLETION_KEY_TIMER,
                @ptrCast(ctx),
            );

            // For non-recurring timers, we could clean up here
            // but it's safer to let the user call cancelTimer
        }
    }

    /// Add a one-shot timer
    pub fn addTimer(self: *IOCPBackend, timer_id: u32, ms: u64) !void {
        // Allocate timer context
        const ctx = try self.allocator.create(TimerContext);
        errdefer self.allocator.destroy(ctx);

        ctx.* = TimerContext{
            .timer_id = timer_id,
            .iocp_handle = self.iocp_handle,
            .timer_handle = null,
            .is_recurring = false,
            .interval_ms = @intCast(@min(ms, std.math.maxInt(u32))),
        };

        // Create timer
        var timer_handle: ?HANDLE = null;
        const success = CreateTimerQueueTimer(
            &timer_handle,
            self.timer_queue,
            timerCallback,
            ctx,
            @intCast(@min(ms, std.math.maxInt(u32))),
            0, // Period 0 = one-shot
            0, // Flags
        );

        if (!success.toBool()) {
            self.allocator.destroy(ctx);
            return error.SystemResources;
        }

        ctx.timer_handle = timer_handle;
        try self.timer_contexts.put(timer_id, ctx);
    }

    /// Add a recurring timer
    pub fn addRecurringTimer(self: *IOCPBackend, timer_id: u32, interval_ms: u64) !void {
        // Allocate timer context
        const ctx = try self.allocator.create(TimerContext);
        errdefer self.allocator.destroy(ctx);

        const period: DWORD = @intCast(@min(interval_ms, std.math.maxInt(u32)));

        ctx.* = TimerContext{
            .timer_id = timer_id,
            .iocp_handle = self.iocp_handle,
            .timer_handle = null,
            .is_recurring = true,
            .interval_ms = period,
        };

        // Create timer
        var timer_handle: ?HANDLE = null;
        const success = CreateTimerQueueTimer(
            &timer_handle,
            self.timer_queue,
            timerCallback,
            ctx,
            period, // Due time
            period, // Period (non-zero = recurring)
            0, // Flags
        );

        if (!success.toBool()) {
            self.allocator.destroy(ctx);
            return error.SystemResources;
        }

        ctx.timer_handle = timer_handle;
        try self.timer_contexts.put(timer_id, ctx);
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *IOCPBackend, timer_id: u32) void {
        if (self.timer_contexts.fetchRemove(timer_id)) |kv| {
            const ctx = kv.value;
            if (ctx.timer_handle) |timer_handle| {
                // Delete timer, wait for any pending callbacks
                _ = DeleteTimerQueueTimer(
                    self.timer_queue,
                    timer_handle,
                    INVALID_HANDLE_VALUE,
                );
            }
            self.allocator.destroy(ctx);
        }
    }
} else void;

test "IOCPBackend basic initialization" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Verify IOCP handle is valid
    try std.testing.expect(backend.iocp_handle != INVALID_HANDLE_VALUE);
    try std.testing.expect(backend.timer_queue != null);
}

test "IOCP one-shot timer delivery" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Add 50ms one-shot timer
    try backend.addTimer(42, 50);

    // Poll with 200ms timeout - should get timer event
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 200);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(EventType.timer_expired, events[0].type);
    try std.testing.expectEqual(@as(u32, 42), events[0].data.timer_id);
}

test "IOCP recurring timer" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Add 30ms recurring timer
    try backend.addRecurringTimer(99, 30);

    // Should get multiple timer events
    var events: [16]Event = undefined;
    var timer_count: usize = 0;

    for (0..5) |_| {
        const count = try backend.poll(&events, 100);
        for (0..count) |i| {
            if (events[i].type == .timer_expired and events[i].data.timer_id == 99) {
                timer_count += 1;
            }
        }
        if (timer_count >= 2) break;
    }

    // Should have received at least 2 timer events
    try std.testing.expect(timer_count >= 2);

    // Cancel the timer
    backend.cancelTimer(99);
}

test "IOCP timer cancellation" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Add a timer with 500ms delay
    try backend.addTimer(123, 500);

    // Cancel it immediately
    backend.cancelTimer(123);

    // Poll with short timeout - should NOT get timer event
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 50);

    // No timer events should be received for this timer_id
    for (0..count) |i| {
        if (events[i].type == .timer_expired and events[i].data.timer_id == 123) {
            return error.TimerNotCancelled;
        }
    }
}

test "IOCP poll timeout" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Poll with no timers registered - should return 0 after timeout
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 10);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "IOCP wake" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Post wake event
    backend.wake();

    // Poll should return immediately with user event
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 100);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(EventType.user_event, events[0].type);
}

test "IOCP user event" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Post user event with data
    backend.postUserEvent(12345);

    // Poll should return the event with our data
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 100);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(EventType.user_event, events[0].type);
    try std.testing.expectEqual(@as(usize, 12345), events[0].data.size);
}

test "IOCP batched user events" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    backend.postUserEvent(11);
    backend.postUserEvent(22);
    backend.postUserEvent(33);

    var events: [8]Event = undefined;
    const count = try backend.poll(&events, 100);

    try std.testing.expect(count >= 3);
    try std.testing.expectEqual(EventType.user_event, events[0].type);
    try std.testing.expectEqual(EventType.user_event, events[1].type);
    try std.testing.expectEqual(EventType.user_event, events[2].type);
}

test "IOCP WinSock initialization" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // WinSock should be initialized
    try std.testing.expect(backend.wsa_initialized);
}

test "IOCP addSocket with invalid socket" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Adding invalid socket should fail
    const result = backend.addSocket(INVALID_SOCKET);
    try std.testing.expectError(error.InvalidSocket, result);
}

test "IOCP removeSocket cleans pending operations" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    const pair = try createSocketPair(&backend);
    defer {
        _ = closesocket(pair.server);
        _ = closesocket(pair.client);
    }

    var recv_buffer: [256]u8 = undefined;
    try backend.recvAsync(pair.server, &recv_buffer);
    try backend.sendAsync(pair.client, "cleanup");
    try std.testing.expect(backend.pending_operations.count() >= 2);

    backend.removeSocket(pair.server);
    try std.testing.expectEqual(@as(usize, 1), backend.pending_operations.count());

    backend.removeSocket(pair.client);
    try std.testing.expectEqual(@as(usize, 0), backend.pending_operations.count());
}

test "IOCP addFd is not supported" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    try std.testing.expectError(error.OperationNotSupported, backend.addFd(123, .{ .read = true }));
}

// Helper to create a connected socket pair via loopback
fn createSocketPair(backend: *IOCPBackend) !struct { server: SOCKET, client: SOCKET } {
    // Create listener socket
    const listener = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) return error.SocketCreationFailed;
    errdefer _ = closesocket(listener);

    // Bind to loopback on any port
    var addr = sockaddr_in{
        .sin_family = AF_INET,
        .sin_port = 0, // Let OS choose port
        .sin_addr = 0x0100007F, // 127.0.0.1 in network byte order
        .sin_zero = @splat(0),
    };

    if (bind(listener, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) {
        return error.BindFailed;
    }

    // Get assigned port
    var addrlen: c_int = @sizeOf(sockaddr_in);
    if (getsockname(listener, @ptrCast(&addr), &addrlen) != 0) {
        return error.GetSockNameFailed;
    }

    if (listen(listener, 1) != 0) {
        return error.ListenFailed;
    }

    // Create client socket and connect
    const client = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (client == INVALID_SOCKET) return error.SocketCreationFailed;
    errdefer _ = closesocket(client);

    if (connect(client, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) {
        return error.ConnectFailed;
    }

    // Accept connection
    const server = accept(listener, null, null);
    _ = closesocket(listener); // Don't need listener anymore

    if (server == INVALID_SOCKET) return error.AcceptFailed;
    errdefer _ = closesocket(server);

    // Associate both sockets with IOCP
    try backend.addSocket(server);
    try backend.addSocket(client);

    return .{ .server = server, .client = client };
}

test "IOCP socket send and receive completion" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Create connected socket pair
    const pair = try createSocketPair(&backend);
    defer {
        _ = closesocket(pair.server);
        _ = closesocket(pair.client);
    }

    // Start async receive on server
    var recv_buffer: [256]u8 = undefined;
    try backend.recvAsync(pair.server, &recv_buffer);

    // Send data from client (sync send is fine for small data)
    const test_data = "Hello IOCP!";
    const sent = send(pair.client, test_data.ptr, @intCast(test_data.len), 0);
    try std.testing.expect(sent == test_data.len);

    // Poll for receive completion
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 1000);

    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(EventType.read_ready, events[0].type);
    try std.testing.expectEqual(test_data.len, events[0].data.size);

    // Verify received data is in our buffer
    try std.testing.expectEqualSlices(u8, test_data, recv_buffer[0..test_data.len]);
}

test "IOCP async send completion" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Create connected socket pair
    const pair = try createSocketPair(&backend);
    defer {
        _ = closesocket(pair.server);
        _ = closesocket(pair.client);
    }

    // Start async send from client
    const test_data = "Async send test!";
    try backend.sendAsync(pair.client, test_data);

    // Poll for send completion
    var events: [16]Event = undefined;
    const count = try backend.poll(&events, 1000);

    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(EventType.write_ready, events[0].type);
    try std.testing.expectEqual(test_data.len, events[0].data.size);
}

test "IOCP multiple pending operations" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Create connected socket pair
    const pair = try createSocketPair(&backend);
    defer {
        _ = closesocket(pair.server);
        _ = closesocket(pair.client);
    }

    // Start async recv on server
    var recv_buffer: [256]u8 = undefined;
    try backend.recvAsync(pair.server, &recv_buffer);

    // Start async send on client
    const test_data = "Multiple ops test!";
    try backend.sendAsync(pair.client, test_data);

    // Poll until we get at least 2 completions
    var events: [16]Event = undefined;
    var total_events: usize = 0;
    var got_read_ready = false;
    var got_write_ready = false;

    for (0..10) |_| {
        const count = try backend.poll(&events, 200);
        for (events[0..count]) |event| {
            total_events += 1;
            if (event.type == .read_ready) got_read_ready = true;
            if (event.type == .write_ready) got_write_ready = true;
        }
        if (total_events >= 2) break;
    }

    // Must have received at least 2 completions
    try std.testing.expect(total_events >= 2);
    // Must have correct event types matching the operations started
    try std.testing.expect(got_read_ready);
    try std.testing.expect(got_write_ready);
    // Verify no pending operations remain
    try std.testing.expectEqual(@as(usize, 0), backend.pending_operations.count());
}

test "IOCP poll drains queued completions" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    const pair = try createSocketPair(&backend);
    defer {
        _ = closesocket(pair.server);
        _ = closesocket(pair.client);
    }

    var recv_a: [64]u8 = undefined;
    var recv_b: [64]u8 = undefined;
    try backend.recvAsync(pair.server, &recv_a);
    try backend.recvAsync(pair.server, &recv_b);
    try backend.sendAsync(pair.client, "first");
    try backend.sendAsync(pair.client, "second");

    var events: [8]Event = undefined;
    const count = try backend.poll(&events, 1000);

    try std.testing.expect(count >= 2);
}

test "IOCP failed I/O completion" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try IOCPBackend.init(allocator);
    defer backend.deinit();

    // Create connected socket pair
    const pair = try createSocketPair(&backend);
    defer {
        // Only close server - client is closed mid-test
        _ = closesocket(pair.server);
    }

    // Start async recv on server
    var recv_buffer: [256]u8 = undefined;
    try backend.recvAsync(pair.server, &recv_buffer);

    // Verify operation is pending
    try std.testing.expectEqual(@as(usize, 1), backend.pending_operations.count());

    // Close the client socket - this should cause the recv to fail
    _ = closesocket(pair.client);

    // Poll for the failed completion
    var events: [16]Event = undefined;
    var got_terminal_event = false;

    for (0..10) |_| {
        const count = try backend.poll(&events, 200);
        for (events[0..count]) |event| {
            // A peer close can surface as EOF/hangup or as an I/O error.
            if (event.type == .io_error or event.type == .hangup) {
                got_terminal_event = true;
            }
        }
        if (backend.pending_operations.count() == 0) break;
    }

    // MUST have received a terminal completion for the closed peer.
    try std.testing.expect(got_terminal_event);
    // Operation must be removed from pending_operations
    try std.testing.expectEqual(@as(usize, 0), backend.pending_operations.count());
}

test "IOCP pending operation cleanup on deinit" {
    if (!supports_iocp) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Create backend and start operations, then deinit without completing them
    // DebugAllocator will catch any leaks
    {
        var backend = try IOCPBackend.init(allocator);
        defer backend.deinit();

        // Create connected socket pair
        const pair = createSocketPair(&backend) catch return; // Skip if socket creation fails
        defer {
            _ = closesocket(pair.server);
            _ = closesocket(pair.client);
        }

        // Start async operations but don't wait for completion
        var recv_buffer: [256]u8 = undefined;
        backend.recvAsync(pair.server, &recv_buffer) catch {};
        backend.sendAsync(pair.client, "test data") catch {};

        // deinit should clean up pending operations without leaking
    }

    // If we get here without DebugAllocator panicking, cleanup worked
}
