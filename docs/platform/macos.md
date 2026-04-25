# macOS

macOS and BSD platform support for ZigZag.

## Backend

### kqueue

Native event notification for macOS and BSD systems.

**Features:**
- Native timer support via EVFILT_TIMER
- Efficient event batching
- Consistent across BSD variants

**Supported Platforms:**
- macOS 10.12+
- iOS, tvOS, watchOS, visionOS
- FreeBSD, OpenBSD, NetBSD

## Usage

```zig
// Auto-detect (uses kqueue)
var loop = try EventLoop.init(allocator, .{});

// Explicit
var loop = try EventLoop.init(allocator, .{ .backend = .kqueue });
```

## Build Options

```bash
# Disable kqueue (not recommended on macOS)
zig build -Dkqueue=false
```

## Terminal Features

Full terminal support on macOS:
- PTY management
- Signal handling
- Event coalescing

## Cross-Compilation

Build for macOS from Linux:

```bash
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-macos
```
