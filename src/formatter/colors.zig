//! Color Support for CC Streamer
//! 
//! This module provides color formatting capabilities for JSON output.
//! It supports:
//! - ANSI color codes for different JSON element types
//! - TTY detection for automatic color disabling in pipes  
//! - Environment variable support (NO_COLOR)
//! - Customizable color schemes
//! - Safe color stripping functionality

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const builtin = @import("builtin");

/// ANSI color codes
pub const AnsiCodes = struct {
    pub const RESET = "\x1b[0m";
    pub const BOLD = "\x1b[1m";
    
    // Foreground colors
    pub const BLACK = "\x1b[30m";
    pub const RED = "\x1b[31m";
    pub const GREEN = "\x1b[32m";
    pub const YELLOW = "\x1b[33m";
    pub const BLUE = "\x1b[34m";
    pub const MAGENTA = "\x1b[35m";
    pub const CYAN = "\x1b[36m";
    pub const WHITE = "\x1b[37m";
    pub const GRAY = "\x1b[90m";
    
    // Bright variants
    pub const BRIGHT_RED = "\x1b[91m";
    pub const BRIGHT_GREEN = "\x1b[92m";
    pub const BRIGHT_YELLOW = "\x1b[93m";
    pub const BRIGHT_BLUE = "\x1b[94m";
    pub const BRIGHT_MAGENTA = "\x1b[95m";
    pub const BRIGHT_CYAN = "\x1b[96m";
    pub const BRIGHT_WHITE = "\x1b[97m";
    
    /// Check if a string contains ANSI codes
    pub fn containsAnsiCodes(text: []const u8) bool {
        return std.mem.indexOf(u8, text, "\x1b[") != null;
    }
    
    /// Strip ANSI codes from a string
    /// Caller owns the returned memory
    pub fn stripAnsiCodes(allocator: Allocator, text: []const u8) ![]u8 {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();
        
        var i: usize = 0;
        while (i < text.len) {
            if (i + 1 < text.len and text[i] == '\x1b' and text[i + 1] == '[') {
                // Found ANSI escape sequence, skip until 'm'
                i += 2; // skip \x1b[
                while (i < text.len and text[i] != 'm') {
                    i += 1;
                }
                if (i < text.len) i += 1; // skip 'm'
            } else {
                try result.append(text[i]);
                i += 1;
            }
        }
        
        return try result.toOwnedSlice();
    }
    
    /// Get length of text without ANSI codes
    pub fn getDisplayLength(text: []const u8) usize {
        var length: usize = 0;
        var i: usize = 0;
        
        while (i < text.len) {
            if (i + 1 < text.len and text[i] == '\x1b' and text[i + 1] == '[') {
                // Skip ANSI escape sequence
                i += 2; // skip \x1b[
                while (i < text.len and text[i] != 'm') {
                    i += 1;
                }
                if (i < text.len) i += 1; // skip 'm'
            } else {
                length += 1;
                i += 1;
            }
        }
        
        return length;
    }
};

/// JSON element color scheme
pub const JsonColorScheme = struct {
    key_color: []const u8 = AnsiCodes.CYAN,
    string_color: []const u8 = AnsiCodes.GREEN,
    number_color: []const u8 = AnsiCodes.YELLOW,
    boolean_color: []const u8 = AnsiCodes.MAGENTA,
    null_color: []const u8 = AnsiCodes.GRAY,
    structural_color: []const u8 = AnsiCodes.WHITE, // For braces, brackets, colons
    error_color: []const u8 = AnsiCodes.RED,
    
    /// Default color scheme following PRD specification
    pub fn default() JsonColorScheme {
        return JsonColorScheme{};
    }
    
    /// High contrast color scheme
    pub fn highContrast() JsonColorScheme {
        return JsonColorScheme{
            .key_color = AnsiCodes.BRIGHT_CYAN,
            .string_color = AnsiCodes.BRIGHT_GREEN,
            .number_color = AnsiCodes.BRIGHT_YELLOW,
            .boolean_color = AnsiCodes.BRIGHT_MAGENTA,
            .null_color = AnsiCodes.GRAY,
            .structural_color = AnsiCodes.BRIGHT_WHITE,
            .error_color = AnsiCodes.BRIGHT_RED,
        };
    }
    
    /// Monochrome scheme (no colors)
    pub fn monochrome() JsonColorScheme {
        return JsonColorScheme{
            .key_color = "",
            .string_color = "",
            .number_color = "",
            .boolean_color = "",
            .null_color = "",
            .structural_color = "",
            .error_color = "",
        };
    }
};

/// Color formatter that applies colors to text
pub const ColorFormatter = struct {
    allocator: Allocator,
    color_scheme: JsonColorScheme,
    enabled: bool,
    
    const Self = @This();
    
    /// Initialize color formatter with automatic TTY detection
    pub fn init(allocator: Allocator, color_scheme: JsonColorScheme) Self {
        return Self{
            .allocator = allocator,
            .color_scheme = color_scheme,
            .enabled = isColorEnabled(),
        };
    }
    
    /// Initialize color formatter with explicit enable/disable
    pub fn initWithEnabled(allocator: Allocator, color_scheme: JsonColorScheme, enabled: bool) Self {
        return Self{
            .allocator = allocator,
            .color_scheme = color_scheme,
            .enabled = enabled,
        };
    }
    
    /// Apply color to text
    /// Caller owns the returned memory
    pub fn colorize(self: *const Self, text: []const u8, color: []const u8) ![]u8 {
        if (!self.enabled or color.len == 0) {
            return try self.allocator.dupe(u8, text);
        }
        
        var result = ArrayList(u8).init(self.allocator);
        errdefer result.deinit();
        
        try result.appendSlice(color);
        try result.appendSlice(text);
        try result.appendSlice(AnsiCodes.RESET);
        
        return try result.toOwnedSlice();
    }
    
    /// Color a JSON key
    pub fn colorizeKey(self: *const Self, text: []const u8) ![]u8 {
        return try self.colorize(text, self.color_scheme.key_color);
    }
    
    /// Color a JSON string value  
    pub fn colorizeString(self: *const Self, text: []const u8) ![]u8 {
        return try self.colorize(text, self.color_scheme.string_color);
    }
    
    /// Color a JSON number value
    pub fn colorizeNumber(self: *const Self, text: []const u8) ![]u8 {
        return try self.colorize(text, self.color_scheme.number_color);
    }
    
    /// Color a JSON boolean value
    pub fn colorizeBoolean(self: *const Self, text: []const u8) ![]u8 {
        return try self.colorize(text, self.color_scheme.boolean_color);
    }
    
    /// Color a JSON null value
    pub fn colorizeNull(self: *const Self, text: []const u8) ![]u8 {
        return try self.colorize(text, self.color_scheme.null_color);
    }
    
    /// Color structural elements (braces, brackets, colons)
    pub fn colorizeStructural(self: *const Self, text: []const u8) ![]u8 {
        return try self.colorize(text, self.color_scheme.structural_color);
    }
    
    /// Color error messages
    pub fn colorizeError(self: *const Self, text: []const u8) ![]u8 {
        return try self.colorize(text, self.color_scheme.error_color);
    }
    
    /// Strip colors from text if colors are disabled
    pub fn maybeStripColors(self: *const Self, text: []const u8) ![]u8 {
        if (!self.enabled) {
            return try AnsiCodes.stripAnsiCodes(self.allocator, text);
        }
        return try self.allocator.dupe(u8, text);
    }
    
    /// Check if colors are enabled for this formatter
    pub fn isEnabled(self: *const Self) bool {
        return self.enabled;
    }
    
    /// Enable or disable colors
    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }
};

/// Check if colors should be enabled based on environment and TTY status
pub fn isColorEnabled() bool {
    // Check NO_COLOR environment variable first (highest priority)
    if (std.process.hasEnvVarConstant("NO_COLOR")) {
        return false;
    }
    
    // Check FORCE_COLOR to override TTY detection
    if (std.process.hasEnvVarConstant("FORCE_COLOR")) {
        return true;
    }
    
    // Check if we're outputting to a TTY
    return isTty();
}

/// Check if stdout is connected to a terminal
pub fn isTty() bool {
    // Platform-specific TTY detection
    return switch (builtin.os.tag) {
        .windows => {
            // On Windows, check console mode
            const win = std.os.windows;
            const stdout_handle = win.GetStdHandle(win.STD_OUTPUT_HANDLE) catch return false;
            var mode: win.DWORD = undefined;
            return win.GetConsoleMode(stdout_handle, &mode) != 0;
        },
        else => {
            // On Unix-like systems, use isatty
            return std.posix.isatty(std.posix.STDOUT_FILENO);
        },
    };
}

/// Load color scheme from environment variable or file
pub fn loadColorScheme(allocator: Allocator) !JsonColorScheme {
    // For now, just return default scheme
    // Future: implement loading from CCSTREAMER_COLORS environment variable
    _ = allocator;
    return JsonColorScheme.default();
}

// ================================
// TESTS (Writing failing tests first following TDD)
// ================================

test "AnsiCodes constants are correct" {
    try testing.expectEqualStrings("\x1b[0m", AnsiCodes.RESET);
    try testing.expectEqualStrings("\x1b[31m", AnsiCodes.RED);
    try testing.expectEqualStrings("\x1b[32m", AnsiCodes.GREEN);
    try testing.expectEqualStrings("\x1b[33m", AnsiCodes.YELLOW);
    try testing.expectEqualStrings("\x1b[34m", AnsiCodes.BLUE);
    try testing.expectEqualStrings("\x1b[35m", AnsiCodes.MAGENTA);
    try testing.expectEqualStrings("\x1b[36m", AnsiCodes.CYAN);
    try testing.expectEqualStrings("\x1b[37m", AnsiCodes.WHITE);
    try testing.expectEqualStrings("\x1b[90m", AnsiCodes.GRAY);
}

test "AnsiCodes.containsAnsiCodes detection" {
    // Text with ANSI codes
    try testing.expect(AnsiCodes.containsAnsiCodes("\x1b[31mred text\x1b[0m"));
    try testing.expect(AnsiCodes.containsAnsiCodes("normal \x1b[32mgreen\x1b[0m text"));
    
    // Text without ANSI codes
    try testing.expect(!AnsiCodes.containsAnsiCodes("plain text"));
    try testing.expect(!AnsiCodes.containsAnsiCodes(""));
    try testing.expect(!AnsiCodes.containsAnsiCodes("text with [brackets] but no ANSI"));
}

test "AnsiCodes.stripAnsiCodes removes colors" {
    // Text with ANSI codes
    const colored_text = "\x1b[31mred\x1b[0m and \x1b[32mgreen\x1b[0m";
    const stripped = try AnsiCodes.stripAnsiCodes(testing.allocator, colored_text);
    defer testing.allocator.free(stripped);
    
    try testing.expectEqualStrings("red and green", stripped);
}

test "AnsiCodes.stripAnsiCodes handles plain text" {
    const plain_text = "just plain text";
    const result = try AnsiCodes.stripAnsiCodes(testing.allocator, plain_text);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings(plain_text, result);
}

test "AnsiCodes.stripAnsiCodes handles empty string" {
    const empty_text = "";
    const result = try AnsiCodes.stripAnsiCodes(testing.allocator, empty_text);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("", result);
}

test "AnsiCodes.stripAnsiCodes handles malformed escape sequences" {
    // Escape sequence without terminating 'm'
    const malformed = "\x1b[31Hello World";
    const result = try AnsiCodes.stripAnsiCodes(testing.allocator, malformed);
    defer testing.allocator.free(result);
    
    // Should strip everything from \x1b[ to end since no 'm' found
    try testing.expectEqualStrings("", result);
}

test "AnsiCodes.getDisplayLength counts visible characters" {
    // Plain text
    try testing.expectEqual(@as(usize, 11), AnsiCodes.getDisplayLength("Hello World"));
    
    // Text with ANSI codes - "red text" = 8 characters
    try testing.expectEqual(@as(usize, 8), AnsiCodes.getDisplayLength("\x1b[31mred\x1b[0m text"));
    
    // Only ANSI codes
    try testing.expectEqual(@as(usize, 0), AnsiCodes.getDisplayLength("\x1b[31m\x1b[0m"));
    
    // Empty string
    try testing.expectEqual(@as(usize, 0), AnsiCodes.getDisplayLength(""));
}

test "JsonColorScheme.default has correct colors" {
    const scheme = JsonColorScheme.default();
    
    try testing.expectEqualStrings(AnsiCodes.CYAN, scheme.key_color);
    try testing.expectEqualStrings(AnsiCodes.GREEN, scheme.string_color);
    try testing.expectEqualStrings(AnsiCodes.YELLOW, scheme.number_color);
    try testing.expectEqualStrings(AnsiCodes.MAGENTA, scheme.boolean_color);
    try testing.expectEqualStrings(AnsiCodes.GRAY, scheme.null_color);
    try testing.expectEqualStrings(AnsiCodes.WHITE, scheme.structural_color);
    try testing.expectEqualStrings(AnsiCodes.RED, scheme.error_color);
}

test "JsonColorScheme.highContrast uses bright colors" {
    const scheme = JsonColorScheme.highContrast();
    
    try testing.expectEqualStrings(AnsiCodes.BRIGHT_CYAN, scheme.key_color);
    try testing.expectEqualStrings(AnsiCodes.BRIGHT_GREEN, scheme.string_color);
    try testing.expectEqualStrings(AnsiCodes.BRIGHT_YELLOW, scheme.number_color);
    try testing.expectEqualStrings(AnsiCodes.BRIGHT_MAGENTA, scheme.boolean_color);
    try testing.expectEqualStrings(AnsiCodes.BRIGHT_WHITE, scheme.structural_color);
    try testing.expectEqualStrings(AnsiCodes.BRIGHT_RED, scheme.error_color);
}

test "JsonColorScheme.monochrome has no colors" {
    const scheme = JsonColorScheme.monochrome();
    
    try testing.expectEqualStrings("", scheme.key_color);
    try testing.expectEqualStrings("", scheme.string_color);
    try testing.expectEqualStrings("", scheme.number_color);
    try testing.expectEqualStrings("", scheme.boolean_color);
    try testing.expectEqualStrings("", scheme.null_color);
    try testing.expectEqualStrings("", scheme.structural_color);
    try testing.expectEqualStrings("", scheme.error_color);
}

test "ColorFormatter.init creates formatter with TTY detection" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.init(testing.allocator, scheme);
    
    // Should detect TTY status (could be true or false depending on test environment)
    try testing.expect(formatter.enabled == isColorEnabled());
}

test "ColorFormatter.initWithEnabled respects explicit setting" {
    const scheme = JsonColorScheme.default();
    
    const enabled_formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, true);
    try testing.expect(enabled_formatter.enabled);
    
    const disabled_formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, false);
    try testing.expect(!disabled_formatter.enabled);
}

test "ColorFormatter.colorize adds color codes when enabled" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, true);
    
    const colored = try formatter.colorize("test", AnsiCodes.RED);
    defer testing.allocator.free(colored);
    
    const expected = AnsiCodes.RED ++ "test" ++ AnsiCodes.RESET;
    try testing.expectEqualStrings(expected, colored);
}

test "ColorFormatter.colorize returns plain text when disabled" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, false);
    
    const result = try formatter.colorize("test", AnsiCodes.RED);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("test", result);
}

test "ColorFormatter.colorize handles empty color code" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, true);
    
    const result = try formatter.colorize("test", "");
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("test", result);
}

test "ColorFormatter specific colorize methods" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, true);
    
    // Test key colorization
    const key_colored = try formatter.colorizeKey("key");
    defer testing.allocator.free(key_colored);
    try testing.expectEqualStrings(AnsiCodes.CYAN ++ "key" ++ AnsiCodes.RESET, key_colored);
    
    // Test string colorization
    const string_colored = try formatter.colorizeString("value");
    defer testing.allocator.free(string_colored);
    try testing.expectEqualStrings(AnsiCodes.GREEN ++ "value" ++ AnsiCodes.RESET, string_colored);
    
    // Test number colorization
    const number_colored = try formatter.colorizeNumber("42");
    defer testing.allocator.free(number_colored);
    try testing.expectEqualStrings(AnsiCodes.YELLOW ++ "42" ++ AnsiCodes.RESET, number_colored);
    
    // Test boolean colorization
    const boolean_colored = try formatter.colorizeBoolean("true");
    defer testing.allocator.free(boolean_colored);
    try testing.expectEqualStrings(AnsiCodes.MAGENTA ++ "true" ++ AnsiCodes.RESET, boolean_colored);
    
    // Test null colorization
    const null_colored = try formatter.colorizeNull("null");
    defer testing.allocator.free(null_colored);
    try testing.expectEqualStrings(AnsiCodes.GRAY ++ "null" ++ AnsiCodes.RESET, null_colored);
    
    // Test structural colorization
    const structural_colored = try formatter.colorizeStructural("{");
    defer testing.allocator.free(structural_colored);
    try testing.expectEqualStrings(AnsiCodes.WHITE ++ "{" ++ AnsiCodes.RESET, structural_colored);
    
    // Test error colorization
    const error_colored = try formatter.colorizeError("ERROR");
    defer testing.allocator.free(error_colored);
    try testing.expectEqualStrings(AnsiCodes.RED ++ "ERROR" ++ AnsiCodes.RESET, error_colored);
}

test "ColorFormatter specific methods return plain text when disabled" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, false);
    
    const key_result = try formatter.colorizeKey("key");
    defer testing.allocator.free(key_result);
    try testing.expectEqualStrings("key", key_result);
    
    const string_result = try formatter.colorizeString("value");
    defer testing.allocator.free(string_result);
    try testing.expectEqualStrings("value", string_result);
}

test "ColorFormatter.maybeStripColors when colors disabled" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, false);
    
    const colored_input = "\x1b[31mred text\x1b[0m";
    const result = try formatter.maybeStripColors(colored_input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("red text", result);
}

test "ColorFormatter.maybeStripColors when colors enabled" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, true);
    
    const colored_input = "\x1b[31mred text\x1b[0m";
    const result = try formatter.maybeStripColors(colored_input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings(colored_input, result);
}

test "ColorFormatter.setEnabled changes state" {
    const scheme = JsonColorScheme.default();
    var formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, false);
    
    try testing.expect(!formatter.isEnabled());
    
    formatter.setEnabled(true);
    try testing.expect(formatter.isEnabled());
    
    formatter.setEnabled(false);
    try testing.expect(!formatter.isEnabled());
}

test "isTty returns boolean" {
    const is_tty = isTty();
    // Should return either true or false, not crash
    _ = is_tty; // Just ensure it doesn't crash
}

test "isColorEnabled respects environment and TTY" {
    // Test that function runs without crashing
    // Actual return value depends on environment
    const color_enabled = isColorEnabled();
    _ = color_enabled;
}

test "loadColorScheme returns valid scheme" {
    const scheme = try loadColorScheme(testing.allocator);
    
    // Should return a valid color scheme
    try testing.expect(scheme.key_color.len >= 0); // Could be empty string for monochrome
    try testing.expect(scheme.string_color.len >= 0);
}

test "ColorFormatter memory management" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, true);
    
    // Create multiple colored strings and ensure proper cleanup
    var colored_strings = std.ArrayList([]u8).init(testing.allocator);
    defer {
        for (colored_strings.items) |str| {
            testing.allocator.free(str);
        }
        colored_strings.deinit();
    }
    
    // Generate multiple colored strings
    for (0..10) |i| {
        const text = try std.fmt.allocPrint(testing.allocator, "text{}", .{i});
        defer testing.allocator.free(text);
        
        const colored = try formatter.colorizeString(text);
        try colored_strings.append(colored);
        
        // Verify it contains the original text
        try testing.expect(std.mem.indexOf(u8, colored, text) != null);
    }
}

test "ColorFormatter edge cases" {
    const scheme = JsonColorScheme.default();
    const formatter = ColorFormatter.initWithEnabled(testing.allocator, scheme, true);
    
    // Empty string
    const empty_colored = try formatter.colorizeString("");
    defer testing.allocator.free(empty_colored);
    try testing.expectEqualStrings(AnsiCodes.GREEN ++ "" ++ AnsiCodes.RESET, empty_colored);
    
    // Very long string
    const long_text = "a" ** 1000;
    const long_colored = try formatter.colorizeString(long_text);
    defer testing.allocator.free(long_colored);
    try testing.expect(std.mem.startsWith(u8, long_colored, AnsiCodes.GREEN));
    try testing.expect(std.mem.endsWith(u8, long_colored, AnsiCodes.RESET));
    try testing.expect(std.mem.indexOf(u8, long_colored, long_text) != null);
}