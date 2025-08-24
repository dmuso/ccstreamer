//! Escape Sequence Renderer for CC Streamer v2
//!
//! This module renders JSON escape sequences as actual characters.
//! From PRD v2 requirements:
//! - \n → actual line break
//! - \t → actual tab  
//! - \" → quote character
//! - Other standard JSON escape sequences
//! - Preserve formatting integrity of code blocks

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const unicode = std.unicode;

/// Errors that can occur during escape rendering
pub const EscapeRenderError = error{
    InvalidEscapeSequence,
    InvalidUnicodeSequence,
    OutOfMemory,
};

/// Configuration for escape sequence rendering
pub const EscapeRenderConfig = struct {
    /// Whether to render escape sequences (can disable for debugging)
    enabled: bool = true,
    /// Whether to preserve literal backslashes in non-escape contexts
    preserve_literals: bool = true,
    /// Maximum output length to prevent memory exhaustion
    max_output_length: usize = 1024 * 1024, // 1MB default
    /// Whether to validate Unicode sequences
    validate_unicode: bool = true,
};

/// Statistics about escape sequence rendering
pub const RenderStats = struct {
    sequences_processed: u32 = 0,
    newlines_rendered: u32 = 0,
    tabs_rendered: u32 = 0,
    quotes_rendered: u32 = 0,
    unicode_rendered: u32 = 0,
    invalid_sequences: u32 = 0,
    bytes_processed: usize = 0,
    bytes_output: usize = 0,
};

/// Escape sequence renderer
pub const EscapeRenderer = struct {
    allocator: Allocator,
    config: EscapeRenderConfig,
    stats: RenderStats,

    const Self = @This();

    pub fn init(allocator: Allocator, config: EscapeRenderConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .stats = RenderStats{},
        };
    }

    /// Render escape sequences in text content
    pub fn renderEscapeSequences(self: *Self, input: []const u8) ![]u8 {
        if (!self.config.enabled) {
            return try self.allocator.dupe(u8, input);
        }

        self.stats.bytes_processed += input.len;

        var result = ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\\' and i + 1 < input.len) {
                // Found potential escape sequence
                const escape_char = input[i + 1];
                if (try self.processEscapeSequence(&result, input, &i, escape_char)) {
                    // Sequence was processed, continue
                    continue;
                }
            }
            
            // Regular character, just append
            try result.append(input[i]);
            i += 1;
        }

        // Check output length limit
        if (self.config.max_output_length > 0 and result.items.len > self.config.max_output_length) {
            result.deinit();
            return EscapeRenderError.OutOfMemory;
        }

        const output = try result.toOwnedSlice();
        self.stats.bytes_output += output.len;
        return output;
    }

    /// Process a single escape sequence
    fn processEscapeSequence(self: *Self, result: *ArrayList(u8), input: []const u8, i: *usize, escape_char: u8) !bool {
        self.stats.sequences_processed += 1;

        switch (escape_char) {
            'n' => {
                // Newline
                try result.append('\n');
                self.stats.newlines_rendered += 1;
                i.* += 2;
                return true;
            },
            't' => {
                // Tab
                try result.append('\t');
                self.stats.tabs_rendered += 1;
                i.* += 2;
                return true;
            },
            'r' => {
                // Carriage return
                try result.append('\r');
                i.* += 2;
                return true;
            },
            'b' => {
                // Backspace
                try result.append('\x08');
                i.* += 2;
                return true;
            },
            'f' => {
                // Form feed
                try result.append('\x0C');
                i.* += 2;
                return true;
            },
            '"' => {
                // Double quote
                try result.append('"');
                self.stats.quotes_rendered += 1;
                i.* += 2;
                return true;
            },
            '\'' => {
                // Single quote (not standard JSON but common)
                try result.append('\'');
                self.stats.quotes_rendered += 1;
                i.* += 2;
                return true;
            },
            '\\' => {
                // Literal backslash
                try result.append('\\');
                i.* += 2;
                return true;
            },
            '/' => {
                // Forward slash (optional in JSON)
                try result.append('/');
                i.* += 2;
                return true;
            },
            'u' => {
                // Unicode escape sequence \uXXXX
                return try self.processUnicodeEscape(result, input, i);
            },
            else => {
                // Unknown escape sequence
                if (self.config.preserve_literals) {
                    // Keep the backslash and continue
                    try result.append('\\');
                    i.* += 1;
                    return false; // Let normal processing handle the next character
                } else {
                    // Skip the backslash
                    self.stats.invalid_sequences += 1;
                    i.* += 1;
                    return false;
                }
            }
        }
    }

    /// Process Unicode escape sequence \uXXXX
    fn processUnicodeEscape(self: *Self, result: *ArrayList(u8), input: []const u8, i: *usize) !bool {
        // Need at least \uXXXX (6 characters total)
        if (i.* + 5 >= input.len) {
            self.stats.invalid_sequences += 1;
            if (self.config.preserve_literals) {
                try result.append('\\');
                i.* += 1;
                return false;
            }
            return true;
        }

        // Parse 4 hex digits
        const hex_start = i.* + 2;
        const hex_digits = input[hex_start..hex_start + 4];
        
        const code_point = std.fmt.parseInt(u16, hex_digits, 16) catch {
            self.stats.invalid_sequences += 1;
            if (self.config.preserve_literals) {
                try result.append('\\');
                i.* += 1;
                return false;
            }
            return true;
        };

        // Convert Unicode code point to UTF-8
        if (self.config.validate_unicode) {
            // Check for surrogate pairs (UTF-16 encoding in JSON)
            if (code_point >= 0xD800 and code_point <= 0xDBFF) {
                // High surrogate - look for low surrogate
                return try self.processSurrogatePair(result, input, i, code_point);
            }
        }

        // Encode single code point to UTF-8
        var utf8_bytes: [4]u8 = undefined;
        const utf8_len = unicode.utf8Encode(code_point, &utf8_bytes) catch {
            self.stats.invalid_sequences += 1;
            return true;
        };

        try result.appendSlice(utf8_bytes[0..utf8_len]);
        self.stats.unicode_rendered += 1;
        i.* += 6; // Skip \uXXXX
        return true;
    }

    /// Process UTF-16 surrogate pair in Unicode escapes
    fn processSurrogatePair(self: *Self, result: *ArrayList(u8), input: []const u8, i: *usize, high_surrogate: u16) !bool {
        // Need \uXXXX\uXXXX (12 characters total from current position)
        if (i.* + 11 >= input.len) {
            self.stats.invalid_sequences += 1;
            return true;
        }

        // Check for second \u
        if (input[i.* + 6] != '\\' or input[i.* + 7] != 'u') {
            self.stats.invalid_sequences += 1;
            return true;
        }

        // Parse second hex sequence
        const hex_start = i.* + 8;
        const hex_digits = input[hex_start..hex_start + 4];
        
        const low_surrogate = std.fmt.parseInt(u16, hex_digits, 16) catch {
            self.stats.invalid_sequences += 1;
            return true;
        };

        // Validate surrogate pair
        if (low_surrogate < 0xDC00 or low_surrogate > 0xDFFF) {
            self.stats.invalid_sequences += 1;
            return true;
        }

        // Combine surrogates into single code point
        const code_point: u21 = 0x10000 + ((@as(u21, high_surrogate) - 0xD800) << 10) + (low_surrogate - 0xDC00);

        // Encode to UTF-8
        var utf8_bytes: [4]u8 = undefined;
        const utf8_len = unicode.utf8Encode(code_point, &utf8_bytes) catch {
            self.stats.invalid_sequences += 1;
            return true;
        };

        try result.appendSlice(utf8_bytes[0..utf8_len]);
        self.stats.unicode_rendered += 1;
        i.* += 12; // Skip both \uXXXX sequences
        return true;
    }

    /// Get rendering statistics
    pub fn getStats(self: *const Self) RenderStats {
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats = RenderStats{};
    }

    /// Check if input contains escape sequences that would be processed
    pub fn containsEscapeSequences(input: []const u8) bool {
        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\\' and i + 1 < input.len) {
                const escape_char = input[i + 1];
                switch (escape_char) {
                    'n', 't', 'r', 'b', 'f', '"', '\'', '\\', '/', 'u' => return true,
                    else => {},
                }
            }
            i += 1;
        }
        return false;
    }
};

// =====================================
// TESTS (TDD - Comprehensive test coverage)
// =====================================

test "EscapeRenderer.init creates renderer with config" {
    const config = EscapeRenderConfig{};
    const renderer = EscapeRenderer.init(testing.allocator, config);
    
    try testing.expect(renderer.config.enabled);
    try testing.expect(renderer.config.preserve_literals);
    try testing.expectEqual(@as(u32, 0), renderer.stats.sequences_processed);
}

test "EscapeRenderer.renderEscapeSequences handles newlines" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Hello\\nWorld\\nAgain";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("Hello\nWorld\nAgain", result);
    try testing.expectEqual(@as(u32, 2), renderer.getStats().newlines_rendered);
}

test "EscapeRenderer.renderEscapeSequences handles tabs" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Column1\\tColumn2\\tColumn3";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("Column1\tColumn2\tColumn3", result);
    try testing.expectEqual(@as(u32, 2), renderer.getStats().tabs_rendered);
}

test "EscapeRenderer.renderEscapeSequences handles quotes" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Say \\\"Hello\\\" to the world";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("Say \"Hello\" to the world", result);
    try testing.expectEqual(@as(u32, 2), renderer.getStats().quotes_rendered);
}

test "EscapeRenderer.renderEscapeSequences handles all standard escapes" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "\\n\\t\\r\\b\\f\\\"\\'\\\\\\/";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    const expected = "\n\t\r\x08\x0C\"'\\/"; 
    try testing.expectEqualStrings(expected, result);
    
    const stats = renderer.getStats();
    try testing.expect(stats.sequences_processed >= 9);
}

test "EscapeRenderer.renderEscapeSequences handles Unicode escapes" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Hello \\u0041\\u0042\\u0043"; // ABC in Unicode
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("Hello ABC", result);
    try testing.expectEqual(@as(u32, 3), renderer.getStats().unicode_rendered);
}

test "EscapeRenderer.renderEscapeSequences handles Unicode emoji" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Smile \\ud83d\\ude00"; // 😀 emoji as surrogate pair
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("Smile 😀", result);
    try testing.expectEqual(@as(u32, 1), renderer.getStats().unicode_rendered);
}

test "EscapeRenderer.renderEscapeSequences handles malformed Unicode" {
    const config = EscapeRenderConfig{ .preserve_literals = false };
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Bad \\uGGGG sequence";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("Bad  sequence", result);
    try testing.expect(renderer.getStats().invalid_sequences > 0);
}

test "EscapeRenderer.renderEscapeSequences with preserve_literals keeps unknowns" {
    const config = EscapeRenderConfig{ .preserve_literals = true };
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Unknown \\x escape";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("Unknown \\x escape", result);
}

test "EscapeRenderer.renderEscapeSequences handles mixed content" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Text with\\nnewlines and\\ttabs plus \\\"quotes\\\" and \\u0041 Unicode";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    const expected = "Text with\nnewlines and\ttabs plus \"quotes\" and A Unicode";
    try testing.expectEqualStrings(expected, result);
    
    const stats = renderer.getStats();
    try testing.expectEqual(@as(u32, 1), stats.newlines_rendered);
    try testing.expectEqual(@as(u32, 1), stats.tabs_rendered);
    try testing.expectEqual(@as(u32, 2), stats.quotes_rendered);
    try testing.expectEqual(@as(u32, 1), stats.unicode_rendered);
}

test "EscapeRenderer.renderEscapeSequences when disabled returns original" {
    const config = EscapeRenderConfig{ .enabled = false };
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Keep\\nescapes\\tas\\rliterals";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings(input, result);
    try testing.expectEqual(@as(u32, 0), renderer.getStats().sequences_processed);
}

test "EscapeRenderer.renderEscapeSequences handles empty input" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("", result);
    try testing.expectEqual(@as(usize, 0), renderer.getStats().bytes_output);
}

test "EscapeRenderer.renderEscapeSequences handles only escape sequences" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "\\n\\t\\r";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("\n\t\r", result);
    try testing.expectEqual(@as(u32, 3), renderer.getStats().sequences_processed);
}

test "EscapeRenderer.renderEscapeSequences respects max_output_length" {
    const config = EscapeRenderConfig{ .max_output_length = 5 };
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "This is a very long string that exceeds the limit";
    const result = renderer.renderEscapeSequences(input);
    
    try testing.expectError(EscapeRenderError.OutOfMemory, result);
}

test "EscapeRenderer.containsEscapeSequences detects escape sequences" {
    try testing.expect(EscapeRenderer.containsEscapeSequences("Hello\\nWorld"));
    try testing.expect(EscapeRenderer.containsEscapeSequences("Tab\\there"));
    try testing.expect(EscapeRenderer.containsEscapeSequences("Quote\\\"test"));
    try testing.expect(EscapeRenderer.containsEscapeSequences("Unicode\\u0041"));
    
    try testing.expect(!EscapeRenderer.containsEscapeSequences("Plain text"));
    try testing.expect(!EscapeRenderer.containsEscapeSequences("Backslash at end\\"));
    try testing.expect(!EscapeRenderer.containsEscapeSequences("Unknown\\x"));
}

test "EscapeRenderer statistics tracking" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Complex\\nstring\\twith\\u0020various\\\"escapes";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    const stats = renderer.getStats();
    try testing.expect(stats.bytes_processed > 0);
    try testing.expect(stats.bytes_output > 0);
    try testing.expect(stats.sequences_processed >= 4);
    
    // Reset stats
    renderer.resetStats();
    const reset_stats = renderer.getStats();
    try testing.expectEqual(@as(u32, 0), reset_stats.sequences_processed);
    try testing.expectEqual(@as(usize, 0), reset_stats.bytes_processed);
}

test "EscapeRenderer handles incomplete escape sequences at end" {
    const config = EscapeRenderConfig{ .preserve_literals = true };
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "Text ending with\\";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("Text ending with\\", result);
}

test "EscapeRenderer handles consecutive escape sequences" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const input = "\\n\\n\\t\\t\\\"\\\"";
    const result = try renderer.renderEscapeSequences(input);
    defer testing.allocator.free(result);
    
    try testing.expectEqualStrings("\n\n\t\t\"\"", result);
    try testing.expectEqual(@as(u32, 2), renderer.getStats().newlines_rendered);
    try testing.expectEqual(@as(u32, 2), renderer.getStats().tabs_rendered);
    try testing.expectEqual(@as(u32, 2), renderer.getStats().quotes_rendered);
}

test "EscapeRenderer memory management with multiple renders" {
    const config = EscapeRenderConfig{};
    var renderer = EscapeRenderer.init(testing.allocator, config);
    
    const inputs = [_][]const u8{
        "First\\nmessage",
        "Second\\tmessage",
        "Third\\\"message",
        "Fourth\\u0041message",
    };
    
    var results = ArrayList([]u8).init(testing.allocator);
    defer {
        for (results.items) |result| {
            testing.allocator.free(result);
        }
        results.deinit();
    }
    
    for (inputs) |input| {
        const result = try renderer.renderEscapeSequences(input);
        try results.append(result);
    }
    
    try testing.expectEqual(@as(usize, 4), results.items.len);
    try testing.expect(renderer.getStats().sequences_processed >= 4);
}