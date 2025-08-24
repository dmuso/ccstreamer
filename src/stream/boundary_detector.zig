//! JSON boundary detection for CC Streamer
//! Detects complete JSON object boundaries in streaming input
//!
//! This module provides functionality to identify complete JSON objects
//! in a stream, handling nested structures and string escaping properly.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Errors that can occur during boundary detection
pub const BoundaryError = error{
    InvalidJson,
    UnexpectedCharacter,
    UnterminatedString,
    NestedTooDeep,
    OutOfMemory,
} || Allocator.Error;

/// State of the JSON boundary detector
pub const DetectorState = enum {
    InObject,
    InArray,
    InString,
    InNumber,
    InLiteral, // true, false, null
    BetweenValues,
    Complete,
    Error,
};

/// Configuration for the boundary detector
pub const DetectorConfig = struct {
    max_nesting_depth: u32 = 1000,
    track_position: bool = true,
};

/// Position tracking for error reporting
pub const Position = struct {
    line: u32 = 1,
    column: u32 = 1,

    pub fn advance(self: *Position, char: u8) void {
        if (char == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
    }
};

/// JSON boundary detector
pub const BoundaryDetector = struct {
    config: DetectorConfig,
    position: Position,

    // Parsing state
    brace_depth: i32 = 0,
    bracket_depth: i32 = 0,
    in_string: bool = false,
    escape_next: bool = false,
    in_literal: bool = false,
    literal_buffer: [5]u8 = undefined, // For "true", "false", "null"
    literal_pos: u8 = 0,

    // State tracking
    state: DetectorState = .BetweenValues,

    const Self = @This();

    pub fn init(config: DetectorConfig) Self {
        return Self{
            .config = config,
            .position = Position{},
        };
    }

    pub fn reset(self: *Self) void {
        self.brace_depth = 0;
        self.bracket_depth = 0;
        self.in_string = false;
        self.escape_next = false;
        self.in_literal = false;
        self.literal_pos = 0;
        self.state = .BetweenValues;
        if (self.config.track_position) {
            self.position = Position{};
        }
    }

    /// Process a single character and update detector state
    pub fn processChar(self: *Self, char: u8) BoundaryError!DetectorState {
        if (self.config.track_position) {
            self.position.advance(char);
        }

        // Handle string escaping
        if (self.escape_next) {
            self.escape_next = false;
            return self.state;
        }

        if (self.in_string) {
            return self.processStringChar(char);
        }

        if (self.in_literal) {
            return self.processLiteralChar(char);
        }

        return self.processStructuralChar(char);
    }

    /// Process a character when inside a string
    fn processStringChar(self: *Self, char: u8) BoundaryError!DetectorState {
        switch (char) {
            '\\' => {
                self.escape_next = true;
            },
            '"' => {
                self.in_string = false;
                self.state = .BetweenValues;
            },
            else => {
                // Regular string character, continue
            },
        }
        return self.state;
    }

    /// Process a character when inside a literal (true, false, null)
    fn processLiteralChar(self: *Self, char: u8) BoundaryError!DetectorState {
        switch (char) {
            'a'...'z' => {
                if (self.literal_pos >= self.literal_buffer.len) {
                    return BoundaryError.InvalidJson;
                }
                self.literal_buffer[self.literal_pos] = char;
                self.literal_pos += 1;
            },
            else => {
                // End of literal, validate it
                const literal = self.literal_buffer[0..self.literal_pos];
                if (!isValidLiteral(literal)) {
                    return BoundaryError.InvalidJson;
                }

                self.in_literal = false;
                self.literal_pos = 0;
                self.state = .BetweenValues;

                // Process this character as a structural character
                return self.processStructuralChar(char);
            },
        }
        return self.state;
    }

    /// Process structural JSON characters
    fn processStructuralChar(self: *Self, char: u8) BoundaryError!DetectorState {
        switch (char) {
            '{' => {
                self.brace_depth += 1;
                if (self.brace_depth > self.config.max_nesting_depth) {
                    return BoundaryError.NestedTooDeep;
                }
                self.state = .InObject;
            },
            '}' => {
                self.brace_depth -= 1;
                if (self.brace_depth < 0) {
                    return BoundaryError.InvalidJson;
                }
                if (self.brace_depth == 0 and self.bracket_depth == 0) {
                    self.state = .Complete;
                } else {
                    self.state = .BetweenValues;
                }
            },
            '[' => {
                self.bracket_depth += 1;
                if (self.bracket_depth > self.config.max_nesting_depth) {
                    return BoundaryError.NestedTooDeep;
                }
                self.state = .InArray;
            },
            ']' => {
                self.bracket_depth -= 1;
                if (self.bracket_depth < 0) {
                    return BoundaryError.InvalidJson;
                }
                if (self.brace_depth == 0 and self.bracket_depth == 0) {
                    self.state = .Complete;
                } else {
                    self.state = .BetweenValues;
                }
            },
            '"' => {
                self.in_string = true;
                self.state = .InString;
            },
            '0'...'9', '-' => {
                self.state = .InNumber;
            },
            't', 'f', 'n' => {
                self.in_literal = true;
                self.literal_buffer[0] = char;
                self.literal_pos = 1;
                self.state = .InLiteral;
            },
            ' ', '\t', '\n', '\r' => {
                // Whitespace, ignore
            },
            ':',
            ',',
            => {
                // Structural characters, continue parsing
                self.state = .BetweenValues;
            },
            else => {
                // Check if we're in a number and this could be part of it
                if (self.state == .InNumber) {
                    switch (char) {
                        '0'...'9', '.', 'e', 'E', '+', '-' => {
                            // Valid number character, continue
                        },
                        else => {
                            // End of number, process as new character
                            self.state = .BetweenValues;
                            return self.processStructuralChar(char);
                        },
                    }
                } else {
                    return BoundaryError.UnexpectedCharacter;
                }
            },
        }

        return self.state;
    }

    /// Check if the JSON object/array is complete
    pub fn isComplete(self: *const Self) bool {
        return self.state == .Complete or (self.brace_depth == 0 and self.bracket_depth == 0 and !self.in_string and !self.in_literal);
    }

    /// Check if currently in an error state
    pub fn hasError(self: *const Self) bool {
        return self.state == .Error or self.brace_depth < 0 or self.bracket_depth < 0;
    }

    /// Get current nesting depth
    pub fn getDepth(self: *const Self) u32 {
        return @intCast(@max(0, self.brace_depth) + @max(0, self.bracket_depth));
    }

    /// Get current position (if tracking is enabled)
    pub fn getPosition(self: *const Self) ?Position {
        if (self.config.track_position) {
            return self.position;
        }
        return null;
    }
};

/// Check if a string is a valid JSON literal
fn isValidLiteral(literal: []const u8) bool {
    return std.mem.eql(u8, literal, "true") or
        std.mem.eql(u8, literal, "false") or
        std.mem.eql(u8, literal, "null");
}

/// Extract complete JSON objects from a string
pub fn extractJsonObjects(input: []const u8, allocator: Allocator) ![][]const u8 {
    var detector = BoundaryDetector.init(DetectorConfig{});
    var objects = std.ArrayList([]const u8).init(allocator);
    errdefer objects.deinit();

    var start: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const char = input[i];

        // Skip leading whitespace before starting new object
        if (detector.brace_depth == 0 and detector.bracket_depth == 0 and
            (char == ' ' or char == '\t' or char == '\n' or char == '\r'))
        {
            start = i + 1;
            i += 1;
            continue;
        }

        _ = detector.processChar(char) catch {
            // Reset detector and skip to next potential JSON start
            detector.reset();
            while (i < input.len and input[i] != '{' and input[i] != '[') {
                i += 1;
            }
            if (i < input.len) {
                start = i;
            }
            continue;
        };

        if (detector.isComplete()) {
            const object_text = std.mem.trim(u8, input[start .. i + 1], " \t\n\r");
            if (object_text.len > 0) {
                try objects.append(object_text);
            }
            detector.reset();
            start = i + 1;
        }

        i += 1;
    }

    return objects.toOwnedSlice();
}

// Unit Tests
test "BoundaryDetector simple object" {
    var detector = BoundaryDetector.init(DetectorConfig{});

    const json = "{\"test\": \"value\"}";

    for (json) |char| {
        const state = try detector.processChar(char);
        _ = state;
    }

    try testing.expect(detector.isComplete());
    try testing.expect(!detector.hasError());
    try testing.expectEqual(@as(u32, 0), detector.getDepth());
}

test "BoundaryDetector nested objects" {
    var detector = BoundaryDetector.init(DetectorConfig{});

    const json = "{\"outer\": {\"inner\": \"value\"}}";

    for (json) |char| {
        _ = try detector.processChar(char);
    }

    try testing.expect(detector.isComplete());
    try testing.expect(!detector.hasError());
}

test "BoundaryDetector arrays" {
    var detector = BoundaryDetector.init(DetectorConfig{});

    const json = "[1, 2, {\"nested\": true}, false]";

    for (json) |char| {
        _ = try detector.processChar(char);
    }

    try testing.expect(detector.isComplete());
    try testing.expect(!detector.hasError());
}

test "BoundaryDetector string with escapes" {
    var detector = BoundaryDetector.init(DetectorConfig{});

    const json = "{\"escaped\": \"test\\\"quote\\\\\"}";

    for (json) |char| {
        _ = try detector.processChar(char);
    }

    try testing.expect(detector.isComplete());
    try testing.expect(!detector.hasError());
}

test "BoundaryDetector literals" {
    var detector = BoundaryDetector.init(DetectorConfig{});

    const json = "{\"bool\": true, \"null\": null, \"false\": false}";

    for (json) |char| {
        _ = try detector.processChar(char);
    }

    try testing.expect(detector.isComplete());
    try testing.expect(!detector.hasError());
}

test "BoundaryDetector numbers" {
    var detector = BoundaryDetector.init(DetectorConfig{});

    const json = "{\"int\": 42, \"float\": 3.14, \"exp\": 1e-5, \"negative\": -123}";

    for (json) |char| {
        _ = try detector.processChar(char);
    }

    try testing.expect(detector.isComplete());
    try testing.expect(!detector.hasError());
}

test "BoundaryDetector incomplete object" {
    var detector = BoundaryDetector.init(DetectorConfig{});

    const json = "{\"incomplete\": \"value\""; // Missing closing brace

    for (json) |char| {
        _ = try detector.processChar(char);
    }

    try testing.expect(!detector.isComplete());
    try testing.expect(!detector.hasError()); // Not an error, just incomplete
}

test "BoundaryDetector invalid JSON" {
    var detector = BoundaryDetector.init(DetectorConfig{});

    const invalid_cases = [_][]const u8{
        "}", // Closing brace without opening
        "{\"unclosed\": \"", // Unclosed string
        "{\"invalid\": trueee}", // Invalid literal
    };

    for (invalid_cases) |json| {
        detector.reset();
        var had_error = false;

        for (json) |char| {
            if (detector.processChar(char)) |_| {
                // Continue processing
            } else |_| {
                had_error = true;
                break;
            }
        }

        // Different validation for different types of invalid JSON
        if (std.mem.eql(u8, json, "}")) {
            // Closing brace without opening should cause error or detector.hasError
            try testing.expect(had_error or detector.hasError());
        } else if (std.mem.eql(u8, json, "{\"unclosed\": \"")) {
            // Unclosed string should not be complete and may not error immediately
            try testing.expect(!detector.isComplete());
        } else {
            // Other invalid cases should error
            try testing.expect(had_error or detector.hasError());
        }
    }
}

test "BoundaryDetector depth limiting" {
    var detector = BoundaryDetector.init(DetectorConfig{
        .max_nesting_depth = 3,
    });

    // Create deeply nested object
    var deep_json = std.ArrayList(u8).init(testing.allocator);
    defer deep_json.deinit();

    // Create 5 levels of nesting (should exceed limit of 3)
    for (0..5) |_| {
        try deep_json.append('{');
        try deep_json.appendSlice("\"nested\":");
    }
    try deep_json.appendSlice("\"value\"");
    for (0..5) |_| {
        try deep_json.append('}');
    }

    var had_error = false;
    for (deep_json.items) |char| {
        if (detector.processChar(char)) |_| {
            // Continue
        } else |_| {
            // Expected error - nesting too deep
            had_error = true;
            break;
        }
    }

    try testing.expect(had_error);
}

test "BoundaryDetector position tracking" {
    var detector = BoundaryDetector.init(DetectorConfig{
        .track_position = true,
    });

    const json = "{\n  \"line2\": \"value\"\n}";

    for (json) |char| {
        _ = try detector.processChar(char);
    }

    const pos = detector.getPosition().?;
    try testing.expectEqual(@as(u32, 3), pos.line);
    try testing.expectEqual(@as(u32, 2), pos.column);
}

test "extractJsonObjects multiple objects" {
    const input =
        \\{"first": "object"}
        \\{"second": {"nested": true}}
        \\[1, 2, 3]
    ;

    const objects = try extractJsonObjects(input, testing.allocator);
    defer testing.allocator.free(objects);

    try testing.expectEqual(@as(usize, 3), objects.len);
    try testing.expectEqualStrings("{\"first\": \"object\"}", objects[0]);
    try testing.expectEqualStrings("{\"second\": {\"nested\": true}}", objects[1]);
    try testing.expectEqualStrings("[1, 2, 3]", objects[2]);
}

test "extractJsonObjects with whitespace and invalid JSON" {
    const input =
        \\   {"valid": "object"}   
        \\invalid json here
        \\   {"another": "valid"}
    ;

    const objects = try extractJsonObjects(input, testing.allocator);
    defer testing.allocator.free(objects);

    // Should find exactly 2 valid JSON objects

    try testing.expectEqual(@as(usize, 2), objects.len);
    try testing.expectEqualStrings("{\"valid\": \"object\"}", objects[0]);
    try testing.expectEqualStrings("{\"another\": \"valid\"}", objects[1]);
}
