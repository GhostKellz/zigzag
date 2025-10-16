//! Tests for Grim editor-specific functionality

const std = @import("std");
const testing = std.testing;
const grim = @import("grim_editor_support.zig");

test "Debounced file watcher initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = grim.EditorWatchConfig{
        .debounce_ms = 100,
        .ignore_patterns = &.{ ".git", "node_modules" },
    };

    var watcher = try grim.DebouncedFileWatcher.init(allocator, config);
    defer watcher.deinit();

    try testing.expectEqual(@as(u64, 100), watcher.config.debounce_ms);
}

test "File change event types" {
    const event1 = grim.FileChangeType.created;
    const event2 = grim.FileChangeType.modified;
    const event3 = grim.FileChangeType.lsp_diagnostic_changed;

    try testing.expect(event1 != event2);
    try testing.expect(event2 != event3);
}

test "LSP event handler" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var handler = grim.LSPEventHandler.init(allocator);
    defer handler.deinit();

    try testing.expect(!handler.diagnostics_changed);
    try testing.expect(!handler.completion_available);

    // Trigger events
    handler.onDiagnosticsChanged();
    try testing.expect(handler.diagnostics_changed);

    handler.onCompletionAvailable();
    try testing.expect(handler.completion_available);

    // Clear events
    handler.clearEvents();
    try testing.expect(!handler.diagnostics_changed);
    try testing.expect(!handler.completion_available);
}

test "Syntax file watcher" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var watcher = try grim.SyntaxFileWatcher.init(allocator);
    defer watcher.deinit();

    // Add syntax files
    try watcher.addSyntaxFile("/path/to/syntax.zig");
    try watcher.addSyntaxFile("/path/to/grammar.tree");

    try testing.expectEqual(@as(usize, 2), watcher.syntax_paths.items.len);

    // Test invalidation
    try testing.expect(!watcher.needsReload());
    watcher.invalidate();
    try testing.expect(watcher.needsReload());

    watcher.clearInvalidation();
    try testing.expect(!watcher.needsReload());
}

test "Editor watch config" {
    const config1 = grim.EditorWatchConfig{
        .debounce_ms = 50,
        .watch_syntax_files = true,
        .watch_lsp_files = true,
    };

    try testing.expectEqual(@as(u64, 50), config1.debounce_ms);
    try testing.expect(config1.watch_syntax_files);
    try testing.expect(config1.watch_lsp_files);
}
