# Watches

File descriptor watching for the ZigZag event loop.

Platform note:
- `Watch` / `addFd()` apply to readiness-style backends.
- On Windows, generic fd-style watching is not supported through `EventLoop.addFd()`.
- Use the Windows socket methods on `EventLoop` for socket I/O, and `FileWatcher` for filesystem notifications.

## Watch

```zig
pub const Watch = struct {
    fd: i32,
    events: EventMask,
    callback: ?*const fn (*const Watch, Event) void,
    user_data: ?*anyopaque,
};
```

## Methods

### addFd

```zig
pub fn addFd(self: *EventLoop, fd: i32, events: EventMask) !*const Watch
```

Add a file descriptor to watch. Returns a stable watch handle owned by the event loop.

**Note:** Callback is initially null. Use `setCallback()` to register. The handle remains valid until `removeFd()` is called.

### setCallback

```zig
pub fn setCallback(
    self: *EventLoop,
    watch: *const Watch,
    callback: ?*const fn (*const Watch, Event) void
) void
```

Set or clear the callback for a watch.

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

## Example

```zig
fn handleEvent(watch: *const zigzag.Watch, event: zigzag.Event) void {
    switch (event.type) {
        .read_ready => {
            // Data available to read
        },
        .write_ready => {
            // Ready to write
        },
        .hangup => {
            // Connection closed
        },
        else => {},
    }
}

// Add watch
const watch = try loop.addFd(socket_fd, .{ .read = true });
loop.setCallback(watch, handleEvent);

// Later: modify to also watch for write
try loop.modifyFd(watch, .{ .read = true, .write = true });

// Cleanup
loop.removeFd(watch);
```
