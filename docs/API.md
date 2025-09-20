# Zigzag API Reference

## EventLoop

The main event loop structure.

### Methods

#### `init(allocator: std.mem.Allocator, options: Options) !EventLoop`

Create a new event loop with the specified options.

**Parameters:**
- `allocator`: Memory allocator
- `options`: Event loop configuration

**Returns:** New EventLoop instance

#### `deinit(self: *EventLoop) void`

Clean up the event loop and release resources.

#### `addFd(self: *EventLoop, fd: posix.fd_t, mask: EventMask, callback: *const fn(*const Watch, Event) void, user_data: ?*anyopaque) !void`

Add a file descriptor to watch for events.

**Parameters:**
- `fd`: File descriptor to watch
- `mask`: Events to watch for
- `callback`: Function called when events occur
- `user_data`: User data passed to callback

#### `modifyFd(self: *EventLoop, fd: posix.fd_t, mask: EventMask) !void`

Modify the event mask for a watched file descriptor.

**Parameters:**
- `fd`: File descriptor to modify
- `mask`: New event mask

#### `removeFd(self: *EventLoop, fd: posix.fd_t) !void`

Stop watching a file descriptor.

**Parameters:**
- `fd`: File descriptor to stop watching

#### `addTimer(self: *EventLoop, timeout_ms: u32, recurring: bool, callback: *const fn(*const Timer) void, user_data: ?*anyopaque) !*Timer`

Add a timer that fires after the specified timeout.

**Parameters:**
- `timeout_ms`: Timeout in milliseconds
- `recurring`: Whether the timer should repeat
- `callback`: Function called when timer fires
- `user_data`: User data passed to callback

**Returns:** Timer handle

#### `cancelTimer(self: *EventLoop, timer: *const Timer) void`

Cancel a timer.

**Parameters:**
- `timer`: Timer to cancel

#### `poll(self: *EventLoop, events: []Event, timeout_ms: ?u32) !usize`

Poll for events (non-blocking).

**Parameters:**
- `events`: Buffer to store events
- `timeout_ms`: Timeout in milliseconds (null for infinite)

**Returns:** Number of events received

#### `tick(self: *EventLoop) !void`

Process one iteration of the event loop.

#### `run(self: *EventLoop) !void`

Run the event loop until stopped.

## Event Types

### Event

```zig
pub const Event = struct {
    fd: i32,
    type: EventType,
    data: EventData,
};
```

### EventType

```zig
pub const EventType = enum {
    read_ready,
    write_ready,
    io_error,
    hangup,
    window_resize,
    focus_change,
    timer_expired,
    child_exit,
    user_event,
};
```

### EventMask

```zig
pub const EventMask = packed struct {
    read: bool = false,
    write: bool = false,
    io_error: bool = false,
    hangup: bool = false,
};
```

## Terminal Module

### Pty

Pseudo terminal management.

#### `create() !Pty`

Create a new PTY pair.

**Returns:** New Pty instance

#### `close(self: *Pty) void`

Close the PTY and release resources.

#### `setSize(self: *Pty, rows: u16, cols: u16) !void`

Set the terminal size.

**Parameters:**
- `rows`: Number of rows
- `cols`: Number of columns

#### `getSize(self: *Pty) !posix.system.winsize`

Get the current terminal size.

**Returns:** Terminal size information

### SignalHandler

Signal handling for terminal events.

#### `init(event_loop: *EventLoop) !SignalHandler`

Create a signal handler.

**Parameters:**
- `event_loop`: Event loop to integrate with

**Returns:** New SignalHandler instance

#### `close(self: *SignalHandler) void`

Close the signal handler.

#### `register(self: *SignalHandler) !void`

Register signal handler with the event loop.

### EventCoalescer

Event coalescing for terminal operations.

#### `init(allocator: std.mem.Allocator) !EventCoalescer`

Create an event coalescer.

**Parameters:**
- `allocator`: Memory allocator

**Returns:** New EventCoalescer instance

#### `deinit(self: *EventCoalescer) void`

Clean up the event coalescer.

#### `addEvent(self: *EventCoalescer, event: Event) !void`

Add an event to the coalescer.

**Parameters:**
- `event`: Event to add

#### `drainEvents(self: *EventCoalescer) ![]Event`

Get all pending events and clear the queue.

**Returns:** Slice of coalesced events

## Backend Selection

Zigzag automatically selects the best available backend:

1. **io_uring** (Linux 5.1+): Highest performance
2. **epoll** (Linux): Excellent performance fallback
3. **kqueue** (macOS/BSD): Native performance
4. **IOCP** (Windows): Windows async I/O

You can also manually specify a backend:

```zig
var loop = try EventLoop.init(allocator, .{
    .backend = .io_uring,  // Force io_uring
});
```

## Error Handling

Zigzag uses Zig's error union system. Common errors:

- `BackendNotInitialized`: Backend failed to initialize
- `SystemOutdated`: io_uring not supported
- `PermissionDenied`: Insufficient permissions
- `OutOfMemory`: Memory allocation failed

## Thread Safety

EventLoop is not thread-safe. All operations must be performed from the same thread that created the EventLoop.