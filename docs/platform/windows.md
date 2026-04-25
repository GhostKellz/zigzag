# Windows

Windows platform support for ZigZag.

## Status: Supported

Windows support is runtime-verified on the Win11 VM for timers, wake/user events, WinSock socket I/O through IOCP, native file watching, and focused Windows stress scenarios. Generic HANDLE or fd-style watching is not supported through `EventLoop.addFd()`, but ZigZag provides native Windows file watching through `FileWatcher`.

## Summary

- Runtime-verified on Windows 11
- Completion-based socket API exposed on `EventLoop`
- Native file watching via `ReadDirectoryChangesW`
- Focused Windows smoke and stress verification included in the build graph

## Backend

### IOCP (I/O Completion Ports)

Windows async I/O using completion ports with WinSock integration.

**Supported Features:**
- One-shot and recurring timers via Windows Timer Queue
- Wake events for cross-thread signaling
- User events with custom data
- Socket I/O via WSARecv/WSASend
- Public `EventLoop` socket operations via `addSocket()`, `recvSocket()`, `sendSocket()`, and `removeSocket()`
- Native file watching via `FileWatcher`
- Focused Windows runtime verification steps for sockets, timers, file watching, and stress scenarios

**Not Supported Yet:**
- Generic `EventLoop.addFd()` parity with Linux/macOS backends
- Arbitrary HANDLE watching through the public event-loop watch API

**Design Note:**
IOCP is completion-based, not readiness-based like epoll/kqueue. This means you must initiate I/O operations (WSARecv/WSASend) to receive completion events. Simply registering a socket is not enough.

Code that wants a backend-neutral terminal socket state should treat both `hangup` and `io_error` as terminal outcomes.

## Socket I/O

Socket support is exposed through the `EventLoop` on Windows as completion-based operations, not through the readiness-style `addFd()` API used on Linux and BSD/macOS.

```zig
try loop.addSocket(socket);

// Initiate async receive
var buffer: [1024]u8 = undefined;
try loop.recvSocket(socket, &buffer);

// Poll for completion
var events: [16]Event = undefined;
const count = try loop.poll(&events, 1000);

// Handle read_ready event
if (events[0].type == .read_ready) {
    // Data received, bytes in events[0].data.size
}
```

## File Watching

`FileWatcher` on Windows now uses native `ReadDirectoryChangesW` directory notifications rather than the old polling fallback.

**Current behavior:**
- `FileWatcher.processEvents()` remains the public API
- Single-file watches are implemented by watching the parent directory and filtering by basename
- Directory watches can use recursive notifications when `WatchConfig.recursive` is enabled
- Create, modify, delete, and rename events are translated from native Windows notifications
- File watches can be registered before the target file exists, as long as the parent directory exists

**Current limits:**
- Delivery is still driven by your calls to `FileWatcher.processEvents()`; ZigZag does not yet integrate file watching directly into the main `EventLoop`
- `EventLoop.addFd()` remains unsupported on Windows because IOCP is not a readiness backend

## Verification

Runtime verification on the Win11 VM currently includes:

- `zig build test`
- `zig build test-windows-iocp --summary all`
- `zig build test-windows-filewatch --summary all`
- `zig build test-windows-stress --summary all`

## Usage

```zig
// Auto-detect (uses IOCP on Windows)
var loop = try EventLoop.init(allocator, .{});

// Explicit
var loop = try EventLoop.init(allocator, .{ .backend = .iocp });
```

Attempting to use `loop.addFd()` on Windows returns `error.OperationNotSupported`.

## Build Options

```bash
# Disable IOCP
zig build -Diocp=false
```

## Cross-Compilation

Build for Windows from Linux:

```bash
zig build -Dtarget=x86_64-windows-gnu
```

## Terminal Features

Terminal features (PTY, signals) are **not available** on Windows.

The terminal module uses Unix-specific APIs that don't exist on Windows.
