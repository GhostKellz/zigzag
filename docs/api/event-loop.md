# EventLoop

The main event loop structure. Manages file descriptor watches, timers, and event dispatching.

## Creation

### init

```zig
pub fn init(allocator: std.mem.Allocator, options: Options) !EventLoop
```

Create a new event loop.

**Parameters:**
- `allocator` - Memory allocator for internal data structures
- `options` - Configuration options (see [Options](options.md))

**Returns:** Initialized EventLoop or error

**Errors:**
- `error.BackendNotInitialized` - Backend failed to initialize
- System errors from backend initialization

**Example:**
```zig
var loop = try zigzag.EventLoop.init(allocator, .{});
defer loop.deinit();
```

### deinit

```zig
pub fn deinit(self: *EventLoop) void
```

Clean up the event loop. Releases all resources including watches, timers, and backend resources.

---

## Event Loop Control

### run

```zig
pub fn run(self: *EventLoop) !void
```

Run the event loop until `stop()` is called. Continuously calls `tick()` and sleeps 1ms when no events are pending.

### tick

```zig
pub fn tick(self: *EventLoop) !bool
```

Process one iteration of the event loop. Non-blocking.

**Returns:** `true` if events were processed, `false` otherwise.

### stop

```zig
pub fn stop(self: *EventLoop) void
```

Signal the event loop to stop. The loop will exit after the current iteration.

### reset

```zig
pub fn reset(self: *EventLoop) void
```

Reset the stop flag, allowing `run()` to be called again.

---

## Polling

### poll

```zig
pub fn poll(self: *EventLoop, events: []Event, timeout_ms: ?u32) !usize
```

Poll for events with optional timeout.

**Parameters:**
- `events` - Buffer to store received events
- `timeout_ms` - Timeout in milliseconds, or `null` for infinite wait

**Returns:** Number of events received

**Example:**
```zig
var events: [64]zigzag.Event = undefined;
const count = try loop.poll(&events, 100); // 100ms timeout
for (events[0..count]) |event| {
    // Process event
}
```

---

## File Descriptor Watching

Platform note:
- `addFd()` is the readiness-style watch API used on Linux and BSD/macOS.
- On Windows IOCP, `addFd()` returns `error.OperationNotSupported`.
- Windows socket I/O is exposed through the completion-based socket methods described below.

### addFd

```zig
pub fn addFd(self: *EventLoop, fd: i32, events: EventMask) !*const Watch
```

Add a file descriptor to watch.

**Parameters:**
- `fd` - File descriptor to watch
- `events` - Events to monitor (see [EventMask](events.md#eventmask))

**Returns:** Stable watch handle owned by the event loop

**Errors:**
- `error.FdAlreadyWatched` - File descriptor already being watched
- `error.BackendNotInitialized` - Backend not initialized

**Note:** The returned watch handle remains valid until you call `removeFd()` for that watch.

**Example:**
```zig
const watch = try loop.addFd(socket_fd, .{ .read = true, .write = true });
loop.setCallback(watch, handleSocketEvent);
```

### setCallback

```zig
pub fn setCallback(
    self: *EventLoop,
    watch: *const Watch,
    callback: ?*const fn (*const Watch, Event) void
) void
```

Set or clear the callback for a watch.

**Parameters:**
- `watch` - Watch returned from `addFd()`
- `callback` - Callback function, or `null` to clear

### setUserData

```zig
pub fn setUserData(self: *EventLoop, watch: *const Watch, user_data: ?*anyopaque) void
```

Attach opaque user data to a watch.

### modifyFd

```zig
pub fn modifyFd(self: *EventLoop, watch: *const Watch, events: EventMask) !void
```

Modify the event mask for a watched file descriptor.

### removeFd

```zig
pub fn removeFd(self: *EventLoop, watch: *const Watch) void
```

Stop watching a file descriptor.

---

## Windows Socket Operations

These methods are available when the active backend is Windows IOCP.

### addSocket

```zig
pub fn addSocket(self: *EventLoop, socket: SocketHandle) !void
```

Associate a Windows socket with the active IOCP backend.

### recvSocket

```zig
pub fn recvSocket(self: *EventLoop, socket: SocketHandle, buffer: []u8) !void
```

Start an overlapped receive operation on a Windows socket.

### sendSocket

```zig
pub fn sendSocket(self: *EventLoop, socket: SocketHandle, data: []const u8) !void
```

Start an overlapped send operation on a Windows socket.

### removeSocket

```zig
pub fn removeSocket(self: *EventLoop, socket: SocketHandle) !void
```

Remove a Windows socket from the IOCP backend and clean up outstanding operations tracked by ZigZag.

Windows event note:
- Completed receives surface as `read_ready`
- Completed sends surface as `write_ready`
- Peer shutdown may surface as `hangup`
- Failed operations surface as `io_error`

## Timer Management

### addTimer

```zig
pub fn addTimer(
    self: *EventLoop,
    ms: u64,
    callback: *const fn (?*anyopaque) void
) !Timer
```

Add a one-shot timer.

**Parameters:**
- `ms` - Delay in milliseconds
- `callback` - Function called when timer fires

**Returns:** Timer structure

### addRecurringTimer

```zig
pub fn addRecurringTimer(
    self: *EventLoop,
    interval_ms: u64,
    callback: *const fn (?*anyopaque) void
) !Timer
```

Add a recurring timer.

**Parameters:**
- `interval_ms` - Interval in milliseconds
- `callback` - Function called each time timer fires

### cancelTimer

```zig
pub fn cancelTimer(self: *EventLoop, timer: *const Timer) void
```

Cancel a timer.

---

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `backend` | `Backend` | Active backend |
| `options` | `Options` | Configuration options |
| `allocator` | `std.mem.Allocator` | Memory allocator |
| `should_stop` | `bool` | Stop flag |
