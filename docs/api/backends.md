# Backends

Backend selection for the ZigZag event loop.

## Backend

```zig
pub const Backend = enum {
    io_uring,
    epoll,
    kqueue,
    iocp,

    pub fn autoDetect() Backend;
};
```

## Auto-Detection

`Backend.autoDetect()` selects the optimal backend for the current platform:

| Platform | Primary | Fallback |
|----------|---------|----------|
| Linux 5.1+ | io_uring | epoll |
| Linux <5.1 | epoll | - |
| macOS/BSD | kqueue | - |
| Windows | iocp | - |

## Manual Selection

```zig
var loop = try EventLoop.init(allocator, .{
    .backend = .epoll,
});
```

## Build Options

Backends can be disabled at compile time:

```bash
zig build -Dio_uring=false
zig build -Depoll=false
zig build -Dkqueue=false
zig build -Diocp=false
```

## Platform Support

| Backend | Platform | Status |
|---------|----------|--------|
| io_uring | Linux 5.1+ | Production |
| epoll | Linux 2.6+ | Production |
| kqueue | macOS/BSD | Production |
| iocp | Windows | Experimental: timers, wake/user events, WinSock socket I/O |

## IOCP Design Note

IOCP (Windows) is completion-based, not readiness-based like epoll/kqueue.

- **epoll/kqueue**: "Notify me when this fd is ready for I/O"
- **IOCP**: "I'm starting this I/O operation; notify me when it completes"

This means you must initiate I/O operations (WSARecv/WSASend) to receive completion events. Simply registering a socket doesn't produce events.

`EventLoop.addFd()` is not a supported Windows abstraction today. Windows socket support currently lives on the IOCP backend API (`addSocket`, `recvAsync`, `sendAsync`).
