//! Grim editor-specific file watching and event handling
//!
//! Optimized file watching for text editors with LSP integration

const std = @import("std");
const EventLoop = @import("root.zig").EventLoop;
const logging = @import("logging.zig");
const time_utils = @import("time_utils.zig");

/// Editor-specific file change types
pub const FileChangeType = enum {
    created,
    modified,
    deleted,
    renamed,
    // Editor-specific
    syntax_tree_invalidated,
    lsp_diagnostic_changed,
};

/// Editor file watch configuration
pub const EditorWatchConfig = struct {
    /// Debounce time for rapid file changes (ms)
    debounce_ms: u64 = 50,

    /// Ignore patterns (e.g., .git, node_modules)
    ignore_patterns: []const []const u8 = &.{},

    /// Watch for syntax file changes
    watch_syntax_files: bool = true,

    /// Watch for LSP-related changes
    watch_lsp_files: bool = true,
};

/// File watch entry for editor
pub const EditorFileWatch = struct {
    path: []const u8,
    last_modified: i64,
    last_event_time: i64,
    change_count: usize = 0,
};

/// Debounced file change events
pub const DebouncedFileWatcher = struct {
    allocator: std.mem.Allocator,
    watches: std.StringHashMap(EditorFileWatch),
    config: EditorWatchConfig,
    pending_events: std.ArrayList(FileChangeEvent),

    pub const FileChangeEvent = struct {
        path: []const u8,
        change_type: FileChangeType,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator, config: EditorWatchConfig) !DebouncedFileWatcher {
        return .{
            .allocator = allocator,
            .watches = std.StringHashMap(EditorFileWatch).init(allocator),
            .config = config,
            .pending_events = std.ArrayList(FileChangeEvent).init(allocator),
        };
    }

    pub fn deinit(self: *DebouncedFileWatcher) void {
        var iter = self.watches.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.watches.deinit();

        for (self.pending_events.items) |event| {
            self.allocator.free(event.path);
        }
        self.pending_events.deinit();
    }

    /// Add file to watch
    pub fn addWatch(self: *DebouncedFileWatcher, path: []const u8) !void {
        // Check ignore patterns
        for (self.config.ignore_patterns) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) {
                return; // Ignored file
            }
        }

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const stat = try std.fs.cwd().statFile(path);
        const watch = EditorFileWatch{
            .path = path_copy,
            .last_modified = @intCast(stat.mtime),
            .last_event_time = blk: {
                const ts = time_utils.getMonotonicTime();
                break :blk @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
            },
        };

        try self.watches.put(path_copy, watch);
        logging.logFileWatchEvent(path, "added");
    }

    /// Check for file changes
    pub fn pollChanges(self: *DebouncedFileWatcher) ![]const FileChangeEvent {
        const ts = time_utils.getMonotonicTime();
        const now = @as(i64, @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000)));
        self.pending_events.clearRetainingCapacity();

        var iter = self.watches.iterator();
        while (iter.next()) |entry| {
            const watch = entry.value_ptr;

            // Check if debounce period has passed
            const time_since_event = now - watch.last_event_time;
            if (time_since_event < self.config.debounce_ms) {
                continue;
            }

            // Check file status
            const stat = std.fs.cwd().statFile(watch.path) catch |err| {
                if (err == error.FileNotFound) {
                    // File was deleted
                    try self.pending_events.append(.{
                        .path = try self.allocator.dupe(u8, watch.path),
                        .change_type = .deleted,
                        .timestamp = now,
                    });
                    logging.logFileWatchEvent(watch.path, "deleted");
                }
                continue;
            };

            const current_mtime: i64 = @intCast(stat.mtime);
            if (current_mtime != watch.last_modified) {
                // File was modified
                try self.pending_events.append(.{
                    .path = try self.allocator.dupe(u8, watch.path),
                    .change_type = .modified,
                    .timestamp = now,
                });

                watch.last_modified = current_mtime;
                watch.last_event_time = now;
                watch.change_count += 1;

                logging.logFileWatchEvent(watch.path, "modified");
            }
        }

        return self.pending_events.items;
    }

    /// Remove watch
    pub fn removeWatch(self: *DebouncedFileWatcher, path: []const u8) void {
        if (self.watches.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
        }
    }
};

/// LSP event integration
pub const LSPEventHandler = struct {
    allocator: std.mem.Allocator,
    diagnostics_changed: bool = false,
    completion_available: bool = false,

    pub fn init(allocator: std.mem.Allocator) LSPEventHandler {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(_: *LSPEventHandler) void {}

    /// Handle LSP diagnostic change
    pub fn onDiagnosticsChanged(self: *LSPEventHandler) void {
        self.diagnostics_changed = true;
        logging.logDebug("LSP diagnostics changed");
    }

    /// Handle LSP completion available
    pub fn onCompletionAvailable(self: *LSPEventHandler) void {
        self.completion_available = true;
        logging.logDebug("LSP completion available");
    }

    /// Clear events
    pub fn clearEvents(self: *LSPEventHandler) void {
        self.diagnostics_changed = false;
        self.completion_available = false;
    }
};

/// Syntax highlighting file watch
pub const SyntaxFileWatcher = struct {
    allocator: std.mem.Allocator,
    syntax_paths: std.ArrayList([]const u8),
    invalidated: bool = false,

    pub fn init(allocator: std.mem.Allocator) !SyntaxFileWatcher {
        return .{
            .allocator = allocator,
            .syntax_paths = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SyntaxFileWatcher) void {
        for (self.syntax_paths.items) |path| {
            self.allocator.free(path);
        }
        self.syntax_paths.deinit();
    }

    /// Add syntax file to watch
    pub fn addSyntaxFile(self: *SyntaxFileWatcher, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        try self.syntax_paths.append(path_copy);
    }

    /// Mark syntax as invalidated
    pub fn invalidate(self: *SyntaxFileWatcher) void {
        self.invalidated = true;
        logging.logDebug("Syntax highlighting invalidated");
    }

    /// Check if syntax needs reload
    pub fn needsReload(self: SyntaxFileWatcher) bool {
        return self.invalidated;
    }

    /// Clear invalidation flag
    pub fn clearInvalidation(self: *SyntaxFileWatcher) void {
        self.invalidated = false;
    }
};
