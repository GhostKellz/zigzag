<p align="center">
  <img src="assets/icons/zigzag.png" alt="ZigZag Logo" width="200"/>
</p>

# ZigZag

<p align="center">
  <img src="https://img.shields.io/badge/Built_with-Zig-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Built with Zig">
  <img src="https://img.shields.io/badge/Zig-0.17.0--dev-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig 0.17.0-dev">
  <img src="https://img.shields.io/badge/Event_Loop-High_Performance-00ADD8?style=for-the-badge" alt="High Performance">
  <img src="https://img.shields.io/badge/Platform-Linux_|_macOS_|_BSD_|_Windows-6C757D?style=for-the-badge" alt="Cross Platform">
  <img src="https://img.shields.io/badge/io__uring-00C853?style=for-the-badge&logo=linux&logoColor=white" alt="io_uring">
  <img src="https://img.shields.io/badge/kqueue-000000?style=for-the-badge&logo=apple&logoColor=white" alt="kqueue">
  <img src="https://img.shields.io/badge/epoll-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="epoll">
  <img src="https://img.shields.io/badge/IOCP-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="IOCP">
  <img src="https://img.shields.io/badge/Zero_Copy_I/O-DC382D?style=for-the-badge" alt="Zero Copy I/O">
  <img src="https://img.shields.io/badge/Memory_Safe-4EAA25?style=for-the-badge" alt="Memory Safe">
  <img src="https://img.shields.io/badge/Lock_Free-9B59B6?style=for-the-badge" alt="Lock Free">
</p>

High-performance, cross-platform event loop for Zig. Optimized for terminal emulators with seamless async runtime integration.

> **Note**: Experimental library under active development. API may change.

## Features

- **Multi-backend**: io_uring (Linux 5.1+), epoll (Linux), kqueue (macOS/BSD)
- **Terminal optimized**: PTY management, signal handling, event coalescing
- **Async integration**: Experimental zsync runtime helpers
- **Zero-copy I/O**: High-performance I/O operations with io_uring
- **Memory safe**: Zig's compile-time guarantees

## Installation

### Using Zig Package Manager

```bash
# Latest release
zig fetch --save https://github.com/ghostkellz/zigzag/archive/refs/tags/v0.1.6.tar.gz

# Or main branch
zig fetch --save https://github.com/ghostkellz/zigzag/archive/refs/heads/main.tar.gz
```

Add to your `build.zig`:

```zig
const zigzag = b.dependency("zigzag", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
```

### Manual

```bash
git clone https://github.com/ghostkellz/zigzag.git
cd zigzag
zig build
```

## Quick Start

```zig
const std = @import("std");
const zigzag = @import("zigzag");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create event loop with auto-detected backend
    var loop = try zigzag.EventLoop.init(allocator, .{});
    defer loop.deinit();

    std.debug.print("Backend: {}\n", .{loop.backend});
}
```

## Backend Selection

ZigZag automatically selects the optimal backend:

| Platform | Primary | Fallback |
|----------|---------|----------|
| Linux 5.1+ | io_uring | epoll |
| Linux <5.1 | epoll | - |
| macOS/BSD | kqueue | - |
| Windows | iocp | - |

**Windows Note:** Windows support remains experimental for `v0.1.6`. The IOCP backend currently covers timers, wake/user events, and WinSock socket I/O. Generic `EventLoop.addFd()` is not supported on Windows, file watching uses a caller-driven polling fallback, and we have not yet run runtime verification on a real Windows host.

## Build Options

```bash
# Disable specific backends
zig build -Dio_uring=false
zig build -Depoll=false
zig build -Dkqueue=false

# Enable debug events
zig build -Ddebug_events=true
```

## Documentation

- [API Reference](docs/api/README.md)
- [Quick Start Guide](docs/guides/quickstart.md)
- [Performance](docs/performance/README.md)

## Requirements

- Zig 0.17.0-dev or later
- Linux 2.6.27+ (epoll) or 5.1+ (io_uring)
- macOS 10.12+ (kqueue)
- Windows 11 (IOCP)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License. See [LICENSE](LICENSE).
