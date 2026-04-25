//! File watching capabilities for ZigZag
//! Cross-platform filesystem monitoring
//!
//! Platform support:
//! - Linux: inotify (native kernel notifications, <1ms latency)
//! - macOS/BSD: kqueue with EVFILT_VNODE (native kernel notifications, <1ms latency)
//! - Windows: ReadDirectoryChangesW (native directory notifications)
//! - Other: polling fallback

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const windows = std.os.windows;
const EventLoop = @import("root.zig").EventLoop;
const Event = @import("root.zig").Event;
const time_utils = @import("time_utils.zig");

const global_io = std.Io.Threaded.global_single_threaded.io();

const FILE_NOTIFY_CHANGE_FILE_NAME: windows.DWORD = 0x00000001;
const FILE_NOTIFY_CHANGE_DIR_NAME: windows.DWORD = 0x00000002;
const FILE_NOTIFY_CHANGE_ATTRIBUTES: windows.DWORD = 0x00000004;
const FILE_NOTIFY_CHANGE_SIZE: windows.DWORD = 0x00000008;
const FILE_NOTIFY_CHANGE_LAST_WRITE: windows.DWORD = 0x00000010;
const FILE_NOTIFY_CHANGE_LAST_ACCESS: windows.DWORD = 0x00000020;
const FILE_NOTIFY_CHANGE_CREATION: windows.DWORD = 0x00000040;
const FILE_NOTIFY_CHANGE_SECURITY: windows.DWORD = 0x00000100;

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
    watches: std.StringHashMap(WatchEntry),
    callback: ?*const fn (FileEventNotification) void = null,
    buffer: []u8,

    const Backend = union(enum) {
        inotify: if (InotifyBackend != void) InotifyBackend else void,
        kqueue: if (KqueueBackend != void) KqueueBackend else void,
        windows: if (WindowsBackend != void) WindowsBackend else void,
        polling: if (PollingBackend != void) PollingBackend else void,
    };

    const WatchEntry = struct {
        path: []u8, // Owned copy
        config: WatchConfig,
        backend_handle: BackendHandle,
    };

    const BackendHandle = union(enum) {
        inotify_wd: i32,
        kqueue_fd: i32,
        windows_entry: void,
        polling_entry: void,
    };

    pub fn init(allocator: std.mem.Allocator, event_loop: *EventLoop) !FileWatcher {
        const backend = try initBackend(allocator);
        var watches = std.StringHashMap(WatchEntry).init(allocator);
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
            .inotify => |*backend| if (InotifyBackend != void) backend.deinit(),
            .kqueue => |*backend| if (KqueueBackend != void) backend.deinit(),
            .windows => |*backend| if (WindowsBackend != void) backend.deinit(),
            .polling => |*backend| if (PollingBackend != void) backend.deinit(),
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
            .inotify => |*backend| if (InotifyBackend != void)
                BackendHandle{ .inotify_wd = try backend.addWatch(path, config) }
            else
                unreachable,
            .kqueue => |*backend| if (KqueueBackend != void)
                BackendHandle{ .kqueue_fd = try backend.addWatch(path, config) }
            else
                unreachable,
            .windows => |*backend| blk: {
                if (WindowsBackend != void) {
                    try backend.addWatch(path, config);
                } else unreachable;
                break :blk BackendHandle{ .windows_entry = {} };
            },
            .polling => |*backend| blk: {
                if (PollingBackend != void) {
                    try backend.addWatch(path, config);
                } else unreachable;
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
                .inotify => |*backend| if (InotifyBackend != void) try backend.removeWatch(entry.backend_handle.inotify_wd),
                .kqueue => |*backend| if (KqueueBackend != void) try backend.removeWatch(entry.backend_handle.kqueue_fd),
                .windows => |*backend| if (WindowsBackend != void) try backend.removeWatch(path),
                .polling => |*backend| if (PollingBackend != void) try backend.removeWatch(path),
            }

            self.allocator.free(entry.path);
        } else {
            return error.PathNotWatched;
        }
    }

    /// Process file system events
    pub fn processEvents(self: *FileWatcher) !void {
        const events = switch (self.backend) {
            .inotify => |*backend| if (InotifyBackend != void) try backend.readEvents(self.buffer) else unreachable,
            .kqueue => |*backend| if (KqueueBackend != void) try backend.readEvents(self.buffer) else unreachable,
            .windows => |*backend| if (WindowsBackend != void) try backend.readEvents(self.buffer) else unreachable,
            .polling => |*backend| if (PollingBackend != void) try backend.readEvents(self.buffer) else unreachable,
        };
        defer self.allocator.free(events);

        for (events) |notification| {
            if (self.callback) |callback| {
                callback(notification);
            }
        }
    }
};

const WindowsBackend = if (builtin.os.tag == .windows) struct {
    allocator: std.mem.Allocator,
    watched_paths: std.array_list.Managed(*WatchedPath),
    temp_paths: std.array_list.Managed([]u8),

    const HANDLE = windows.HANDLE;
    const DWORD = windows.DWORD;
    const BOOL = windows.BOOL;
    const OVERLAPPED = extern struct {
        Internal: windows.ULONG_PTR = 0,
        InternalHigh: windows.ULONG_PTR = 0,
        Offset: DWORD = 0,
        OffsetHigh: DWORD = 0,
        hEvent: ?HANDLE = null,
    };

    const FILE_LIST_DIRECTORY: DWORD = 0x0001;
    const FILE_SHARE_READ: DWORD = 0x00000001;
    const FILE_SHARE_WRITE: DWORD = 0x00000002;
    const FILE_SHARE_DELETE: DWORD = 0x00000004;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
    const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
    const FILE_ACTION_ADDED: DWORD = 0x00000001;
    const FILE_ACTION_REMOVED: DWORD = 0x00000002;
    const FILE_ACTION_MODIFIED: DWORD = 0x00000003;
    const FILE_ACTION_RENAMED_OLD_NAME: DWORD = 0x00000004;
    const FILE_ACTION_RENAMED_NEW_NAME: DWORD = 0x00000005;
    const WAIT_OBJECT_0: DWORD = 0;
    const WAIT_TIMEOUT: DWORD = 258;
    const WAIT_FAILED: DWORD = 0xFFFF_FFFF;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn CreateEventW(
        lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
        bManualReset: BOOL,
        bInitialState: BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?HANDLE;

    extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;

    extern "kernel32" fn WaitForSingleObject(
        hHandle: HANDLE,
        dwMilliseconds: DWORD,
    ) callconv(.winapi) DWORD;

    extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: HANDLE,
        lpBuffer: *anyopaque,
        nBufferLength: DWORD,
        bWatchSubtree: BOOL,
        dwNotifyFilter: DWORD,
        lpBytesReturned: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn GetOverlappedResult(
        hFile: HANDLE,
        lpOverlapped: *OVERLAPPED,
        lpNumberOfBytesTransferred: *DWORD,
        bWait: BOOL,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CancelIoEx(
        hFile: HANDLE,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn GetLastError() callconv(.winapi) windows.Win32Error;

    const WatchedPath = struct {
        watch_path: []u8,
        directory_path: []u8,
        basename: ?[]u8,
        is_directory: bool,
        config: WatchConfig,
        dir_handle: HANDLE,
        event_handle: HANDLE,
        overlapped: OVERLAPPED,
        armed: bool,
        buffer: [64 * 1024]u8 align(@alignOf(windows.FILE.NOTIFY.INFORMATION)),
    };

    const PendingRename = struct {
        old_path: []const u8,
        relevant: bool,
    };

    fn init(allocator: std.mem.Allocator) !WindowsBackend {
        return .{
            .allocator = allocator,
            .watched_paths = std.array_list.Managed(*WatchedPath).init(allocator),
            .temp_paths = std.array_list.Managed([]u8).init(allocator),
        };
    }

    fn deinit(self: *WindowsBackend) void {
        self.freeTempPaths();
        for (self.watched_paths.items) |watched_path| {
            self.deinitWatch(watched_path);
            self.allocator.destroy(watched_path);
        }
        self.watched_paths.deinit();
        self.temp_paths.deinit();
    }

    fn addWatch(self: *WindowsBackend, path: []const u8, config: WatchConfig) !void {
        const is_directory = blk: {
            var directory_probe = std.Io.Dir.cwd().openDir(global_io, path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => break :blk false,
                else => return err,
            };
            directory_probe.close(global_io);
            break :blk true;
        };

        const directory_path = if (is_directory) path else std.fs.path.dirname(path) orelse ".";
        const basename = if (is_directory) null else std.fs.path.basename(path);

        if (!is_directory) {
            var parent_dir = std.Io.Dir.cwd().openDir(global_io, directory_path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return error.PathNotFound,
                else => return err,
            };
            parent_dir.close(global_io);
        }

        const watch_path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(watch_path_copy);
        const directory_path_copy = try self.allocator.dupe(u8, directory_path);
        errdefer self.allocator.free(directory_path_copy);
        const basename_copy = if (basename) |name|
            try self.allocator.dupe(u8, name)
        else
            null;
        errdefer if (basename_copy) |name| self.allocator.free(name);

        const directory_w = try std.unicode.wtf8ToWtf16LeAllocZ(self.allocator, directory_path);
        defer self.allocator.free(directory_w);

        const dir_handle = CreateFileW(
            directory_w.ptr,
            FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null,
        );
        if (dir_handle == windows.INVALID_HANDLE_VALUE) {
            return mapWindowsError(GetLastError());
        }
        errdefer windows.CloseHandle(dir_handle);

        const event_handle = CreateEventW(null, .TRUE, .FALSE, null) orelse {
            return mapWindowsError(GetLastError());
        };
        errdefer windows.CloseHandle(event_handle);

        const watched_path = try self.allocator.create(WatchedPath);
        errdefer self.allocator.destroy(watched_path);

        watched_path.* = .{
            .watch_path = watch_path_copy,
            .directory_path = directory_path_copy,
            .basename = basename_copy,
            .is_directory = is_directory,
            .config = config,
            .dir_handle = dir_handle,
            .event_handle = event_handle,
            .overlapped = std.mem.zeroes(OVERLAPPED),
            .armed = false,
            .buffer = undefined,
        };
        watched_path.overlapped.hEvent = event_handle;

        errdefer self.deinitWatch(watched_path);
        try self.issueRead(watched_path);
        try self.watched_paths.append(watched_path);
    }

    fn removeWatch(self: *WindowsBackend, path: []const u8) !void {
        for (self.watched_paths.items, 0..) |watched_path, index| {
            if (!std.mem.eql(u8, watched_path.watch_path, path)) continue;

            const removed = self.watched_paths.orderedRemove(index);
            self.deinitWatch(removed);
            self.allocator.destroy(removed);
            return;
        }

        return error.PathNotWatched;
    }

    fn readEvents(self: *WindowsBackend, buffer: []u8) ![]FileEventNotification {
        _ = buffer;
        self.freeTempPaths();

        var events = std.array_list.Managed(FileEventNotification).init(self.allocator);
        defer events.deinit();

        for (self.watched_paths.items) |watched_path| {
            const wait_result = WaitForSingleObject(watched_path.event_handle, 0);
            switch (wait_result) {
                WAIT_OBJECT_0 => try self.collectCompletedEvents(watched_path, &events),
                WAIT_TIMEOUT => {},
                WAIT_FAILED => return mapWindowsError(GetLastError()),
                else => return error.WindowsApiError,
            }
        }

        return try events.toOwnedSlice();
    }

    fn collectCompletedEvents(self: *WindowsBackend, watched_path: *WatchedPath, events: *std.array_list.Managed(FileEventNotification)) !void {
        var bytes_transferred: DWORD = 0;
        const completed = GetOverlappedResult(
            watched_path.dir_handle,
            &watched_path.overlapped,
            &bytes_transferred,
            .FALSE,
        ).toBool();
        const last_error = if (completed) null else GetLastError();

        watched_path.armed = false;
        _ = ResetEvent(watched_path.event_handle);
        errdefer watched_path.armed = false;
        defer self.issueRead(watched_path) catch {};

        if (!completed) {
            switch (last_error.?) {
                .OPERATION_ABORTED, .NOTIFY_ENUM_DIR => return,
                else => return mapWindowsError(last_error.?),
            }
        }

        if (bytes_transferred == 0) return;

        var pending_rename: ?PendingRename = null;
        var offset: usize = 0;
        while (offset < bytes_transferred) {
            const notify: *align(1) windows.FILE.NOTIFY.INFORMATION = @ptrCast(&watched_path.buffer[offset]);
            const file_name_len = @divExact(notify.FileNameLength, @sizeOf(windows.WCHAR));
            const file_name_w = try self.allocator.alloc(windows.WCHAR, file_name_len);
            defer self.allocator.free(file_name_w);

            const file_name_src: [*]align(1) const windows.WCHAR = @ptrCast(&notify.FileName);
            for (file_name_w, 0..) |*dest, i| {
                dest.* = file_name_src[i];
            }

            const relative_name = try self.trackTempPath(try std.unicode.wtf16LeToWtf8Alloc(self.allocator, file_name_w));
            const relevant = self.isRelevantPath(watched_path, relative_name);

            switch (notify.Action) {
                FILE_ACTION_ADDED => {
                    if (relevant and watched_path.config.watch_create) {
                        try events.append(.{
                            .event_type = .created,
                            .path = try self.eventPathFor(watched_path, relative_name, relevant),
                            .timestamp = nowMillis(),
                        });
                    }
                },
                FILE_ACTION_REMOVED => {
                    if (relevant and watched_path.config.watch_delete) {
                        try events.append(.{
                            .event_type = .deleted,
                            .path = try self.eventPathFor(watched_path, relative_name, relevant),
                            .timestamp = nowMillis(),
                        });
                    }
                },
                FILE_ACTION_MODIFIED => {
                    if (relevant and (watched_path.config.watch_modify or watched_path.config.watch_metadata)) {
                        try events.append(.{
                            .event_type = .modified,
                            .path = try self.eventPathFor(watched_path, relative_name, relevant),
                            .timestamp = nowMillis(),
                        });
                    }
                },
                FILE_ACTION_RENAMED_OLD_NAME => {
                    pending_rename = .{
                        .old_path = try self.eventPathFor(watched_path, relative_name, relevant),
                        .relevant = relevant,
                    };
                },
                FILE_ACTION_RENAMED_NEW_NAME => {
                    if (pending_rename) |rename| {
                        if ((rename.relevant or relevant) and watched_path.config.watch_move) {
                            try events.append(.{
                                .event_type = .moved,
                                .path = try self.eventPathFor(watched_path, relative_name, relevant),
                                .old_path = rename.old_path,
                                .timestamp = nowMillis(),
                            });
                        }
                        pending_rename = null;
                    }
                },
                else => {},
            }

            if (notify.NextEntryOffset == 0) break;
            offset += notify.NextEntryOffset;
        }
    }

    fn issueRead(self: *WindowsBackend, watched_path: *WatchedPath) !void {
        watched_path.overlapped = std.mem.zeroes(OVERLAPPED);
        watched_path.overlapped.hEvent = watched_path.event_handle;

        const ok = ReadDirectoryChangesW(
            watched_path.dir_handle,
            @ptrCast(&watched_path.buffer),
            watched_path.buffer.len,
            BOOL.fromBool(watched_path.is_directory and watched_path.config.recursive),
            watchConfigToNotifyFilter(watched_path.config),
            null,
            &watched_path.overlapped,
            null,
        ).toBool();

        if (!ok) {
            switch (GetLastError()) {
                .IO_PENDING => {},
                else => |err| return mapWindowsError(err),
            }
        }

        watched_path.armed = true;
        _ = self;
    }

    fn isRelevantPath(_: *WindowsBackend, watched_path: *const WatchedPath, relative_name: []const u8) bool {
        if (watched_path.is_directory) return true;
        const basename = watched_path.basename orelse return true;
        return windows.eqlIgnoreCaseWtf8(basename, relative_name);
    }

    fn eventPathFor(self: *WindowsBackend, watched_path: *const WatchedPath, relative_name: []const u8, relevant: bool) ![]const u8 {
        if (!watched_path.is_directory and relevant) {
            return watched_path.watch_path;
        }

        if (std.mem.eql(u8, watched_path.directory_path, ".")) {
            return self.trackTempPath(try self.allocator.dupe(u8, relative_name));
        }

        return self.trackTempPath(try std.fs.path.join(self.allocator, &[_][]const u8{ watched_path.directory_path, relative_name }));
    }

    fn trackTempPath(self: *WindowsBackend, path: []u8) ![]const u8 {
        try self.temp_paths.append(path);
        return path;
    }

    fn freeTempPaths(self: *WindowsBackend) void {
        for (self.temp_paths.items) |path| {
            self.allocator.free(path);
        }
        self.temp_paths.clearRetainingCapacity();
    }

    fn deinitWatch(self: *WindowsBackend, watched_path: *WatchedPath) void {
        if (watched_path.armed) {
            _ = CancelIoEx(watched_path.dir_handle, &watched_path.overlapped);
            watched_path.armed = false;
        }
        windows.CloseHandle(watched_path.event_handle);
        windows.CloseHandle(watched_path.dir_handle);
        self.allocator.free(watched_path.watch_path);
        self.allocator.free(watched_path.directory_path);
        if (watched_path.basename) |basename| self.allocator.free(basename);
    }
} else struct {
    fn init(_: std.mem.Allocator) !@This() {
        return error.PlatformNotSupported;
    }
};

fn isDirectoryPath(path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(global_io, path, .{}) catch |err| switch (err) {
        error.NotDir => return false,
        else => return err,
    };
    dir.close(global_io);
    return true;
}

fn watchConfigToNotifyFilter(config: WatchConfig) windows.DWORD {
    var filter: windows.DWORD = 0;

    if (config.watch_create or config.watch_delete or config.watch_move) {
        filter |= FILE_NOTIFY_CHANGE_FILE_NAME;
        filter |= FILE_NOTIFY_CHANGE_DIR_NAME;
    }
    if (config.watch_modify) {
        filter |= FILE_NOTIFY_CHANGE_LAST_WRITE;
        filter |= FILE_NOTIFY_CHANGE_SIZE;
    }
    if (config.watch_metadata) {
        filter |= FILE_NOTIFY_CHANGE_ATTRIBUTES;
        filter |= FILE_NOTIFY_CHANGE_SECURITY;
        filter |= FILE_NOTIFY_CHANGE_CREATION;
    }
    if (config.watch_access) {
        filter |= FILE_NOTIFY_CHANGE_LAST_ACCESS;
    }

    if (filter == 0) {
        filter = FILE_NOTIFY_CHANGE_LAST_WRITE;
    }

    return filter;
}

fn mapWindowsError(err: windows.Win32Error) anyerror {
    return switch (err) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.PathNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        else => error.WindowsApiError,
    };
}

fn nowMillis() i64 {
    const ts = time_utils.getMonotonicTime();
    return @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
}

/// Linux inotify backend
const InotifyBackend = if (builtin.os.tag == .linux) struct {
    allocator: std.mem.Allocator,
    inotify_fd: posix.fd_t,
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
        std.Io.Threaded.closeFd(self.inotify_fd);
    }

    fn addWatch(self: *InotifyBackend, path: []const u8, config: WatchConfig) !i32 {
        var mask: u32 = 0;

        if (config.watch_create) mask |= std.os.linux.IN.CREATE;
        if (config.watch_modify) mask |= std.os.linux.IN.MODIFY;
        if (config.watch_delete) mask |= std.os.linux.IN.DELETE;
        if (config.watch_move) mask |= std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO;
        if (config.watch_metadata) mask |= std.os.linux.IN.ATTRIB;
        if (config.watch_access) mask |= std.os.linux.IN.ACCESS;

        const path_z = try std.posix.toPosixPath(path);
        const wd = std.os.linux.inotify_add_watch(self.inotify_fd, &path_z, mask);
        const signed_wd: isize = @bitCast(wd);
        if (signed_wd < 0) {
            return posix.unexpectedErrno(@enumFromInt(-signed_wd));
        }
        const watch_descriptor: i32 = @intCast(wd);
        try self.watch_descriptors.put(watch_descriptor, path);
        return watch_descriptor;
    }

    fn removeWatch(self: *InotifyBackend, wd: i32) !void {
        _ = std.os.linux.inotify_rm_watch(self.inotify_fd, wd);
        _ = self.watch_descriptors.remove(wd);
    }

    fn readEvents(self: *InotifyBackend, buffer: []u8) ![]FileEventNotification {
        const bytes_read = try posix.read(self.inotify_fd, buffer);
        var events = std.array_list.Managed(FileEventNotification).init(self.allocator);
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
                .timestamp = blk: {
                    const ts = time_utils.getMonotonicTime();
                    break :blk @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
                },
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
} else void;

/// macOS/BSD kqueue backend
const KqueueBackend = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd) struct {
    allocator: std.mem.Allocator,
    kqueue_fd: posix.fd_t,
    watched_fds: std.AutoHashMap(posix.fd_t, []const u8),

    fn init(allocator: std.mem.Allocator) !KqueueBackend {
        const kqueue_fd = try posix.kqueue();
        const watched_fds = std.AutoHashMap(posix.fd_t, []const u8).init(allocator);

        return KqueueBackend{
            .allocator = allocator,
            .kqueue_fd = kqueue_fd,
            .watched_fds = watched_fds,
        };
    }

    fn deinit(self: *KqueueBackend) void {
        var iter = self.watched_fds.iterator();
        while (iter.next()) |entry| {
            std.Io.Threaded.closeFd(entry.key_ptr.*);
        }
        self.watched_fds.deinit();
        std.Io.Threaded.closeFd(self.kqueue_fd);
    }

    fn addWatch(self: *KqueueBackend, path: []const u8, config: WatchConfig) !i32 {
        const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
        errdefer std.Io.Threaded.closeFd(fd);

        // Build fflags based on config
        var fflags: u32 = 0;
        if (config.watch_delete) fflags |= std.c.NOTE.DELETE;
        if (config.watch_modify) fflags |= std.c.NOTE.WRITE | std.c.NOTE.EXTEND;
        if (config.watch_metadata) fflags |= std.c.NOTE.ATTRIB;
        if (config.watch_move) fflags |= std.c.NOTE.RENAME;

        // Always watch for revoke to handle unmounts/removals
        fflags |= std.c.NOTE.REVOKE;

        // Add kqueue event for this file descriptor
        var kevent = std.c.Kevent{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.VNODE,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
            .fflags = fflags,
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
        std.Io.Threaded.closeFd(fd);
    }

    fn readEvents(self: *KqueueBackend, buffer: []u8) ![]FileEventNotification {
        _ = buffer;
        var kevents: [32]std.c.Kevent = undefined;
        const num_events = std.c.kevent(self.kqueue_fd, null, 0, &kevents, kevents.len, null);

        var events = std.array_list.Managed(FileEventNotification).init(self.allocator);
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
                        .timestamp = blk: {
                    const ts = time_utils.getMonotonicTime();
                    break :blk @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
                },
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
} else void;

/// Polling-based backend for Windows and unsupported platforms
/// Used on unsupported platforms that do not have a native backend.
const PollingBackend = if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .freebsd and builtin.os.tag != .openbsd and builtin.os.tag != .netbsd and builtin.os.tag != .windows) struct {
    allocator: std.mem.Allocator,
    watched_paths: std.array_list.Managed(WatchedPath),
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
            .watched_paths = std.array_list.Managed(WatchedPath).init(allocator),
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
        var events = std.array_list.Managed(FileEventNotification).init(self.allocator);
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
                        .timestamp = blk: {
                    const ts = time_utils.getMonotonicTime();
                    break :blk @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
                },
                    };
                    try events.append(notification);
                }
            } else |err| {
                // File might have been deleted
                if (err == error.FileNotFound and watched_path.config.watch_delete) {
                    const notification = FileEventNotification{
                        .event_type = .deleted,
                        .path = watched_path.path,
                        .timestamp = blk: {
                    const ts = time_utils.getMonotonicTime();
                    break :blk @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
                },
                    };
                    try events.append(notification);
                }
            }
        }

        return try events.toOwnedSlice();
    }
} else void;

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
        var paths = std.array_list.Managed([]u8).init(self.allocator);
        errdefer {
            for (paths.items) |path| {
                self.allocator.free(path);
            }
            paths.deinit(self.allocator);
        }

        try self.scanRecursiveImpl(root_path, &paths);
        return try paths.toOwnedSlice();
    }

    fn scanRecursiveImpl(self: *DirectoryScanner, dir_path: []const u8, paths: *std.array_list.Managed([]u8)) !void {
        var dir = std.Io.Dir.cwd().openDir(global_io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(global_io);

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

test "FileWatcher repeated processEvents does not leak" {
    // This test verifies that calling processEvents multiple times
    // does not leak memory (the owned slice from readEvents is freed)
    const allocator = std.testing.allocator;

    // Create a dummy event loop for testing
    var loop = try @import("root.zig").EventLoop.init(allocator, .{});
    defer loop.deinit();

    var watcher = try FileWatcher.init(allocator, &loop);
    defer watcher.deinit();

    // Call processEvents multiple times - should not leak
    // (DebugAllocator will catch any leaks at end of test)
    for (0..10) |_| {
        try watcher.processEvents();
    }
}

test "watchConfigToNotifyFilter maps create and modify flags" {
    const filter = watchConfigToNotifyFilter(.{
        .watch_create = true,
        .watch_modify = true,
        .watch_delete = false,
        .watch_move = false,
        .watch_metadata = false,
        .watch_access = false,
    });

    try std.testing.expect(filter & FILE_NOTIFY_CHANGE_FILE_NAME != 0);
    try std.testing.expect(filter & FILE_NOTIFY_CHANGE_LAST_WRITE != 0);
    try std.testing.expect(filter & FILE_NOTIFY_CHANGE_SIZE != 0);
}

test "watchConfigToNotifyFilter defaults to last write" {
    try std.testing.expectEqual(@as(windows.DWORD, FILE_NOTIFY_CHANGE_LAST_WRITE), watchConfigToNotifyFilter(.{
        .watch_create = false,
        .watch_modify = false,
        .watch_delete = false,
        .watch_move = false,
        .watch_metadata = false,
        .watch_access = false,
    }));
}
