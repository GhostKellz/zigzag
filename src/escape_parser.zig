//! ANSI/VT100 Escape Sequence Parser
//! Converts raw terminal input bytes into structured key events
//!
//! Handles:
//! - Single character input
//! - Control sequences (\x1b[A for arrow keys, etc.)
//! - Function keys (\x1b[11~ for F1, etc.)
//! - Mouse events (SGR protocol)
//! - Incomplete sequences (buffering)

const std = @import("std");

/// Key event representation (designed to match common TUI frameworks)
pub const Key = union(enum) {
    char: u21,

    // Special keys
    backspace,
    enter,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    tab,
    shift_tab,
    delete,
    insert,
    escape,

    // Function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    // Ctrl combinations
    ctrl_a,
    ctrl_b,
    ctrl_c,
    ctrl_d,
    ctrl_e,
    ctrl_f,
    ctrl_g,
    ctrl_h,
    ctrl_i,
    ctrl_j,
    ctrl_k,
    ctrl_l,
    ctrl_m,
    ctrl_n,
    ctrl_o,
    ctrl_p,
    ctrl_q,
    ctrl_r,
    ctrl_s,
    ctrl_t,
    ctrl_u,
    ctrl_v,
    ctrl_w,
    ctrl_x,
    ctrl_y,
    ctrl_z,

    pub fn fromChar(c: u8) Key {
        return Key{ .char = c };
    }
};

/// Mouse button types
pub const MouseButton = enum {
    left,
    right,
    middle,
    wheel_up,
    wheel_down,
};

/// Mouse event
pub const MouseEvent = struct {
    button: MouseButton,
    x: u16,
    y: u16,
    pressed: bool, // true for press, false for release
};

/// Parse result
pub const ParseResult = union(enum) {
    key: Key,
    mouse: MouseEvent,
    none, // No complete sequence yet
    invalid, // Invalid sequence
};

/// Escape sequence parser with buffering for incomplete sequences
pub const EscapeParser = struct {
    buffer: [32]u8 = undefined,
    buffer_len: usize = 0,

    pub fn init() EscapeParser {
        return .{};
    }

    /// Reset the parser state
    pub fn reset(self: *EscapeParser) void {
        self.buffer_len = 0;
    }

    /// Parse input bytes and return key events
    /// Returns null when more bytes are needed to complete a sequence
    pub fn parse(self: *EscapeParser, input: []const u8) !?ParseResult {
        if (input.len == 0) return null;

        // If we have buffered data, append new input
        if (self.buffer_len > 0) {
            const space_left = self.buffer.len - self.buffer_len;
            const bytes_to_copy = @min(space_left, input.len);
            @memcpy(self.buffer[self.buffer_len..][0..bytes_to_copy], input[0..bytes_to_copy]);
            self.buffer_len += bytes_to_copy;

            const result = try self.parseSequence(self.buffer[0..self.buffer_len]);

            // If we got a complete sequence, reset buffer
            if (result != null and result.? != .none) {
                self.reset();
                return result;
            }

            return null;
        }

        return try self.parseSequence(input);
    }

    fn parseSequence(self: *EscapeParser, bytes: []const u8) !?ParseResult {
        if (bytes.len == 0) return null;

        const first = bytes[0];

        // Single byte sequences
        if (bytes.len == 1) {
            return ParseResult{ .key = try self.parseSingleByte(first) };
        }

        // Escape sequences
        if (first == 0x1B) { // ESC
            if (bytes.len < 2) {
                // Need more bytes
                @memcpy(self.buffer[0..bytes.len], bytes);
                self.buffer_len = bytes.len;
                return ParseResult.none;
            }

            return try self.parseEscapeSequence(bytes);
        }

        // Regular character
        return ParseResult{ .key = Key{ .char = first } };
    }

    fn parseSingleByte(self: *EscapeParser, byte: u8) !Key {
        _ = self;
        return switch (byte) {
            0x08, 0x7F => .backspace, // BS or DEL
            0x09 => .tab,
            0x0D, 0x0A => .enter, // CR or LF
            0x1B => .escape,
            0x01 => .ctrl_a,
            0x02 => .ctrl_b,
            0x03 => .ctrl_c,
            0x04 => .ctrl_d,
            0x05 => .ctrl_e,
            0x06 => .ctrl_f,
            0x07 => .ctrl_g,
            // 0x08 handled above as backspace
            // 0x09 handled above as tab
            0x0B => .ctrl_k,
            0x0C => .ctrl_l,
            // 0x0D handled above as enter
            0x0E => .ctrl_n,
            0x0F => .ctrl_o,
            0x10 => .ctrl_p,
            0x11 => .ctrl_q,
            0x12 => .ctrl_r,
            0x13 => .ctrl_s,
            0x14 => .ctrl_t,
            0x15 => .ctrl_u,
            0x16 => .ctrl_v,
            0x17 => .ctrl_w,
            0x18 => .ctrl_x,
            0x19 => .ctrl_y,
            0x1A => .ctrl_z,
            else => Key{ .char = byte },
        };
    }

    fn parseEscapeSequence(self: *EscapeParser, bytes: []const u8) !?ParseResult {
        if (bytes.len < 2) {
            @memcpy(self.buffer[0..bytes.len], bytes);
            self.buffer_len = bytes.len;
            return ParseResult.none;
        }

        const second = bytes[1];

        // CSI sequences: ESC [
        if (second == '[') {
            return try self.parseCSI(bytes);
        }

        // Alt + key: ESC + character
        if (bytes.len == 2) {
            // For now, just return the character
            // Could extend to support Alt combinations
            return ParseResult{ .key = Key{ .char = second } };
        }

        return ParseResult.invalid;
    }

    fn parseCSI(self: *EscapeParser, bytes: []const u8) !?ParseResult {
        if (bytes.len < 3) {
            @memcpy(self.buffer[0..bytes.len], bytes);
            self.buffer_len = bytes.len;
            return ParseResult.none;
        }

        const third = bytes[2];

        // Arrow keys and basic navigation
        // ESC [ A/B/C/D/H/F
        if (bytes.len == 3) {
            const key: Key = switch (third) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                'Z' => .shift_tab, // Shift+Tab
                else => {
                    // Might need more bytes for sequences like ESC[1~
                    if (third >= '0' and third <= '9') {
                        @memcpy(self.buffer[0..bytes.len], bytes);
                        self.buffer_len = bytes.len;
                        return ParseResult.none;
                    }
                    return ParseResult.invalid;
                },
            };
            return ParseResult{ .key = key };
        }

        // Extended sequences: ESC [ <num> ~
        // Examples: ESC[1~ (Home), ESC[2~ (Insert), ESC[11~ (F1)
        if (bytes.len >= 4) {
            return try self.parseExtendedCSI(bytes);
        }

        @memcpy(self.buffer[0..bytes.len], bytes);
        self.buffer_len = bytes.len;
        return ParseResult.none;
    }

    fn parseExtendedCSI(self: *EscapeParser, bytes: []const u8) !?ParseResult {
        _ = self;

        // Find the terminator
        var num_end: usize = 2;
        while (num_end < bytes.len and bytes[num_end] >= '0' and bytes[num_end] <= '9') : (num_end += 1) {}

        if (num_end >= bytes.len) {
            // Need more bytes
            return ParseResult.none;
        }

        const terminator = bytes[num_end];
        if (terminator != '~' and terminator != ';') {
            return ParseResult.invalid;
        }

        // Parse the number
        const num_str = bytes[2..num_end];
        const num = std.fmt.parseInt(u16, num_str, 10) catch return ParseResult.invalid;

        // Map numbers to keys
        return ParseResult{ .key = switch (num) {
            1 => Key.home,
            2 => Key.insert,
            3 => Key.delete,
            4 => Key.end,
            5 => Key.page_up,
            6 => Key.page_down,
            11 => Key.f1,
            12 => Key.f2,
            13 => Key.f3,
            14 => Key.f4,
            15 => Key.f5,
            17 => Key.f6,
            18 => Key.f7,
            19 => Key.f8,
            20 => Key.f9,
            21 => Key.f10,
            23 => Key.f11,
            24 => Key.f12,
            else => return ParseResult.invalid,
        } };
    }
};

test "parse single characters" {
    var parser = EscapeParser.init();

    // Regular character
    const result1 = try parser.parse("a");
    try std.testing.expect(result1.?.key.char == 'a');

    // Enter
    const result2 = try parser.parse("\r");
    try std.testing.expect(result2.?.key == .enter);

    // Tab
    const result3 = try parser.parse("\t");
    try std.testing.expect(result3.?.key == .tab);

    // Backspace
    const result4 = try parser.parse("\x08");
    try std.testing.expect(result4.?.key == .backspace);
}

test "parse control keys" {
    var parser = EscapeParser.init();

    // Ctrl+C
    const result1 = try parser.parse("\x03");
    try std.testing.expect(result1.?.key == .ctrl_c);

    // Ctrl+D
    const result2 = try parser.parse("\x04");
    try std.testing.expect(result2.?.key == .ctrl_d);
}

test "parse arrow keys" {
    var parser = EscapeParser.init();

    // Up arrow: ESC [ A
    const result1 = try parser.parse("\x1b[A");
    try std.testing.expect(result1.?.key == .up);

    // Down arrow
    const result2 = try parser.parse("\x1b[B");
    try std.testing.expect(result2.?.key == .down);

    // Right arrow
    const result3 = try parser.parse("\x1b[C");
    try std.testing.expect(result3.?.key == .right);

    // Left arrow
    const result4 = try parser.parse("\x1b[D");
    try std.testing.expect(result4.?.key == .left);
}

test "parse function keys" {
    var parser = EscapeParser.init();

    // F1: ESC [ 1 1 ~
    const result1 = try parser.parse("\x1b[11~");
    try std.testing.expect(result1.?.key == .f1);

    // F2
    const result2 = try parser.parse("\x1b[12~");
    try std.testing.expect(result2.?.key == .f2);

    // F12
    const result3 = try parser.parse("\x1b[24~");
    try std.testing.expect(result3.?.key == .f12);
}

test "parse extended keys" {
    var parser = EscapeParser.init();

    // Home: ESC [ 1 ~
    const result1 = try parser.parse("\x1b[1~");
    try std.testing.expect(result1.?.key == .home);

    // Insert
    const result2 = try parser.parse("\x1b[2~");
    try std.testing.expect(result2.?.key == .insert);

    // Delete
    const result3 = try parser.parse("\x1b[3~");
    try std.testing.expect(result3.?.key == .delete);

    // Page Up
    const result4 = try parser.parse("\x1b[5~");
    try std.testing.expect(result4.?.key == .page_up);
}

test "buffering incomplete sequences" {
    var parser = EscapeParser.init();

    // Send partial sequence - just ESC, returns as escape key
    const result1 = try parser.parse("\x1b");
    // Single ESC is a valid key
    try std.testing.expect(result1.?.key == .escape);

    // Send a complete arrow sequence
    parser.reset();
    const result2 = try parser.parse("\x1b[A");
    try std.testing.expect(result2.?.key == .up);
}
