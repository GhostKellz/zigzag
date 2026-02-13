//! Cross-platform time utilities for ZigZag
//! Provides portable monotonic clock access for all supported platforms

const std = @import("std");
const builtin = @import("builtin");

/// Sleep for the specified number of nanoseconds
pub fn sleep(ns: u64) void {
    if (builtin.os.tag == .linux) {
        const sec: isize = @intCast(ns / std.time.ns_per_s);
        const nsec: isize = @intCast(ns % std.time.ns_per_s);
        var req = std.os.linux.timespec{ .sec = sec, .nsec = nsec };
        var rem: std.os.linux.timespec = undefined;
        while (true) {
            const rc = std.os.linux.nanosleep(&req, &rem);
            if (rc == 0) break;
            // Interrupted by signal, continue with remaining time
            req = rem;
        }
    } else {
        // Use libc for other POSIX platforms
        const sec: std.c.time_t = @intCast(ns / std.time.ns_per_s);
        const nsec: c_long = @intCast(ns % std.time.ns_per_s);
        var req = std.c.timespec{ .sec = sec, .nsec = nsec };
        var rem: std.c.timespec = undefined;
        while (std.c.nanosleep(&req, &rem) != 0) {
            req = rem;
        }
    }
}

/// Returns the current monotonic timestamp as a timespec
/// Works across Linux, macOS, and BSD platforms
pub fn getMonotonicTime() Timespec {
    if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return .{
            .sec = ts.sec,
            .nsec = ts.nsec,
        };
    } else {
        // Use libc for other POSIX platforms (macOS, BSD, etc.)
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return .{
            .sec = ts.sec,
            .nsec = ts.nsec,
        };
    }
}

/// Returns current time in milliseconds since some unspecified epoch
pub fn getMonotonicMs() i64 {
    const ts = getMonotonicTime();
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Returns current time in nanoseconds since some unspecified epoch
pub fn getMonotonicNs() i128 {
    const ts = getMonotonicTime();
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Platform-independent timespec
pub const Timespec = struct {
    sec: isize,
    nsec: isize,
};

/// Simple timer for measuring elapsed time
/// Replaces std.time.Timer which was removed in Zig 0.16.0
pub const Timer = struct {
    start_ns: i128,

    pub fn start() Timer {
        return .{ .start_ns = getMonotonicNs() };
    }

    pub fn read(self: *const Timer) u64 {
        const now = getMonotonicNs();
        const elapsed = now - self.start_ns;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }

    pub fn reset(self: *Timer) void {
        self.start_ns = getMonotonicNs();
    }
};

test "Timer basic functionality" {
    var timer = Timer.start();
    sleep(1_000_000); // 1ms
    const elapsed = timer.read();
    try std.testing.expect(elapsed >= 1_000_000); // At least 1ms
    try std.testing.expect(elapsed < 100_000_000); // Less than 100ms

    timer.reset();
    const after_reset = timer.read();
    try std.testing.expect(after_reset < elapsed);
}

test "getMonotonicMs" {
    const t1 = getMonotonicMs();
    sleep(2_000_000); // 2ms
    const t2 = getMonotonicMs();
    try std.testing.expect(t2 >= t1);
    try std.testing.expect(t2 - t1 >= 1); // At least 1ms difference
}
