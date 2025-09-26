//! PTY (Pseudo Terminal) management for terminal emulators
//! Handles process lifecycle, signal forwarding, and PTY operations

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

/// PTY configuration
pub const PtyConfig = struct {
    /// Initial window size
    cols: u16 = 80,
    rows: u16 = 24,
    /// Shell to execute (default to user's shell)
    shell: ?[]const u8 = null,
    /// Working directory
    cwd: ?[]const u8 = null,
    /// Environment variables (null to inherit)
    env: ?[]const []const u8 = null,
    /// Enable raw mode
    raw_mode: bool = true,
};

/// Window size for PTY
pub const WinSize = struct {
    cols: u16,
    rows: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,

    fn toWinsize(self: WinSize) std.os.linux.winsize {
        return std.os.linux.winsize{
            .ws_row = self.rows,
            .ws_col = self.cols,
            .ws_xpixel = self.xpixel,
            .ws_ypixel = self.ypixel,
        };
    }
};

/// PTY process information
pub const PtyProcess = struct {
    /// Process ID
    pid: posix.pid_t,
    /// Master PTY file descriptor
    master_fd: i32,
    /// Current window size
    window_size: WinSize,
    /// Process start time
    start_time: i64,
    /// Exit status (valid only after process ends)
    exit_status: ?i32 = null,
    /// Whether process has exited
    exited: bool = false,
};

/// PTY manager
pub const PtyManager = struct {
    allocator: std.mem.Allocator,
    processes: std.AutoHashMap(posix.pid_t, PtyProcess),

    pub fn init(allocator: std.mem.Allocator) PtyManager {
        return PtyManager{
            .allocator = allocator,
            .processes = std.AutoHashMap(posix.pid_t, PtyProcess).init(allocator),
        };
    }

    pub fn deinit(self: *PtyManager) void {
        // Close all PTY file descriptors
        var iter = self.processes.iterator();
        while (iter.next()) |entry| {
            posix.close(entry.value_ptr.master_fd);
        }
        self.processes.deinit();
    }

    /// Create a new PTY and spawn a process
    pub fn spawn(self: *PtyManager, config: PtyConfig) !PtyProcess {
        // Open PTY master
        const master_fd = try openPtyMaster();
        errdefer posix.close(master_fd);

        // Get slave name
        var slave_name_buf: [256]u8 = undefined;
        const slave_name = try getPtySlveName(master_fd, &slave_name_buf);

        // Set initial window size
        const winsize = WinSize{
            .cols = config.cols,
            .rows = config.rows,
        };
        try setPtyWindowSize(master_fd, winsize);

        // Fork process
        const pid = try posix.fork();

        if (pid == 0) {
            // Child process
            try setupChildProcess(slave_name, config);
            // This should not return
            std.process.exit(1);
        } else {
            // Parent process
            const process = PtyProcess{
                .pid = pid,
                .master_fd = master_fd,
                .window_size = winsize,
                .start_time = std.time.milliTimestamp(),
            };

            try self.processes.put(pid, process);
            return process;
        }
    }

    /// Resize PTY window
    pub fn resize(self: *PtyManager, pid: posix.pid_t, new_size: WinSize) !void {
        if (self.processes.getPtr(pid)) |process| {
            try setPtyWindowSize(process.master_fd, new_size);
            process.window_size = new_size;

            // Send SIGWINCH to the process
            try posix.kill(pid, posix.SIG.WINCH);
        } else {
            return error.ProcessNotFound;
        }
    }

    /// Send signal to process
    pub fn signal(self: *PtyManager, pid: posix.pid_t, sig: i32) !void {
        if (self.processes.contains(pid)) {
            try posix.kill(pid, sig);
        } else {
            return error.ProcessNotFound;
        }
    }

    /// Wait for process to exit (non-blocking)
    pub fn checkExit(self: *PtyManager, pid: posix.pid_t) !?i32 {
        if (self.processes.getPtr(pid)) |process| {
            if (process.exited) {
                return process.exit_status;
            }

            // Check if process has exited
            var status: i32 = undefined;
            const result = std.c.waitpid(pid, &status, std.c.WNOHANG);

            if (result == pid) {
                // Process has exited
                process.exited = true;
                process.exit_status = status;
                posix.close(process.master_fd);
                return status;
            } else if (result == 0) {
                // Process still running
                return null;
            } else {
                // Error
                return error.WaitError;
            }
        } else {
            return error.ProcessNotFound;
        }
    }

    /// Terminate process
    pub fn terminate(self: *PtyManager, pid: posix.pid_t, force: bool) !void {
        if (self.processes.getPtr(pid)) |process| {
            if (process.exited) {
                return; // Already exited
            }

            // Send SIGTERM first
            try posix.kill(pid, posix.SIG.TERM);

            if (force) {
                // Give process time to clean up
                std.time.sleep(100_000_000); // 100ms

                // Check if still running
                if (try self.checkExit(pid) == null) {
                    // Force kill
                    try posix.kill(pid, posix.SIG.KILL);
                }
            }
        } else {
            return error.ProcessNotFound;
        }
    }

    /// Get process information
    pub fn getProcess(self: *const PtyManager, pid: posix.pid_t) ?PtyProcess {
        return self.processes.get(pid);
    }

    /// Get all active processes
    pub fn getActiveProcesses(self: *const PtyManager, allocator: std.mem.Allocator) ![]posix.pid_t {
        var active = std.ArrayList(posix.pid_t).init(allocator);
        defer active.deinit();

        var iter = self.processes.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.exited) {
                try active.append(allocator, entry.key_ptr.*);
            }
        }

        return try active.toOwnedSlice(allocator);
    }
};

/// Open PTY master (platform-specific)
fn openPtyMaster() !i32 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const fd = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR }, 0);
            errdefer posix.close(fd);

            // Grant access to slave
            if (c.grantpt(fd) != 0) {
                return error.GrantPtFailed;
            }

            // Unlock slave
            if (c.unlockpt(fd) != 0) {
                return error.UnlockPtFailed;
            }

            break :blk fd;
        },
        .macos, .freebsd, .openbsd, .netbsd => blk: {
            break :blk try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR }, 0);
        },
        else => error.UnsupportedPlatform,
    };
}

/// Get PTY slave name
fn getPtySlveName(master_fd: i32, buffer: []u8) ![]const u8 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const name_ptr = c.ptsname(master_fd);
            if (name_ptr == null) {
                return error.PtsNameFailed;
            }

            const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));
            if (name.len >= buffer.len) {
                return error.BufferTooSmall;
            }

            @memcpy(buffer[0..name.len], name);
            break :blk buffer[0..name.len];
        },
        .macos, .freebsd, .openbsd, .netbsd => blk: {
            const name_ptr = c.ptsname(master_fd);
            if (name_ptr == null) {
                return error.PtsNameFailed;
            }

            const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));
            if (name.len >= buffer.len) {
                return error.BufferTooSmall;
            }

            @memcpy(buffer[0..name.len], name);
            break :blk buffer[0..name.len];
        },
        else => error.UnsupportedPlatform,
    };
}

/// Set PTY window size
fn setPtyWindowSize(fd: i32, size: WinSize) !void {
    const winsize = size.toWinsize();
    const result = std.c.ioctl(fd, std.os.linux.T.IOCSWINSZ, @intFromPtr(&winsize));
    if (result != 0) {
        return error.IoctlFailed;
    }
}

/// Setup child process (runs in child after fork)
fn setupChildProcess(slave_name: []const u8, config: PtyConfig) !void {
    // Create new session
    _ = c.setsid();

    // Open slave PTY
    const slave_fd = try posix.open(slave_name, .{ .ACCMODE = .RDWR }, 0);
    defer posix.close(slave_fd);

    // Make it controlling terminal
    if (builtin.os.tag == .linux) {
        const result = std.c.ioctl(slave_fd, std.os.linux.T.IOCSCTTY, @as(c_int, 0));
        if (result != 0) {
            return error.IoctlFailed;
        }
    }

    // Duplicate slave FD to stdin, stdout, stderr
    try posix.dup2(slave_fd, posix.STDIN_FILENO);
    try posix.dup2(slave_fd, posix.STDOUT_FILENO);
    try posix.dup2(slave_fd, posix.STDERR_FILENO);

    // Set raw mode if requested
    if (config.raw_mode) {
        try setRawMode(posix.STDIN_FILENO);
    }

    // Change working directory
    if (config.cwd) |cwd| {
        try posix.chdir(cwd);
    }

    // Set environment
    var env_map = std.process.EnvMap.init(std.heap.page_allocator);
    defer env_map.deinit();

    if (config.env) |env_vars| {
        for (env_vars) |env_var| {
            if (std.mem.indexOf(u8, env_var, "=")) |eq_pos| {
                const key = env_var[0..eq_pos];
                const value = env_var[eq_pos + 1 ..];
                try env_map.put(key, value);
            }
        }
    } else {
        // Inherit current environment
        try env_map.copyFrom(std.process.getEnvMap(std.heap.page_allocator));
    }

    // Determine shell
    const shell = config.shell orelse blk: {
        break :blk env_map.get("SHELL") orelse "/bin/sh";
    };

    // Execute shell
    const argv = [_][]const u8{ shell, "-i" };
    const result = posix.execvpe(shell, &argv, &env_map);
    _ = result; // execvpe should not return on success
}

/// Set terminal to raw mode
fn setRawMode(fd: i32) !void {
    var termios: std.c.termios = undefined;
    const result = std.c.tcgetattr(fd, &termios);
    if (result != 0) {
        return error.TcGetAttrFailed;
    }

    // Make raw
    std.c.cfmakeraw(&termios);

    const set_result = std.c.tcsetattr(fd, std.c.TCSA.NOW, &termios);
    if (set_result != 0) {
        return error.TcSetAttrFailed;
    }
}

test "PTY manager basic operations" {
    const allocator = std.testing.allocator;

    var manager = PtyManager.init(allocator);
    defer manager.deinit();

    // Test initialization
    try std.testing.expect(manager.processes.count() == 0);

    // Note: We can't easily test actual PTY creation in a unit test
    // without potentially spawning real processes, so we test the structure
}

test "WinSize conversion" {
    const winsize = WinSize{
        .cols = 80,
        .rows = 24,
        .xpixel = 640,
        .ypixel = 480,
    };

    const linux_winsize = winsize.toWinsize();
    try std.testing.expectEqual(@as(u16, 24), linux_winsize.ws_row);
    try std.testing.expectEqual(@as(u16, 80), linux_winsize.ws_col);
    try std.testing.expectEqual(@as(u16, 640), linux_winsize.ws_xpixel);
    try std.testing.expectEqual(@as(u16, 480), linux_winsize.ws_ypixel);
}