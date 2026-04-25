# Timers

Timer management for the ZigZag event loop.

## Timer

```zig
pub const Timer = struct {
    id: u32,
    deadline: i64,
    interval: ?u64,
    type: TimerType,
    callback: *const fn (?*anyopaque) void,
    user_data: ?*anyopaque,
};
```

## TimerType

```zig
pub const TimerType = enum {
    one_shot,
    recurring,
};
```

## Methods

### addTimer

```zig
pub fn addTimer(
    self: *EventLoop,
    ms: u64,
    callback: *const fn (?*anyopaque) void
) !Timer
```

Add a one-shot timer that fires after `ms` milliseconds.

### addRecurringTimer

```zig
pub fn addRecurringTimer(
    self: *EventLoop,
    interval_ms: u64,
    callback: *const fn (?*anyopaque) void
) !Timer
```

Add a recurring timer that fires every `interval_ms` milliseconds.

### cancelTimer

```zig
pub fn cancelTimer(self: *EventLoop, timer: *const Timer) void
```

Cancel a timer.

## Example

```zig
fn timerCallback(user_data: ?*anyopaque) void {
    _ = user_data;
    std.debug.print("Timer fired!\n", .{});
}

// One-shot timer (5 seconds)
const timer = try loop.addTimer(5000, timerCallback);

// Recurring timer (1 second interval)
const heartbeat = try loop.addRecurringTimer(1000, timerCallback);

// Cancel
loop.cancelTimer(&timer);
```
