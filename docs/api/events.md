# Events

Event types and structures for the ZigZag event loop.

## Event

```zig
pub const Event = struct {
    fd: i32,
    type: EventType,
    data: EventData,
};
```

## EventType

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

### Semantics

- `read_ready`: data was received or a readiness backend reported the fd/socket readable.
- `write_ready`: a write completed or a readiness backend reported the fd/socket writable.
- `hangup`: the peer performed an orderly shutdown / end-of-stream was observed.
- `io_error`: the operation failed instead of completing as an orderly shutdown.

Backend note:
- Linux and BSD/macOS backends are readiness-oriented.
- Windows IOCP is completion-oriented.
- On Windows socket receives, peer close may surface as `hangup` when the overlapped receive completes with zero bytes.
- Code that needs a backend-neutral terminal state should treat both `hangup` and `io_error` as terminal outcomes.

## EventData

```zig
pub const EventData = union {
    size: usize,
    signal: i32,
    timer_id: u32,
    user_data: *anyopaque,
};
```

## EventMask

```zig
pub const EventMask = packed struct {
    read: bool = false,
    write: bool = false,
    io_error: bool = false,
    hangup: bool = false,

    pub fn any(self: EventMask) bool;
};
```

### Usage

```zig
// Watch for read events
const mask = EventMask{ .read = true };

// Watch for read and write
const rw_mask = EventMask{ .read = true, .write = true };
```
