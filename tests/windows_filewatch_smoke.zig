const std = @import("std");
const builtin = @import("builtin");
const zigzag = @import("zigzag");

const io = std.testing.io;

const CapturedEvent = struct {
    event_type: zigzag.file_watching.FileEvent,
    path: []u8,
    old_path: ?[]u8,
};

const CaptureState = struct {
    allocator: std.mem.Allocator,
    events: std.array_list.Managed(CapturedEvent),

    fn init(allocator: std.mem.Allocator) CaptureState {
        return .{
            .allocator = allocator,
            .events = std.array_list.Managed(CapturedEvent).init(allocator),
        };
    }

    fn deinit(self: *CaptureState) void {
        for (self.events.items) |event| {
            self.allocator.free(event.path);
            if (event.old_path) |old_path| self.allocator.free(old_path);
        }
        self.events.deinit();
    }

    fn clear(self: *CaptureState) void {
        for (self.events.items) |event| {
            self.allocator.free(event.path);
            if (event.old_path) |old_path| self.allocator.free(old_path);
        }
        self.events.clearRetainingCapacity();
    }
};

threadlocal var capture_state: ?*CaptureState = null;

fn captureEvent(notification: zigzag.file_watching.FileEventNotification) void {
    const state = capture_state orelse return;
    const path_copy = state.allocator.dupe(u8, notification.path) catch return;
    errdefer state.allocator.free(path_copy);
    const old_path_copy = if (notification.old_path) |old_path|
        state.allocator.dupe(u8, old_path) catch return
    else
        null;
    errdefer if (old_path_copy) |old_path| state.allocator.free(old_path);

    state.events.append(.{
        .event_type = notification.event_type,
        .path = path_copy,
        .old_path = old_path_copy,
    }) catch {
        state.allocator.free(path_copy);
        if (old_path_copy) |old_path| state.allocator.free(old_path);
    };
}

fn waitForEvent(
    watcher: *zigzag.FileWatcher,
    state: *CaptureState,
    expected_type: zigzag.file_watching.FileEvent,
    expected_path_suffix: []const u8,
    timeout_ms: u64,
) !CapturedEvent {
    const deadline = zigzag.time.getMonotonicMs() + @as(i64, @intCast(timeout_ms));

    while (zigzag.time.getMonotonicMs() < deadline) {
        try watcher.processEvents();
        for (state.events.items) |event| {
            if (event.event_type != expected_type) continue;
            if (!std.mem.endsWith(u8, event.path, expected_path_suffix)) continue;
            return event;
        }
        zigzag.time.sleep(10_000_000);
    }

    return error.ExpectedEventNotReceived;
}

fn tmpRootPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
}

test "Windows file watcher smoke - file lifecycle events" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var loop = try zigzag.EventLoop.init(allocator, .{ .backend = .iocp });
    defer loop.deinit();

    var watcher = try zigzag.FileWatcher.init(allocator, &loop);
    defer watcher.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmpRootPath(allocator, &tmp);
    defer allocator.free(root_path);
    const watched_file_path = try std.fs.path.join(allocator, &[_][]const u8{ root_path, "note.txt" });
    defer allocator.free(watched_file_path);

    var state = CaptureState.init(allocator);
    defer state.deinit();
    capture_state = &state;
    defer capture_state = null;
    watcher.setCallback(captureEvent);

    try watcher.addWatch(watched_file_path, .{});
    defer watcher.removeWatch(watched_file_path) catch {};

    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "first" });
    _ = try waitForEvent(&watcher, &state, .created, "note.txt", 2000);

    state.clear();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "second" });
    _ = try waitForEvent(&watcher, &state, .modified, "note.txt", 2000);

    state.clear();
    try tmp.dir.deleteFile(io, "note.txt");
    _ = try waitForEvent(&watcher, &state, .deleted, "note.txt", 2000);
}

test "Windows file watcher smoke - rename event in watched directory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var loop = try zigzag.EventLoop.init(allocator, .{ .backend = .iocp });
    defer loop.deinit();

    var watcher = try zigzag.FileWatcher.init(allocator, &loop);
    defer watcher.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpRootPath(allocator, &tmp);
    defer allocator.free(dir_path);

    var state = CaptureState.init(allocator);
    defer state.deinit();
    capture_state = &state;
    defer capture_state = null;
    watcher.setCallback(captureEvent);

    try watcher.addWatch(dir_path, .{ .recursive = false });
    defer watcher.removeWatch(dir_path) catch {};

    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "rename me" });
    _ = try waitForEvent(&watcher, &state, .created, "old.txt", 2000);

    state.clear();
    try tmp.dir.rename("old.txt", tmp.dir, "new.txt", io);
    const moved = try waitForEvent(&watcher, &state, .moved, "new.txt", 2000);
    try std.testing.expect(moved.old_path != null);
    try std.testing.expect(std.mem.endsWith(u8, moved.old_path.?, "old.txt"));
}
