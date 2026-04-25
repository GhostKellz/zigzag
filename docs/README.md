# ZigZag Documentation

High-performance event loop library for Zig, optimized for terminal emulators.

## Contents

### [API Reference](api/)
Complete API documentation with actual function signatures.
- [Event Loop](api/event-loop.md) - Core EventLoop methods
- [Events](api/events.md) - Event, EventType, EventMask types
- [Timers](api/timers.md) - Timer management
- [Watches](api/watches.md) - File descriptor watching
- [Backends](api/backends.md) - Backend selection
- [Options](api/options.md) - Configuration options

### [Guides](guides/)
Practical guides for common use cases.
- [Quick Start](guides/quickstart.md) - Get started in minutes
- [Terminal Integration](guides/terminal-integration.md) - PTY and signal handling
- [Async Integration](guides/async-integration.md) - experimental zsync runtime helpers

### [Platform Support](platform/)
Platform-specific documentation and support matrix.
- [Overview](platform/) - Support matrix
- [Linux](platform/linux.md) - epoll and io_uring
- [macOS](platform/macos.md) - kqueue
- [Windows](platform/windows.md) - IOCP, native file watching, and Win11 runtime verification

### [Performance](performance/)
Performance characteristics and tuning.
- [Overview](performance/) - Performance summary
- [Tuning Guide](performance/tuning.md) - Configuration tuning

## Quick Links

- [GitHub Repository](https://github.com/ghostkellz/zigzag)
- [CHANGELOG](../CHANGELOG.md)
- [CONTRIBUTING](../CONTRIBUTING.md)

## Requirements

- Zig 0.17.0-dev or later
- Linux 2.6.27+ (epoll) or 5.1+ (io_uring)
- macOS 10.12+ (kqueue)
- Windows 11 (IOCP, native file watching, runtime-verified)
