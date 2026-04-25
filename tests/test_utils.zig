//! Platform-independent test utilities for ZigZag
//!
//! Provides cross-platform helpers for test code.

const std = @import("std");
const builtin = @import("builtin");
const zigzag = @import("zigzag");
const posix = std.posix;

pub const Fd = if (supportsPosixPipe()) posix.fd_t else i32;

/// Create a pipe in a platform-independent way
pub fn createPipe() ![2]Fd {
    if (builtin.os.tag == .linux) {
        var fds: [2]i32 = undefined;
        const rc = std.os.linux.pipe(&fds);
        if (rc != 0) {
            return posix.unexpectedErrno(@enumFromInt(rc));
        }
        return fds;
    } else if (comptime supportsPosixPipe()) {
        return posix.pipe();
    } else {
        return error.PlatformNotSupported;
    }
}

/// Close both ends of a pipe
pub fn closePipe(fds: [2]Fd) void {
    if (comptime supportsPosixPipe()) {
        std.Io.Threaded.closeFd(fds[0]);
        std.Io.Threaded.closeFd(fds[1]);
    }
}

/// Check if current platform supports POSIX pipe
pub fn supportsPosixPipe() bool {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => true,
        .freebsd, .openbsd, .netbsd, .dragonfly => true,
        .linux => true,
        else => false,
    };
}

/// Check if current platform supports terminal features
pub fn supportsTerminal() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd => true,
        else => false,
    };
}

/// Skip test on unsupported platforms
pub fn skipOnUnsupportedPlatform() error{SkipZigTest}!void {
    if (!supportsPosixPipe()) {
        return error.SkipZigTest;
    }
}

/// Skip terminal tests on unsupported platforms
pub fn skipTerminalTest() error{SkipZigTest}!void {
    if (!supportsTerminal()) {
        return error.SkipZigTest;
    }
}

/// Get monotonic time in milliseconds (cross-platform)
pub fn getMonotonicMs() i64 {
    return zigzag.time.getMonotonicMs();
}

/// Get monotonic time in nanoseconds (cross-platform)
pub fn getMonotonicNs() i64 {
    return @intCast(zigzag.time.getMonotonicNs());
}

/// Sleep for a given number of nanoseconds (cross-platform)
pub fn sleepNs(ns: u64) void {
    zigzag.time.sleep(ns);
}

/// Read from a file descriptor (cross-platform helper for tests)
pub fn readFromFd(fd: Fd, buf: []u8) !usize {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.read(fd, buf.ptr, buf.len);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc < 0) {
            return posix.unexpectedErrno(@enumFromInt(-signed_rc));
        }
        return rc;
    } else if (comptime supportsPosixPipe()) {
        const result = std.c.read(fd, buf.ptr, buf.len);
        if (result < 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }
        return @intCast(result);
    } else {
        return error.PlatformNotSupported;
    }
}

/// Write to a file descriptor (Linux-specific helper for tests)
pub fn writeToFd(fd: Fd, data: []const u8) !usize {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.write(fd, data.ptr, data.len);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc < 0) {
            return posix.unexpectedErrno(@enumFromInt(-signed_rc));
        }
        return rc;
    } else if (comptime supportsPosixPipe()) {
        const result = std.c.write(fd, data.ptr, data.len);
        if (result < 0) {
            return posix.unexpectedErrno(@enumFromInt(std.c._errno().*));
        }
        return @intCast(result);
    } else {
        return error.PlatformNotSupported;
    }
}

test "createPipe" {
    if (!supportsPosixPipe()) return error.SkipZigTest;

    const fds = try createPipe();
    defer closePipe(fds);

    // Write and read test
    const msg = "test";
    _ = try writeToFd(fds[1], msg);

    var buf: [4]u8 = undefined;
    const n = try readFromFd(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings(msg, &buf);
}
