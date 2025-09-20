# ZIGZAG_TODO.md - Event Loop Development Roadmap

🔄 **Mission: Build the fastest, most efficient event loop for Zig - optimized for terminal emulators**

## Overview

zigzag is a lightweight, high-performance event loop library designed to complement zsync. While zsync provides high-level async/await abstractions, zigzag handles the low-level I/O multiplexing and event notification that terminal emulators need for maximum performance.

## Architecture Philosophy

```
Terminal Application
       ↓
   zsync (async tasks, channels, futures)
       ↓
   zigzag (event loop, I/O polling, timers)
       ↓
   OS (io_uring, epoll, kqueue, IOCP)
```

## Core Requirements

### What libxev Does (Reference Implementation)
- Cross-platform event notification (Linux, macOS, Windows, WASM)
- File descriptor monitoring (readable, writable, error states)
- Timer management (one-shot and recurring)
- Signal handling (POSIX signals)
- Process management (child process events)
- Async DNS resolution
- Thread pool for blocking operations

### What zigzag Needs for Ghostshell

#### 🎯 Essential Features (Phase 1)

##### 1. Platform Backends
```zig
pub const Backend = enum {
    io_uring,   // Linux 5.1+ (fastest)
    epoll,      // Linux fallback
    kqueue,     // macOS/BSD
    iocp,       // Windows (future)
};

pub fn autoDetect() Backend {
    // Detect best available backend at runtime
    if (linux and io_uring_available) return .io_uring;
    if (linux) return .epoll;
    if (macos or bsd) return .kqueue;
    // etc.
}
```

##### 2. Core Event Loop
```zig
pub const EventLoop = struct {
    backend: Backend,
    events: EventQueue,
    timers: TimerWheel,

    pub fn init(options: Options) !EventLoop;
    pub fn deinit(self: *EventLoop) void;

    // Main polling function
    pub fn poll(self: *EventLoop, timeout_ms: ?u32) ![]Event;

    // Run one iteration
    pub fn tick(self: *EventLoop) !bool;

    // Run until stopped
    pub fn run(self: *EventLoop) !void;
    pub fn stop(self: *EventLoop) void;
};
```

##### 3. Event Types
```zig
pub const EventType = enum {
    // I/O events
    read_ready,
    write_ready,
    error,
    hangup,

    // Terminal specific
    window_resize,
    focus_change,

    // Timer events
    timer_expired,

    // Process events
    child_exit,

    // Custom events
    user_event,
};

pub const Event = struct {
    fd: i32,
    type: EventType,
    data: union {
        size: usize,
        signal: i32,
        user_data: *anyopaque,
    },
};
```

##### 4. File Descriptor Management
```zig
pub const Watch = struct {
    fd: i32,
    events: EventMask,
    callback: ?*const fn(Event) void,
    user_data: ?*anyopaque,
};

pub fn addFd(self: *EventLoop, fd: i32, events: EventMask) !*Watch;
pub fn modifyFd(self: *EventLoop, watch: *Watch, events: EventMask) !void;
pub fn removeFd(self: *EventLoop, watch: *Watch) void;
```

##### 5. Timer Management
```zig
pub const Timer = struct {
    deadline: i64,
    interval: ?u64, // null for one-shot
    callback: *const fn() void,
};

pub fn addTimer(self: *EventLoop, ms: u64, callback: *const fn() void) !*Timer;
pub fn addRecurringTimer(self: *EventLoop, interval_ms: u64, callback: *const fn() void) !*Timer;
pub fn cancelTimer(self: *EventLoop, timer: *Timer) void;
```

#### ⚡ Terminal-Specific Optimizations (Phase 2)

##### 1. Batch Event Processing
```zig
// Process multiple events in single syscall
pub fn pollBatch(self: *EventLoop, events: []Event, timeout: ?u32) !usize;
```

##### 2. Priority Queues
```zig
pub const Priority = enum {
    immediate,  // Keyboard input
    high,       // Terminal resize
    normal,     // Network I/O
    low,        // Background tasks
};

pub fn addFdWithPriority(self: *EventLoop, fd: i32, priority: Priority) !*Watch;
```

##### 3. Event Coalescing
```zig
// Combine rapid terminal resize events
pub fn enableCoalescing(self: *EventLoop, event_type: EventType) void;
```

#### 🚀 Performance Features (Phase 3)

##### 1. Zero-Copy Operations
```zig
// io_uring specific optimizations
pub fn readDirect(self: *EventLoop, fd: i32, buffer: []u8) !ReadOp;
pub fn writeDirect(self: *EventLoop, fd: i32, buffer: []const u8) !WriteOp;
```

##### 2. Submission Queue Batching
```zig
// Batch multiple operations before syscall
pub fn beginBatch(self: *EventLoop) void;
pub fn submitBatch(self: *EventLoop) !void;
```

##### 3. Memory Pool
```zig
// Pre-allocated event structures
pub const EventPool = struct {
    events: [4096]Event,
    free_list: FreeList,
};
```

## Integration with zsync

### Complementary Design
```zig
// zsync handles high-level async
const task = zsync.spawn(async {
    const data = await socket.read();
});

// zigzag handles low-level I/O
const loop = zigzag.init();
loop.addFd(socket.fd, .{ .read = true });
while (loop.tick()) {
    // Process events that zsync tasks are waiting for
}
```

### Shared Event Sources
```zig
// zigzag can notify zsync of events
pub fn connectToZsync(self: *EventLoop, runtime: *zsync.Runtime) void;
```

## Terminal Emulator Specific Features

### 1. PTY Management
```zig
pub fn addPty(self: *EventLoop, pty: Pty) !*Watch {
    // Special handling for pseudo-terminals
    return self.addFd(pty.master_fd, .{ .read = true, .write = true });
}
```

### 2. Signal Handling
```zig
pub fn addSignal(self: *EventLoop, sig: i32, callback: *const fn() void) !void {
    // SIGWINCH for terminal resize
    // SIGCHLD for child processes
}
```

### 3. Wayland Integration
```zig
// Direct integration with wzl
pub fn addWaylandFd(self: *EventLoop, display: *wzl.Display) !*Watch;
```

## Performance Targets

- **Latency**: < 1µs event dispatch
- **Throughput**: 1M+ events/second
- **Memory**: < 1MB for 1000 file descriptors
- **CPU**: < 1% idle overhead
- **Syscalls**: Minimal (batch operations)

## API Examples

### Basic Usage
```zig
const zigzag = @import("zigzag");

const loop = try zigzag.EventLoop.init(.{
    .backend = .auto_detect,
    .max_events = 1024,
});
defer loop.deinit();

// Add terminal input
const stdin_watch = try loop.addFd(std.io.getStdIn().handle, .{ .read = true });
stdin_watch.callback = handleInput;

// Add timer for cursor blink
const blink_timer = try loop.addRecurringTimer(500, blinkCursor);

// Main loop
while (try loop.tick()) {
    // Process events
}
```

### Advanced Usage with zsync
```zig
// Create zigzag event loop
const loop = try zigzag.EventLoop.init(.{ .backend = .io_uring });

// Connect to zsync runtime
const runtime = try zsync.Runtime.init();
loop.connectToZsync(runtime);

// Now zsync tasks can await zigzag events
const task = runtime.spawn(async {
    const event = await loop.waitForFd(socket_fd, .read_ready);
    // Handle event
});
```

## Testing Strategy

### Unit Tests
- [ ] Each backend implementation
- [ ] Timer accuracy
- [ ] Event ordering
- [ ] Memory management

### Integration Tests
- [ ] With zsync runtime
- [ ] With wzl (Wayland)
- [ ] With terminal emulator

### Performance Benchmarks
- [ ] Event throughput
- [ ] Latency measurements
- [ ] Memory usage under load
- [ ] Comparison with libxev

## Development Phases

### Phase 1: Core (Week 1-2)
- [ ] Basic event loop structure
- [ ] Linux epoll backend
- [ ] File descriptor monitoring
- [ ] Simple timer support
- [ ] Basic tests

### Phase 2: Platforms (Week 3-4)
- [ ] io_uring backend (Linux 5.1+)
- [ ] kqueue backend (macOS/BSD)
- [ ] Backend auto-detection
- [ ] Platform-specific optimizations

### Phase 3: Terminal Features (Week 5-6)
- [ ] PTY handling
- [ ] Signal management
- [ ] Event coalescing
- [ ] Priority queues

### Phase 4: Performance (Week 7-8)
- [ ] Zero-copy operations
- [ ] Batch submissions
- [ ] Memory pooling
- [ ] Benchmarking suite

### Phase 5: Integration (Week 9-10)
- [ ] zsync integration
- [ ] wzl integration
- [ ] Ghostshell integration
- [ ] Documentation

## Success Metrics

- ✅ Replaces libxev dependency completely
- ✅ 2x faster than libxev for terminal operations
- ✅ Seamless zsync integration
- ✅ < 5000 lines of code
- ✅ 100% test coverage
- ✅ Zero memory leaks

## Design Decisions

### Why Not Just Use libxev?
1. **Terminal-optimized** - We don't need all libxev features
2. **Zig 0.16 native** - Built for modern Zig from day one
3. **zsync integration** - Designed to work with your async runtime
4. **Lighter weight** - Only what terminals need
5. **Your control** - Custom optimizations for Ghostshell

### Why "zigzag"?
- Event loops "zigzag" between waiting and processing
- Clever play on "Zig" language name
- Memorable and unique in the ecosystem
- Represents the back-and-forth nature of I/O

---

**🚀 Let's build the fastest event loop for terminal emulators!**