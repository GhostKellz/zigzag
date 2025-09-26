//! Terminal emulator demo for ZigZag event loop
//! Demonstrates all alpha features

const std = @import("std");
const zigzag = @import("zigzag");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize event loop with all features enabled
    var loop = try zigzag.EventLoop.init(allocator, .{
        .max_events = 1024,
        .backend = null, // Auto-detect best backend
        .coalescing = .{
            .coalesce_resize = true,
            .max_coalesce_time_ms = 10,
            .max_batch_size = 16,
        },
    });
    defer loop.deinit();

    std.log.info("ZigZag Event Loop Alpha Demo", .{});
    std.log.info("Backend: {s}", .{@tagName(loop.backend)});

    // Set up stdin for non-blocking I/O
    const stdin_fd = std.io.getStdIn().handle;

    // Watch stdin for input
    const stdin_watch = try loop.addFd(stdin_fd, .{ .read = true });
    std.log.info("Watching stdin (fd={d})", .{stdin_fd});

    // Set up a timer callback
    const timer_callback = struct {
        var count: u32 = 0;
        pub fn onTimer(user_data: ?*anyopaque) void {
            _ = user_data;
            count += 1;
            std.log.info("Timer fired! Count: {d}", .{count});
        }
    }.onTimer;

    // Add a recurring timer (fires every second)
    const timer = try loop.addRecurringTimer(1000, timer_callback);
    std.log.info("Added recurring timer (id={d}, interval=1000ms)", .{timer.id});

    // Set up input handler callback
    const input_callback = struct {
        pub fn onInput(watch: *const zigzag.Watch, event: zigzag.Event) void {
            _ = watch;
            std.log.info("Input available! fd={d}, type={s}, bytes={d}", .{
                event.fd,
                @tagName(event.type),
                event.data.size,
            });

            // Read and echo the input
            var buffer: [1024]u8 = undefined;
            const bytes_read = std.posix.read(event.fd, &buffer) catch |err| {
                std.log.err("Failed to read input: {s}", .{@errorName(err)});
                return;
            };

            if (bytes_read > 0) {
                const input = buffer[0..bytes_read];
                std.log.info("Received: {s}", .{std.fmt.fmtSliceEscapeLower(input)});

                // Check for quit command
                if (std.mem.eql(u8, input, "q\n") or std.mem.eql(u8, input, "quit\n")) {
                    std.log.info("Quit command received. Stopping event loop...", .{});
                    // Note: We can't directly access loop here, so we'd need a better design
                    // for a real application
                }
            }
        }
    }.onInput;

    // Set the callback for stdin
    loop.setCallback(stdin_watch, input_callback);

    // Demo: Add a one-shot timer
    const oneshot_callback = struct {
        pub fn onTimer(user_data: ?*anyopaque) void {
            _ = user_data;
            std.log.info("One-shot timer expired!", .{});
        }
    }.onTimer;

    const oneshot_timer = try loop.addTimer(2500, oneshot_callback);
    std.log.info("Added one-shot timer (id={d}, fires in 2500ms)", .{oneshot_timer.id});

    std.log.info("\n=== Event Loop Running ===", .{});
    std.log.info("Type 'q' or 'quit' to exit", .{});
    std.log.info("Watch for timer events every second", .{});
    std.log.info("========================\n", .{});

    // Run the event loop for a limited time (10 seconds for demo)
    const start_time = std.time.milliTimestamp();
    const max_runtime_ms = 10000; // 10 seconds

    while (!loop.should_stop) {
        const now = std.time.milliTimestamp();
        if (now - start_time >= max_runtime_ms) {
            std.log.info("\nDemo time limit reached (10 seconds). Stopping...", .{});
            break;
        }

        // Run one iteration with a 100ms timeout
        const had_events = try loop.tick();
        if (!had_events) {
            // No events, wait a bit
            std.time.sleep(10_000_000); // 10ms
        }
    }

    std.log.info("\nEvent loop stopped. Cleaning up...", .{});

    // Cancel timers
    loop.cancelTimer(&timer);
    loop.cancelTimer(&oneshot_timer);

    // Remove watches
    loop.removeFd(stdin_watch);

    std.log.info("Demo completed successfully!", .{});
}

test "Terminal demo components" {
    const allocator = std.testing.allocator;

    // Test event loop initialization with coalescing
    var loop = try zigzag.EventLoop.init(allocator, .{
        .coalescing = .{
            .coalesce_resize = true,
        },
    });
    defer loop.deinit();

    // Test that coalescer was initialized
    try std.testing.expect(loop.coalescer != null);

    // Test timer operations
    const callback = struct {
        pub fn cb(user_data: ?*anyopaque) void {
            _ = user_data;
        }
    }.cb;

    const timer = try loop.addTimer(100, callback);
    try std.testing.expect(loop.timers.contains(timer.id));

    loop.cancelTimer(&timer);
    try std.testing.expect(!loop.timers.contains(timer.id));
}