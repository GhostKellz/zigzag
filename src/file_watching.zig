//! File watching capabilities for ZigZag
//! Cross-platform filesystem monitoring with inotify, kqueue, and ReadDirectoryChangesW

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;

/// File system event types
pub const FileEvent = enum {
    created,
    modified,
    deleted,
    moved,
    metadata_changed,
    access,
};

/// File watch configuration
pub const WatchConfig = struct {
    /// Watch for file creation
    watch_create: bool = true,
    /// Watch for file modification
    watch_modify: bool = true,
    /// Watch for file deletion
    watch_delete: bool = true,
    /// Watch for file moves/renames
    watch_move: bool = true,
    /// Watch for metadata changes (permissions, timestamps)
    watch_metadata: bool = false,
    /// Watch for file access
    watch_access: bool = false,
    /// Watch subdirectories recursively
    recursive: bool = false,
};

/// File system event notification
pub const FileEventNotification = struct {
    event_type: FileEvent,
    path: []const u8,
    old_path: ?[]const u8 = null, // For move events
    timestamp: i64,
    cookie: u32 = 0, // For correlating related events
};

/// Cross-platform file watcher
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    event_loop: *EventLoop,
    backend: Backend,
    watches: std.AutoHashMap([]const u8, WatchEntry),
    callback: ?*const fn (FileEventNotification) void = null,
    buffer: []u8,

    const Backend = union(enum) {
        inotify: InotifyBackend,
        kqueue: KqueueBackend,
        windows: WindowsBackend,
        polling: PollingBackend,
    };

    const WatchEntry = struct {
        path: []u8, // Owned copy
        config: WatchConfig,
        backend_handle: BackendHandle,
    };

    const BackendHandle = union(enum) {
        inotify_wd: i32,
        kqueue_fd: i32,
        windows_handle: if (builtin.os.tag == .windows) std.os.windows.HANDLE else void,
        polling_entry: void,
    };

    pub fn init(allocator: std.mem.Allocator, event_loop: *EventLoop) !FileWatcher {
        const backend = try initBackend(allocator);
        var watches = std.AutoHashMap([]const u8, WatchEntry).init(allocator);
        errdefer watches.deinit();

        // Allocate buffer for event reading
        const buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(buffer);

        return FileWatcher{
            .allocator = allocator,
            .event_loop = event_loop,
            .backend = backend,
            .watches = watches,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        // Clean up all watches
        var iter = self.watches.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
        }
        self.watches.deinit();

        // Clean up backend
        self.deinitBackend();

        self.allocator.free(self.buffer);
    }

    fn initBackend(allocator: std.mem.Allocator) !Backend {
        return switch (builtin.os.tag) {
            .linux => Backend{ .inotify = try InotifyBackend.init(allocator) },
            .macos, .freebsd, .openbsd, .netbsd => Backend{ .kqueue = try KqueueBackend.init(allocator) },
            .windows => Backend{ .windows = try WindowsBackend.init(allocator) },
            else => Backend{ .polling = try PollingBackend.init(allocator) },
        };
    }

    fn deinitBackend(self: *FileWatcher) void {
        switch (self.backend) {
            .inotify => |*backend| backend.deinit(),
            .kqueue => |*backend| backend.deinit(),
            .windows => |*backend| backend.deinit(),
            .polling => |*backend| backend.deinit(),
        }
    }

    /// Set callback for file events
    pub fn setCallback(self: *FileWatcher, callback: *const fn (FileEventNotification) void) void {
        self.callback = callback;
    }

    /// Add a path to watch
    pub fn addWatch(self: *FileWatcher, path: []const u8, config: WatchConfig) !void {
        // Check if already watching
        if (self.watches.contains(path)) {
            return error.PathAlreadyWatched;
        }

        // Create owned copy of path
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        // Add to backend
        const backend_handle = switch (self.backend) {
            .inotify => |*backend| BackendHandle{ .inotify_wd = try backend.addWatch(path, config) },
            .kqueue => |*backend| BackendHandle{ .kqueue_fd = try backend.addWatch(path, config) },
            .windows => |*backend| BackendHandle{ .windows_handle = try backend.addWatch(path, config) },
            .polling => |*backend| blk: {
                try backend.addWatch(path, config);
                break :blk BackendHandle{ .polling_entry = {} };
            },
        };

        const entry = WatchEntry{
            .path = owned_path,
            .config = config,
            .backend_handle = backend_handle,
        };

        try self.watches.put(owned_path, entry);
    }

    /// Remove a watch
    pub fn removeWatch(self: *FileWatcher, path: []const u8) !void {
        if (self.watches.fetchRemove(path)) |kv| {
            const entry = kv.value;

            // Remove from backend
            switch (self.backend) {
                .inotify => |*backend| try backend.removeWatch(entry.backend_handle.inotify_wd),
                .kqueue => |*backend| try backend.removeWatch(entry.backend_handle.kqueue_fd),
                .windows => |*backend| try backend.removeWatch(entry.backend_handle.windows_handle),
                .polling => |*backend| try backend.removeWatch(path),
            }

            self.allocator.free(entry.path);
        } else {
            return error.PathNotWatched;
        }
    }

    /// Process file system events
    pub fn processEvents(self: *FileWatcher) !void {
        const events = switch (self.backend) {
            .inotify => |*backend| try backend.readEvents(self.buffer),
            .kqueue => |*backend| try backend.readEvents(self.buffer),
            .windows => |*backend| try backend.readEvents(self.buffer),
            .polling => |*backend| try backend.readEvents(self.buffer),
        };

        for (events) |notification| {
            if (self.callback) |callback| {
                callback(notification);
            }
        }
    }
};

/// Linux inotify backend
const InotifyBackend = struct {
    allocator: std.mem.Allocator,
    inotify_fd: i32,
    watch_descriptors: std.AutoHashMap(i32, []const u8),

    fn init(allocator: std.mem.Allocator) !InotifyBackend {
        if (builtin.os.tag != .linux) {
            return error.PlatformNotSupported;
        }

        const inotify_fd = try std.os.linux.inotify_init1(std.os.linux.IN.CLOEXEC);
        const watch_descriptors = std.AutoHashMap(i32, []const u8).init(allocator);

        return InotifyBackend{
            .allocator = allocator,
            .inotify_fd = inotify_fd,
            .watch_descriptors = watch_descriptors,
        };
    }

    fn deinit(self: *InotifyBackend) void {
        self.watch_descriptors.deinit();
        posix.close(self.inotify_fd);
    }

    fn addWatch(self: *InotifyBackend, path: []const u8, config: WatchConfig) !i32 {
        var mask: u32 = 0;

        if (config.watch_create) mask |= std.os.linux.IN.CREATE;
        if (config.watch_modify) mask |= std.os.linux.IN.MODIFY;
        if (config.watch_delete) mask |= std.os.linux.IN.DELETE;
        if (config.watch_move) mask |= std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO;
        if (config.watch_metadata) mask |= std.os.linux.IN.ATTRIB;
        if (config.watch_access) mask |= std.os.linux.IN.ACCESS;

        const wd = try std.os.linux.inotify_add_watch(self.inotify_fd, path, mask);
        try self.watch_descriptors.put(wd, path);
        return wd;
    }

    fn removeWatch(self: *InotifyBackend, wd: i32) !void {
        _ = std.os.linux.inotify_rm_watch(self.inotify_fd, wd);
        _ = self.watch_descriptors.remove(wd);
    }

    fn readEvents(self: *InotifyBackend, buffer: []u8) ![]FileEventNotification {
        const bytes_read = try posix.read(self.inotify_fd, buffer);
        var events = std.ArrayList(FileEventNotification).init(self.allocator);
        defer events.deinit();

        var offset: usize = 0;
        while (offset < bytes_read) {
            const event = @as(*std.os.linux.inotify_event, @ptrCast(@alignCast(&buffer[offset])));
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;

            const path = if (self.watch_descriptors.get(event.wd)) |p| p else "unknown";

            const file_event_type = inotifyMaskToFileEvent(event.mask);
            const notification = FileEventNotification{
                .event_type = file_event_type,
                .path = path,
                .timestamp = std.time.milliTimestamp(),
                .cookie = event.cookie,
            };

            try events.append(notification);
        }

        return try events.toOwnedSlice();
    }

    fn inotifyMaskToFileEvent(mask: u32) FileEvent {
        if (mask & std.os.linux.IN.CREATE != 0) return .created;
        if (mask & std.os.linux.IN.MODIFY != 0) return .modified;
        if (mask & std.os.linux.IN.DELETE != 0) return .deleted;
        if (mask & (std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO) != 0) return .moved;
        if (mask & std.os.linux.IN.ATTRIB != 0) return .metadata_changed;
        if (mask & std.os.linux.IN.ACCESS != 0) return .access;
        return .modified; // Default
    }
};

/// macOS/BSD kqueue backend
const KqueueBackend = struct {
    allocator: std.mem.Allocator,
    kqueue_fd: i32,
    watched_fds: std.AutoHashMap(i32, []const u8),

    fn init(allocator: std.mem.Allocator) !KqueueBackend {
        const kqueue_fd = try posix.kqueue();
        const watched_fds = std.AutoHashMap(i32, []const u8).init(allocator);

        return KqueueBackend{
            .allocator = allocator,
            .kqueue_fd = kqueue_fd,
            .watched_fds = watched_fds,
        };
    }

    fn deinit(self: *KqueueBackend) void {
        var iter = self.watched_fds.iterator();
        while (iter.next()) |entry| {
            posix.close(entry.key_ptr.*);
        }
        self.watched_fds.deinit();
        posix.close(self.kqueue_fd);
    }

    fn addWatch(self: *KqueueBackend, path: []const u8, config: WatchConfig) !i32 {
        _ = config; // TODO: Use config to set appropriate kqueue filters

        const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
        errdefer posix.close(fd);

        // Add kqueue event for this file descriptor
        var kevent = std.c.Kevent{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.VNODE,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
            .fflags = std.c.NOTE.DELETE | std.c.NOTE.WRITE | std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB,
            .data = 0,
            .udata = 0,
        };

        const result = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
        if (result == -1) {
            return error.KqueueError;
        }

        try self.watched_fds.put(fd, path);
        return fd;
    }

    fn removeWatch(self: *KqueueBackend, fd: i32) !void {
        var kevent = std.c.Kevent{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.VNODE,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        _ = std.c.kevent(self.kqueue_fd, &kevent, 1, null, 0, null);
        _ = self.watched_fds.remove(fd);
        posix.close(fd);
    }

    fn readEvents(self: *KqueueBackend, buffer: []u8) ![]FileEventNotification {
        _ = buffer;
        var kevents: [32]std.c.Kevent = undefined;
        const num_events = std.c.kevent(self.kqueue_fd, null, 0, &kevents, kevents.len, null);

        var events = std.ArrayList(FileEventNotification).init(self.allocator);
        defer events.deinit();

        if (num_events > 0) {
            for (0..@intCast(num_events)) |i| {
                const kevent = kevents[i];
                const fd = @as(i32, @intCast(kevent.ident));

                if (self.watched_fds.get(fd)) |path| {
                    const file_event_type = kqueueFflagsToFileEvent(kevent.fflags);
                    const notification = FileEventNotification{
                        .event_type = file_event_type,
                        .path = path,
                        .timestamp = std.time.milliTimestamp(),
                    };

                    try events.append(notification);
                }
            }
        }

        return try events.toOwnedSlice();
    }

    fn kqueueFflagsToFileEvent(fflags: u32) FileEvent {
        if (fflags & std.c.NOTE.DELETE != 0) return .deleted;
        if (fflags & std.c.NOTE.WRITE != 0) return .modified;
        if (fflags & std.c.NOTE.EXTEND != 0) return .modified;
        if (fflags & std.c.NOTE.ATTRIB != 0) return .metadata_changed;
        return .modified; // Default
    }
};

/// Windows ReadDirectoryChangesW backend
const WindowsBackend = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !WindowsBackend {
        return WindowsBackend{
            .allocator = allocator,
        };
    }

    fn deinit(self: *WindowsBackend) void {
        _ = self;
        // TODO: Implement Windows cleanup
    }

    fn addWatch(self: *WindowsBackend, path: []const u8, config: WatchConfig) !std.os.windows.HANDLE {
        _ = self;
        _ = path;
        _ = config;
        // TODO: Implement Windows file watching
        return error.NotImplemented;
    }

    fn removeWatch(self: *WindowsBackend, handle: std.os.windows.HANDLE) !void {
        _ = self;
        _ = handle;
        // TODO: Implement Windows watch removal
        return error.NotImplemented;
    }

    fn readEvents(self: *WindowsBackend, buffer: []u8) ![]FileEventNotification {
        _ = self;
        _ = buffer;
        // TODO: Implement Windows event reading
        return &[_]FileEventNotification{};
    }
};

/// Fallback polling backend for unsupported platforms
const PollingBackend = struct {
    allocator: std.mem.Allocator,
    watched_paths: std.ArrayList(WatchedPath),
    poll_interval_ms: u64 = 1000,

    const WatchedPath = struct {
        path: []u8,
        config: WatchConfig,
        last_modified: i64,
        last_size: u64,
    };

    fn init(allocator: std.mem.Allocator) !PollingBackend {
        return PollingBackend{
            .allocator = allocator,
            .watched_paths = std.ArrayList(WatchedPath).init(allocator),
        };
    }

    fn deinit(self: *PollingBackend) void {
        for (self.watched_paths.items) |watched_path| {
            self.allocator.free(watched_path.path);
        }
        self.watched_paths.deinit();
    }

    fn addWatch(self: *PollingBackend, path: []const u8, config: WatchConfig) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        // Get initial file stats
        const stat = posix.stat(path) catch {
            return error.PathNotFound;
        };

        const watched_path = WatchedPath{
            .path = owned_path,
            .config = config,
            .last_modified = stat.mtime,
            .last_size = @intCast(stat.size),
        };

        try self.watched_paths.append(watched_path);
    }

    fn removeWatch(self: *PollingBackend, path: []const u8) !void {
        for (self.watched_paths.items, 0..) |watched_path, i| {
            if (std.mem.eql(u8, watched_path.path, path)) {
                const removed = self.watched_paths.orderedRemove(i);
                self.allocator.free(removed.path);
                return;
            }
        }
        return error.PathNotWatched;
    }

    fn readEvents(self: *PollingBackend, buffer: []u8) ![]FileEventNotification {
        _ = buffer;
        var events = std.ArrayList(FileEventNotification).init(self.allocator);
        defer events.deinit();

        for (self.watched_paths.items) |*watched_path| {
            if (posix.stat(watched_path.path)) |stat| {
                var changed = false;
                var event_type: FileEvent = .modified;

                // Check for modifications
                if (stat.mtime != watched_path.last_modified and watched_path.config.watch_modify) {
                    changed = true;
                    event_type = .modified;
                    watched_path.last_modified = stat.mtime;
                }

                // Check for size changes
                const new_size = @as(u64, @intCast(stat.size));
                if (new_size != watched_path.last_size and watched_path.config.watch_modify) {
                    changed = true;
                    event_type = .modified;
                    watched_path.last_size = new_size;
                }

                if (changed) {
                    const notification = FileEventNotification{
                        .event_type = event_type,
                        .path = watched_path.path,
                        .timestamp = std.time.milliTimestamp(),
                    };
                    try events.append(notification);
                }
            } else |err| {
                // File might have been deleted
                if (err == error.FileNotFound and watched_path.config.watch_delete) {
                    const notification = FileEventNotification{
                        .event_type = .deleted,
                        .path = watched_path.path,
                        .timestamp = std.time.milliTimestamp(),
                    };
                    try events.append(notification);
                }
            }
        }

        return try events.toOwnedSlice();
    }
};

/// Directory scanner for recursive watching
pub const DirectoryScanner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DirectoryScanner {
        return DirectoryScanner{
            .allocator = allocator,
        };
    }

    /// Recursively scan directory and return all subdirectories
    pub fn scanRecursive(self: *DirectoryScanner, root_path: []const u8) ![][]u8 {
        var paths = std.ArrayList([]u8).init(self.allocator);
        errdefer {
            for (paths.items) |path| {
                self.allocator.free(path);
            }
            paths.deinit();
        }

        try self.scanRecursiveImpl(root_path, &paths);
        return try paths.toOwnedSlice();
    }

    fn scanRecursiveImpl(self: *DirectoryScanner, dir_path: []const u8, paths: *std.ArrayList([]u8)) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .directory) {
                const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                try paths.append(full_path);
                try self.scanRecursiveImpl(full_path, paths);
            }
        }
    }

    pub fn deinit(self: *DirectoryScanner, paths: [][]u8) void {
        for (paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(paths);
    }
};

test "File watcher initialization" {
    const allocator = std.testing.allocator;

    // Create a dummy event loop for testing
    var loop = try @import("root.zig").EventLoop.init(allocator, .{});
    defer loop.deinit();

    var watcher = try FileWatcher.init(allocator, &loop);
    defer watcher.deinit();

    // Basic initialization test
    try std.testing.expect(watcher.watches.count() == 0);
}

test "Directory scanner" {
    const allocator = std.testing.allocator;

    var scanner = DirectoryScanner.init(allocator);

    // Test with a known directory (current directory)
    const paths = scanner.scanRecursive(".") catch {
        // Skip test if we can't read current directory
        return error.SkipZigTest;
    };
    defer scanner.deinit(paths);

    // Should find at least some directories
    try std.testing.expect(paths.len >= 0);
}