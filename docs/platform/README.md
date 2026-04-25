# Platform Support

ZigZag platform support matrix and documentation.

## Support Matrix

| Platform | Backend | Status | Notes |
|----------|---------|--------|-------|
| Linux 5.1+ | io_uring | **Supported** | Primary, production-ready |
| Linux 2.6+ | epoll | **Supported** | Fallback, production-ready |
| macOS 10.12+ | kqueue | **Supported** | Production-ready |
| FreeBSD/OpenBSD/NetBSD | kqueue | **Supported** | Production-ready |
| Windows 11 | IOCP | **Experimental** | Timers, sockets, wake events |

## Platform Documentation

- [Linux](linux.md) - epoll and io_uring backends
- [macOS](macos.md) - kqueue backend
- [Windows](windows.md) - IOCP backend

## Feature Availability

| Feature | Linux | macOS | Windows |
|---------|-------|-------|---------|
| Event Loop | Yes | Yes | Yes |
| Timers | Yes | Yes | Yes |
| Socket I/O | Yes | Yes | Yes |
| File Watching | Native | Native | Polling (1s) |
| PTY Management | Yes | Yes | No |
| Signal Handling | Yes | Yes | No |
| Event Coalescing | Yes | Yes | Yes |
| Zero-Copy I/O | io_uring only | No | No |
