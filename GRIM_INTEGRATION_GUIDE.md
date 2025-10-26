# ZigZag Event Loop - Complete Integration Guide for Grim Editor

## Executive Summary

ZigZag is a high-performance, cross-platform event loop library for Zig optimized for terminal emulators. It provides a unified API across Linux (io_uring/epoll), macOS (kqueue), and Windows (IOCP) platforms. This guide documents the complete public API and integration requirements for using ZigZag as the event loop backend for the Grim editor.

**Key Characteristics:**
- Modern async-first design with multi-backend support
- Terminal-optimized with built-in signal handling and PTY management
- Zero-copy I/O capability
- Event coalescing for high-frequency events
- Theta phase (feature-complete) with comprehensive error handling

---

## 1. Core Event Loop API

### 1.1 Main Entry Point: EventLoop Initialization

**Location:** `/data/projects/zigzag/src/root.zig` (primary public API)

The `EventLoop` struct is the main orchestrator for all event handling:

```zig
pub const EventLoop = struct {
    backend: Backend,
    options: Options,
    allocator: std.mem.Allocator,
    
    // Internal: backend-specific handlers (conditionally compiled)
    epoll_backend: if (build_options.enable_epoll) ?EpollBackend else void,
    io_uring_backend: if (build_options.enable_io_uring) ?IoUringBackend else void,
    kqueue_backend: if (build_options.enable_kqueue) ?KqueueBackend else void,
    iocp_backend: if (build_options.enable_iocp) ?IOCPBackend else void,
    
    // State management
    watches: std.AutoHashMap(i32, Watch),
    timers: std.AutoHashMap(u32, Timer),
    should_stop: bool = false,
    coalescer: ?EventCoalescer = null,
    
    // Key methods...
};
```

**Initialization:**

```zig
pub fn init(allocator: std.mem.Allocator, options: Options) !EventLoop
```

Parameters:
- `allocator`: Memory allocator (typically GeneralPurposeAllocator)
- `options`: Configuration struct with:
  - `max_events: u32 = 1024` - Maximum events per poll cycle
  - `backend: ?Backend = null` - Force specific backend or auto-detect
  - `coalescing: ?CoalescingConfig = null` - Optional event coalescing

**Auto-Detection Logic:**
```zig
const backend = options.backend orelse Backend.autoDetect();
```

The auto-detection prioritizes:
- Linux: io_uring (5.1+) → epoll (fallback)
- macOS/BSD: kqueue
- Windows: IOCP

### 1.2 Core Event Loop Types

**Backend Enum:**
```zig
pub const Backend = enum {
    io_uring,  // Linux 5.1+ (fastest)
    epoll,     // Linux fallback
    kqueue,    // macOS/BSD
    iocp,      // Windows (future)
};
```

**Event Type Enum:**
```zig
pub const EventType = enum {
    // I/O events
    read_ready,      // FD is readable
    write_ready,     // FD is writable
    io_error,        // I/O error occurred
    hangup,          // FD hungup (EOF)
    
    // Terminal specific
    window_resize,   // Terminal window resized (SIGWINCH)
    focus_change,    // Terminal focus changed
    
    // Timer events
    timer_expired,   // Timer callback should fire
    
    // Process events
    child_exit,      // Child process exited (SIGCHLD)
    
    // Custom events
    user_event,      // User-defined event
};
```

**Event Structure:**
```zig
pub const Event = struct {
    fd: i32,                    // File descriptor (or -1 for non-FD events)
    type: EventType,            // Event type
    data: EventData,            // Event-specific data
};

pub const EventData = union {
    size: usize,               // Bytes available for I/O
    signal: i32,               // Signal number
    timer_id: u32,             // Timer ID
    user_data: *anyopaque,     // User-defined data
};
```

**EventMask (for FD watching):**
```zig
pub const EventMask = packed struct {
    read: bool = false,        // Watch for read readiness
    write: bool = false,       // Watch for write readiness
    io_error: bool = false,    // Watch for I/O errors
    hangup: bool = false,      // Watch for hangup

    pub fn any(self: EventMask) bool {
        return self.read or self.write or self.io_error or self.hangup;
    }
};
```

**Watch Structure:**
```zig
pub const Watch = struct {
    fd: i32,
    events: EventMask,
    callback: ?*const fn (*const Watch, Event) void,  // Optional callback
    user_data: ?*anyopaque,                           // User data for callback
};
```

---

## 2. File Descriptor Watching API

**Critical for Grim:** This is how stdin keyboard input is monitored.

### 2.1 Adding File Descriptors

```zig
pub fn addFd(self: *EventLoop, fd: i32, events: EventMask) !*const Watch
```

**Returns:** Pointer to stored Watch struct (must not be freed by caller)

**Error Cases:**
- `error.FdAlreadyWatched` - FD already being watched
- `error.BackendNotInitialized` - Backend failed to initialize
- Backend-specific errors

**Usage Example for stdin:**
```zig
const stdin_fd = std.io.getStdIn().handle;
const watch = try loop.addFd(stdin_fd, .{ .read = true });
```

### 2.2 Modifying File Descriptor Events

```zig
pub fn modifyFd(self: *EventLoop, watch: *const Watch, events: EventMask) !void
```

**Usage:** Change what events you're watching for after initial registration.

```zig
// Switch from read to write monitoring
try loop.modifyFd(watch, .{ .write = true });
```

### 2.3 Removing File Descriptors

```zig
pub fn removeFd(self: *EventLoop, watch: *const Watch) void
```

**Removes:** Watch from all monitoring

**Cleanup order:** Always call before closing the FD and before deinit.

### 2.4 Setting Callbacks

```zig
pub fn setCallback(self: *EventLoop, watch: *const Watch, 
                   callback: ?*const fn (*const Watch, Event) void) void
```

**Callback Signature:**
```zig
fn myCallback(watch: *const Watch, event: Event) void {
    // Handle event
    // Access watch.fd, watch.user_data, event.type, event.data
}
```

**Important:** Can be set to `null` to remove callback.

---

## 3. Timer API

### 3.1 One-Shot Timers

```zig
pub fn addTimer(self: *EventLoop, ms: u64, 
                callback: *const fn (?*anyopaque) void) !Timer
```

**Returns:** Timer struct with unique `id` field

**Callback Signature:**
```zig
fn timerCallback(user_data: ?*anyopaque) void {
    // Timer fired
    // user_data is always null with current API (see TODO below)
}
```

**Issues with current API:**
- No way to pass user_data to timer callbacks
- Timer struct doesn't include user_data field initialization
- Must track timer IDs externally for cancellation

### 3.2 Recurring Timers

```zig
pub fn addRecurringTimer(self: *EventLoop, interval_ms: u64,
                         callback: *const fn (?*anyopaque) void) !Timer
```

**Behavior:**
- Automatically reschedules after each expiration
- `timer.interval` field is set to `interval_ms`
- Removed manually with `cancelTimer()`

### 3.3 Timer Structure

```zig
pub const Timer = struct {
    id: u32,                                    // Unique timer ID
    deadline: i64,                              // Absolute deadline (ms since epoch)
    interval: ?u64,                             // null for one-shot, value for recurring
    type: TimerType,                            // one_shot or recurring
    callback: *const fn (?*anyopaque) void,    // Callback function
    user_data: ?*anyopaque,                    // (Not initialized by API - design limitation)
};

pub const TimerType = enum {
    one_shot,
    recurring,
};
```

### 3.4 Canceling Timers

```zig
pub fn cancelTimer(self: *EventLoop, timer: *const Timer) void
```

**Cleanup:** Must be called before event loop deinitialization.

---

## 4. Event Loop Execution

### 4.1 Main Loop - Blocking Run

```zig
pub fn run(self: *EventLoop) !void
```

**Behavior:**
- Blocks until `self.should_stop` is set to true
- Calls `tick()` repeatedly with sleep(1ms) between iterations
- Does NOT automatically stop on zero events

**Exit:** Only via `self.stop()` call from callback

### 4.2 Single Iteration - Tick

```zig
pub fn tick(self: *EventLoop) !bool
```

**Returns:** `true` if events were processed, `false` if no events

**Behavior:**
1. Calls `poll()` with timeout_ms=0 (non-blocking)
2. Applies event coalescing if enabled
3. Dispatches events to callbacks or fires timer callbacks
4. Returns event count > 0

**Usage Pattern for Grim:**
```zig
while (!should_exit) {
    const had_events = try loop.tick();
    if (!had_events) {
        std.time.sleep(10_000_000); // 10ms
    }
}
```

### 4.3 Polling for Events

```zig
pub fn poll(self: *EventLoop, events: []Event, timeout_ms: ?u32) !usize
```

**Returns:** Number of events available

**Parameters:**
- `events`: Output buffer for events
- `timeout_ms`: `null` for non-blocking, `?u32` for specific timeout

**Behavior:** Delegated to backend implementation.

### 4.4 Control Methods

```zig
pub fn stop(self: *EventLoop) void     // Set should_stop = true
pub fn reset(self: *EventLoop) void    // Clear should_stop flag
pub fn deinit(self: *EventLoop) void   // Cleanup all resources
```

---

## 5. Terminal-Specific Features

**Location:** `/data/projects/zigzag/src/terminal.zig`

### 5.1 Signal Handler for Terminal Events

```zig
pub const SignalHandler = struct {
    event_loop: *EventLoop,
    signal_fd: posix.fd_t,
    
    pub fn init(event_loop: *EventLoop) !SignalHandler
    pub fn close(self: *SignalHandler) void
    pub fn register(self: *SignalHandler) !void
};
```

**Signals Monitored:**
- `SIGWINCH` - Window resize → `.window_resize` event
- `SIGCHLD` - Child exit → `.child_exit` event
- `SIGINT` - Interrupt (Ctrl+C)
- `SIGTERM` - Termination

**Implementation Uses:**
- Linux: `signalfd()` for efficient signal delivery
- Converts signals to events dispatched through event loop

**Integration Pattern:**
```zig
var signal_handler = try terminal.SignalHandler.init(&loop);
defer signal_handler.close();
try signal_handler.register();
```

### 5.2 PTY (Pseudo-Terminal) Management

**Location:** `/data/projects/zigzag/src/pty.zig`

```zig
pub const Pty = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    slave_path: []const u8,
    
    pub fn create() !Pty
    pub fn close(self: *Pty) void
    pub fn setSize(self: *Pty, rows: u16, cols: u16) !void
    pub fn getSize(self: *Pty) !posix.system.winsize
};
```

**PTY Manager (for multiple processes):**
```zig
pub const PtyManager = struct {
    allocator: std.mem.Allocator,
    processes: std.AutoHashMap(posix.pid_t, PtyProcess),
    
    pub fn init(allocator: std.mem.Allocator) PtyManager
    pub fn deinit(self: *PtyManager) void
    pub fn spawn(self: *PtyManager, config: PtyConfig) !PtyProcess
};
```

**Configuration:**
```zig
pub const PtyConfig = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    shell: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    raw_mode: bool = true,
};
```

---

## 6. Grim Editor-Specific Support

**Location:** `/data/projects/zigzag/src/grim_editor_support.zig`

### 6.1 Debounced File Watcher

```zig
pub const DebouncedFileWatcher = struct {
    allocator: std.mem.Allocator,
    watches: std.StringHashMap(EditorFileWatch),
    config: EditorWatchConfig,
    pending_events: std.ArrayList(FileChangeEvent),
    
    pub fn init(allocator: std.mem.Allocator, config: EditorWatchConfig) !DebouncedFileWatcher
    pub fn deinit(self: *DebouncedFileWatcher) void
    pub fn addWatch(self: *DebouncedFileWatcher, path: []const u8) !void
    pub fn pollChanges(self: *DebouncedFileWatcher) ![]const FileChangeEvent
    pub fn removeWatch(self: *DebouncedFileWatcher, path: []const u8) void
};
```

**Configuration:**
```zig
pub const EditorWatchConfig = struct {
    debounce_ms: u64 = 50,           // Debounce time for file changes
    ignore_patterns: []const []const u8 = &.{},  // Patterns to ignore
    watch_syntax_files: bool = true,
    watch_lsp_files: bool = true,
};

pub const FileChangeType = enum {
    created,
    modified,
    deleted,
    renamed,
    syntax_tree_invalidated,
    lsp_diagnostic_changed,
};
```

**Usage Pattern:**
```zig
var watcher = try DebouncedFileWatcher.init(allocator, .{
    .debounce_ms = 50,
    .ignore_patterns = &.{".git", "node_modules"},
});
defer watcher.deinit();

try watcher.addWatch("myfile.zig");
const changes = try watcher.pollChanges();
```

### 6.2 LSP Event Handler

```zig
pub const LSPEventHandler = struct {
    allocator: std.mem.Allocator,
    diagnostics_changed: bool = false,
    completion_available: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) LSPEventHandler
    pub fn deinit(_: *LSPEventHandler) void
    pub fn onDiagnosticsChanged(self: *LSPEventHandler) void
    pub fn onCompletionAvailable(self: *LSPEventHandler) void
    pub fn clearEvents(self: *LSPEventHandler) void
};
```

### 6.3 Syntax File Watcher

```zig
pub const SyntaxFileWatcher = struct {
    allocator: std.mem.Allocator,
    syntax_paths: std.ArrayList([]const u8),
    invalidated: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) !SyntaxFileWatcher
    pub fn deinit(self: *SyntaxFileWatcher) void
    pub fn addSyntaxFile(self: *SyntaxFileWatcher, path: []const u8) !void
    pub fn invalidate(self: *SyntaxFileWatcher) void
    pub fn needsReload(self: SyntaxFileWatcher) bool
    pub fn clearInvalidation(self: *SyntaxFileWatcher) void
};
```

---

## 7. Event Coalescing

**Location:** `/data/projects/zigzag/src/event_coalescing.zig`

### 7.1 Purpose and Configuration

Event coalescing reduces event spam by batching similar events:

```zig
pub const CoalescingConfig = struct {
    coalesce_resize: bool = true,        // Merge window_resize events
    max_coalesce_time_ms: u32 = 10,      // Max wait time
    max_batch_size: usize = 16,          // Max events per batch
};
```

### 7.2 EventCoalescer Structure

```zig
pub const EventCoalescer = struct {
    allocator: std.mem.Allocator,
    config: CoalescingConfig,
    
    // Pending events by type
    resize_events: std.ArrayList(Event),
    io_events: std.AutoHashMap(i32, Event),  // fd -> latest event
    last_coalesce_time: i64,
    
    pub fn init(allocator: std.mem.Allocator, config: CoalescingConfig) !EventCoalescer
    pub fn deinit(self: *EventCoalescer) void
    pub fn addEvent(self: *EventCoalescer, event: Event) !void
    pub fn shouldFlush(self: *EventCoalescer) bool
    pub fn flush(self: *EventCoalescer, output: []Event) !usize
};
```

**Behavior:**
- Window resize events are coalesced (only latest kept)
- I/O events are coalesced per FD (latest update wins)
- Other events pass through unchanged
- Flushes after max_coalesce_time_ms or when batch full

---

## 8. Error Handling

**Location:** `/data/projects/zigzag/src/errors.zig`

### 8.1 Error Types

```zig
pub const EventLoopError = error{
    // Initialization
    BackendNotSupported,
    BackendInitializationFailed,
    BackendNotInitialized,
    InsufficientMemory,
    InvalidConfiguration,
    
    // File descriptor operations
    FdAlreadyWatched,
    FdNotWatched,
    InvalidFileDescriptor,
    TooManyFileDescriptors,
    
    // Timer operations
    TimerAlreadyExists,
    TimerNotFound,
    InvalidTimerConfiguration,
    TooManyTimers,
    
    // Event processing
    EventQueueFull,
    EventProcessingFailed,
    InvalidEventType,
    
    // Backend errors
    EpollError,
    IoUringError,
    KQueueError,
    IOCPError,
    SubmissionQueueFull,
    
    // System errors
    SystemResourceExhausted,
    PermissionDenied,
    SystemOutdated,
    
    // Platform errors
    PlatformNotSupported,
    BackendNotImplemented,
};
```

### 8.2 Error Recovery

```zig
pub const ErrorHandler = struct {
    handleFn: *const fn (context: ErrorContext) RecoveryStrategy,
    user_data: ?*anyopaque = null,
};

pub const RecoveryStrategy = enum {
    retry,      // Retry the operation
    fallback,   // Try alternative approach
    ignore,     // Continue normally
    fatal,      // Stop event loop
};
```

---

## 9. Platform Backends

### 9.1 Linux Backends

#### 9.1.1 io_uring Backend
**Location:** `/data/projects/zigzag/src/backend/io_uring.zig`
- Linux 5.1+
- Highest performance
- Supports:
  - File descriptor monitoring
  - Timer operations via `IORING_OP_TIMEOUT`
  - Zero-copy I/O

#### 9.1.2 epoll Backend
**Location:** `/data/projects/zigzag/src/backend/epoll.zig`
- Linux 2.6+
- Fallback for older Linux
- Supports:
  - `epoll_create1()` for FD monitoring
  - `timerfd_create()` for timers
  - Event mask conversion

```zig
pub const EpollBackend = struct {
    epoll_fd: i32,
    allocator: std.mem.Allocator,
    timer_fds: std.AutoHashMap(u32, i32),  // timer_id -> timerfd
    
    pub fn init(allocator: std.mem.Allocator) !EpollBackend
    pub fn deinit(self: *EpollBackend) void
    pub fn addFd(self: *EpollBackend, fd: i32, mask: EventMask) !void
    pub fn modifyFd(self: *EpollBackend, fd: i32, mask: EventMask) !void
    pub fn removeFd(self: *EpollBackend, fd: i32) !void
    pub fn poll(self: *EpollBackend, events: []Event, timeout_ms: ?u32) !usize
    pub fn addTimer(self: *EpollBackend, timer_id: u32, ms: u64) !void
    pub fn addRecurringTimer(self: *EpollBackend, timer_id: u32, ms: u64) !void
    pub fn cancelTimer(self: *EpollBackend, timer_id: u32) !void
};
```

### 9.2 macOS/BSD Backend

**Location:** `/data/projects/zigzag/src/backend/kqueue.zig`

```zig
pub const KqueueBackend = struct {
    kqueue_fd: i32,
    allocator: std.mem.Allocator,
    timer_map: std.AutoHashMap(u32, void),
    
    pub fn init(allocator: std.mem.Allocator) !KqueueBackend
    pub fn deinit(self: *KqueueBackend) void
    pub fn addFd(self: *KqueueBackend, fd: i32, mask: EventMask) !void
    pub fn modifyFd(self: *KqueueBackend, fd: i32, mask: EventMask) !void
    pub fn removeFd(self: *KqueueBackend, fd: i32) !void
    pub fn poll(self: *KqueueBackend, events: []Event, timeout_ms: ?u32) !usize
    pub fn addTimer(self: *KqueueBackend, timer_id: u32, ms: u64) !void
    pub fn addRecurringTimer(self: *KqueueBackend, timer_id: u32, ms: u64) !void
    pub fn cancelTimer(self: *KqueueBackend, timer_id: u32) !void
};
```

**Features:**
- `EVFILT_READ` / `EVFILT_WRITE` for I/O
- `EVFILT_TIMER` for timers
- Native event delivery without conversion

### 9.3 Windows Backend

**Location:** `/data/projects/zigzag/src/backend/iocp.zig`

- IOCP (I/O Completion Ports)
- Supports overlapped I/O
- Integrated timer support

---

## 10. Build Configuration and Feature Flags

**Location:** `/data/projects/zigzag/build.zig`

### 10.1 Compile-Time Options

```
zig build -Denable_io_uring=true -Denable_epoll=true -Dkqueue=true
```

Options:
- `io_uring` (bool) - Enable io_uring backend
- `epoll` (bool) - Enable epoll backend
- `kqueue` (bool) - Enable kqueue backend
- `iocp` (bool) - Enable IOCP backend
- `terminal` (bool) - Enable PTY/signal features
- `zsync` (bool) - Enable async runtime integration
- `debug_events` (bool) - Enable event debugging
- `zlog` (bool) - Enable structured logging
- `zdoc` (bool) - Enable documentation generation

### 10.2 Feature Detection at Runtime

**Location:** `/data/projects/zigzag/src/api.zig`

```zig
pub const ApiLevel = enum(u32) {
    alpha = 1,      // Core functionality
    beta = 2,       // Stability and performance
    theta = 3,      // Feature complete (CURRENT)
    rc = 4,         // Release candidate
    stable = 5,     // Production ready
};

pub const Features = struct {
    pub const event_loop = true;
    pub const multiple_backends = true;
    pub const timers = true;
    // ... many more
    
    pub fn isAvailable(comptime feature_name: []const u8) bool
    pub fn getFeatureLevel(comptime feature_name: []const u8) ApiLevel
};
```

---

## 11. Logging and Debugging

**Location:** `/data/projects/zigzag/src/logging.zig`

The library uses Zig's standard logging when available, with integration for `zlog` when enabled.

**Available Functions:**
- `logBackendInit(backend_name: []const u8)`
- `logEventProcessing(fd: i32, event_type: EventType)`
- `logTimerEvent(timer_id: u32)`
- `logFileWatchEvent(path: []const u8, change_type: []const u8)`
- `logDebug(message: []const u8)`

---

## 12. Usage Example: Integrating with Grim

```zig
const std = @import("std");
const zigzag = @import("zigzag");
const grim = @import("grim"); // Your editor code

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Initialize event loop with auto-detection
    var loop = try zigzag.EventLoop.init(allocator, .{
        .max_events = 256,
        .coalescing = .{
            .coalesce_resize = true,
            .max_coalesce_time_ms = 10,
            .max_batch_size = 32,
        },
    });
    defer loop.deinit();

    // 2. Set up signal handler for window resize
    var signal_handler = try zigzag.terminal.SignalHandler.init(&loop);
    defer signal_handler.close();
    try signal_handler.register();

    // 3. Watch stdin for keyboard input
    const stdin_fd = std.io.getStdIn().handle;
    const stdin_watch = try loop.addFd(stdin_fd, .{ .read = true });

    // 4. Set input callback
    loop.setCallback(stdin_watch, &onStdinInput);

    // 5. Add cursor blink timer
    const blink_timer = try loop.addRecurringTimer(500, &onCursorBlink);

    // 6. Set up file watcher for buffer changes
    var watcher = try zigzag.grim_editor_support.DebouncedFileWatcher.init(allocator, .{
        .debounce_ms = 50,
        .ignore_patterns = &.{".git", "target"},
    });
    defer watcher.deinit();

    // 7. Main event loop
    while (!grim.should_exit) {
        // Process events
        const had_events = try loop.tick();
        
        // Poll file changes
        if (watcher.pollChanges()) |changes| {
            for (changes) |change| {
                grim.onFileChanged(change);
            }
        } else |_| {
            // Handle error
        }
        
        if (!had_events) {
            std.time.sleep(10_000_000); // 10ms
        }
    }

    // 8. Cleanup
    loop.cancelTimer(&blink_timer);
    loop.removeFd(stdin_watch);
    signal_handler.close();
}

fn onStdinInput(watch: *const zigzag.Watch, event: zigzag.Event) void {
    _ = watch;
    if (event.type == .read_ready) {
        var buffer: [4096]u8 = undefined;
        const bytes_read = std.posix.read(event.fd, &buffer) catch return;
        grim.onKeyboardInput(buffer[0..bytes_read]);
    }
}

fn onCursorBlink(user_data: ?*anyopaque) void {
    _ = user_data;
    grim.toggleCursorVisibility();
}
```

---

## 13. Key Observations and Integration Notes

### 13.1 Architecture Strengths for Grim Integration

1. **Unified API** - Single interface across platforms eliminates platform-specific code in Grim
2. **Event Coalescing** - Window resize spam naturally coalesced (5-10ms batching)
3. **Signal Integration** - Built-in SIGWINCH → window_resize event conversion
4. **File Watching** - Grim-specific file watcher with debouncing already included
5. **Terminal Features** - PTY management, signal handling, stdio integration
6. **Multiple Backends** - Automatically uses best available (io_uring on Linux, kqueue on macOS)

### 13.2 Design Limitations

1. **Timer Callbacks** - No user_data support in current callback signature:
   ```zig
   // Current: callback doesn't receive user_data
   pub fn addTimer(self: *EventLoop, ms: u64, 
                   callback: *const fn (?*anyopaque) void) !Timer
   ```
   **Workaround:** Store context in module-level variables or use closure-like patterns

2. **Watch Callback** - Must use `setCallback()` after adding FD:
   ```zig
   const watch = try loop.addFd(fd, mask);
   loop.setCallback(watch, myCallback);  // Two-step process
   ```

3. **Event Dispatch** - Default behavior in `tick()` is automatic callback invocation
   - If no callback set, events are silently dropped
   - Manual event retrieval requires lower-level `poll()` usage

4. **Backend Conditionals** - Some backends may be disabled at compile time
   - Check build options to understand available features
   - Platform auto-detection handles fallbacks transparently

### 13.3 Integration Patterns

**Pattern 1: Manual Control (Recommended for Grim)**
```zig
var events: [256]Event = undefined;
const count = try loop.poll(&events, 0);  // Non-blocking poll
for (events[0..count]) |event| {
    // Manually handle event
    grim.onEvent(event);
}
```

**Pattern 2: Callback-Driven (Works but less flexible)**
```zig
loop.setCallback(watch, &myCallback);
_ = try loop.tick();  // Callbacks dispatched automatically
```

**Pattern 3: Mixed (Timers + Manual I/O)**
```zig
const _timer = try loop.addRecurringTimer(100, &onTimer);
loop.setCallback(stdin_watch, &onInput);  // Hybrid approach
_ = try loop.tick();
```

### 13.4 Building Grim's Phantom Event Converter

To convert ZigZag events to Phantom:

```zig
pub fn onZigzagEvent(loop: *EventLoop, event: zigzag.Event) !void {
    const phantom_event = switch (event.type) {
        .read_ready => {
            // Read from FD and convert to Phantom input event
            var buffer: [4096]u8 = undefined;
            const bytes = try std.posix.read(event.fd, &buffer);
            Phantom.createInputEvent(buffer[0..bytes])
        },
        .window_resize => {
            // Query actual terminal size
            const winsize = try getTerminalSize();
            Phantom.createResizeEvent(winsize.ws_col, winsize.ws_row)
        },
        .timer_expired => {
            Phantom.createTimerEvent(event.data.timer_id)
        },
        else => null,  // Ignore others
    };
    
    if (phantom_event) |pe| {
        grim.dispatchEvent(pe);
    }
}
```

---

## 14. Files Summary

### Core API
- **`root.zig`** (735 lines) - Main EventLoop, Event, Timer, Watch structures
- **`api.zig`** (487 lines) - Stable public API, feature detection, ConfigBuilder
- **`terminal.zig`** (249 lines) - PTY, SignalHandler, terminal event coalescing

### Editor Support
- **`grim_editor_support.zig`** (233 lines) - File watcher, LSP handler, syntax watcher
- **`pty.zig`** (200+ lines) - PTY process management, window size handling

### Platform Backends
- **`backend/epoll.zig`** - Linux epoll implementation
- **`backend/io_uring.zig`** - Linux io_uring implementation
- **`backend/kqueue.zig`** - macOS/BSD kqueue implementation
- **`backend/iocp.zig`** - Windows IOCP implementation

### Support Modules
- **`event_coalescing.zig`** - Event batching and deduplication
- **`signals.zig`** - Signal handling infrastructure
- **`file_watching.zig`** - Cross-platform file monitoring
- **`errors.zig`** - Error types and recovery strategies
- **`logging.zig`** - Event logging
- **`timer_wheel.zig`** - Timer management data structure
- **`zero_copy.zig`** - Zero-copy I/O buffers
- **`priority_queue.zig`** - Event priority handling

---

## 15. Quick Integration Checklist

For Grim integration:

- [ ] Initialize EventLoop with coalescing enabled
- [ ] Watch stdin FD with read event mask
- [ ] Set up signal handler for SIGWINCH (window resize)
- [ ] Add cursor blink timer (recurring, ~500ms)
- [ ] Create file watcher for buffer tracking
- [ ] Implement event dispatch loop using `tick()`
- [ ] Convert EventType → Phantom EventType
- [ ] Handle EventMask for keyboard input detection
- [ ] Clean up watches/timers on shutdown
- [ ] Test on Linux (io_uring), macOS (kqueue), Windows (IOCP)

