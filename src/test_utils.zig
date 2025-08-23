//! Test utilities for CC Streamer
//! Provides common testing functions, mock streams, and test data management
//!
//! This module contains utilities that make testing easier across all components
//! of the CC Streamer application.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Mock stream reader for testing
pub const MockStreamReader = struct {
    data: []const u8,
    position: usize = 0,
    
    const Self = @This();
    
    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .position = 0,
        };
    }
    
    pub fn read(self: *Self, buffer: []u8) !usize {
        if (self.position >= self.data.len) return 0;
        
        const remaining = self.data.len - self.position;
        const to_read = @min(buffer.len, remaining);
        
        @memcpy(buffer[0..to_read], self.data[self.position..self.position + to_read]);
        self.position += to_read;
        
        return to_read;
    }
    
    pub fn reset(self: *Self) void {
        self.position = 0;
    }
    
    pub fn hasMore(self: *const Self) bool {
        return self.position < self.data.len;
    }
};

/// Test data generators for various JSON scenarios
pub const TestDataGenerator = struct {
    allocator: Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }
    
    /// Generate a simple JSON object string
    pub fn simpleObject(self: *Self) ![]u8 {
        const json_str = 
            \\{"name": "test", "value": 42, "active": true}
        ;
        return try self.allocator.dupe(u8, json_str);
    }
    
    /// Generate a nested JSON object
    pub fn nestedObject(self: *Self, depth: u32) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();
        
        // Create nested structure
        for (0..depth) |_| {
            try result.appendSlice("{\"nested\": ");
        }
        
        try result.appendSlice("\"value\"");
        
        for (0..depth) |_| {
            try result.append('}');
        }
        
        return try result.toOwnedSlice();
    }
    
    /// Generate JSON array with specified number of elements
    pub fn jsonArray(self: *Self, element_count: u32) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();
        
        try result.append('[');
        
        for (0..element_count) |i| {
            if (i > 0) try result.appendSlice(", ");
            try result.writer().print("{}", .{i});
        }
        
        try result.append(']');
        
        return try result.toOwnedSlice();
    }
    
    /// Generate malformed JSON for error testing
    pub fn malformedJson(self: *Self) ![]u8 {
        const malformed_samples = [_][]const u8{
            "{\"incomplete\": ",
            "{\"missing_quote: \"value\"}",
            "{\"trailing_comma\": \"value\",}",
            "[1, 2, 3,]",
            "\"unclosed string",
        };
        
        return try self.allocator.dupe(u8, malformed_samples[0]);
    }
    
    /// Generate large JSON object for performance testing
    pub fn largeObject(self: *Self, field_count: u32) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();
        
        try result.append('{');
        
        for (0..field_count) |i| {
            if (i > 0) try result.appendSlice(", ");
            try result.writer().print("\"field{}\": \"value{}\"", .{ i, i });
        }
        
        try result.append('}');
        
        return try result.toOwnedSlice();
    }
    
    /// Generate JSONL (JSON Lines) test data
    pub fn jsonLines(self: *Self, line_count: u32) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();
        
        for (0..line_count) |i| {
            try result.writer().print("{{\"line\": {}, \"data\": \"test{}\"}}\n", .{ i, i });
        }
        
        return try result.toOwnedSlice();
    }
};

/// JSON comparison utilities
pub const JsonComparator = struct {
    /// Compare two JSON strings ignoring whitespace differences
    pub fn compareJsonStrings(expected: []const u8, actual: []const u8) !bool {
        // Simple comparison for now - could be enhanced with proper parsing
        var expected_clean = std.ArrayList(u8).init(testing.allocator);
        defer expected_clean.deinit();
        
        var actual_clean = std.ArrayList(u8).init(testing.allocator);
        defer actual_clean.deinit();
        
        // Remove whitespace for comparison
        for (expected) |char| {
            if (char != ' ' and char != '\n' and char != '\t' and char != '\r') {
                try expected_clean.append(char);
            }
        }
        
        for (actual) |char| {
            if (char != ' ' and char != '\n' and char != '\t' and char != '\r') {
                try actual_clean.append(char);
            }
        }
        
        return std.mem.eql(u8, expected_clean.items, actual_clean.items);
    }
    
    /// Verify JSON structure is valid (basic check)
    pub fn isValidJson(json_str: []const u8) bool {
        // Basic validation - check balanced braces/brackets
        var brace_count: i32 = 0;
        var bracket_count: i32 = 0;
        var in_string = false;
        var escaped = false;
        
        for (json_str) |char| {
            if (escaped) {
                escaped = false;
                continue;
            }
            
            if (char == '\\') {
                escaped = true;
                continue;
            }
            
            if (char == '"') {
                in_string = !in_string;
                continue;
            }
            
            if (in_string) continue;
            
            switch (char) {
                '{' => brace_count += 1,
                '}' => brace_count -= 1,
                '[' => bracket_count += 1,
                ']' => bracket_count -= 1,
                else => {},
            }
            
            if (brace_count < 0 or bracket_count < 0) return false;
        }
        
        return brace_count == 0 and bracket_count == 0 and !in_string;
    }
};

/// Performance measurement utilities
pub const PerformanceMeasurement = struct {
    pub fn measureTime(comptime func: anytype, args: anytype) !struct { result: @TypeOf(@call(.auto, func, args)), duration_ns: u64 } {
        const start_time = std.time.nanoTimestamp();
        const result = try @call(.auto, func, args);
        const end_time = std.time.nanoTimestamp();
        
        return .{
            .result = result,
            .duration_ns = @intCast(end_time - start_time),
        };
    }
    
    pub fn benchmarkFunction(comptime func: anytype, args: anytype, iterations: u32) !u64 {
        var total_time: u64 = 0;
        
        for (0..iterations) |_| {
            const measurement = try measureTime(func, args);
            total_time += measurement.duration_ns;
        }
        
        return total_time / iterations; // Return average time
    }
};

// Unit Tests
test "MockStreamReader basic functionality" {
    const test_data = "Hello, World!";
    var reader = MockStreamReader.init(test_data);
    
    var buffer: [50]u8 = undefined;
    
    // Test reading data
    const bytes_read = try reader.read(&buffer);
    try testing.expectEqual(@as(usize, 13), bytes_read);
    try testing.expectEqualStrings("Hello, World!", buffer[0..bytes_read]);
    
    // Test end of stream
    const no_more_bytes = try reader.read(&buffer);
    try testing.expectEqual(@as(usize, 0), no_more_bytes);
    
    // Test reset functionality
    reader.reset();
    try testing.expect(reader.hasMore());
    
    const bytes_read_after_reset = try reader.read(buffer[0..5]);
    try testing.expectEqual(@as(usize, 5), bytes_read_after_reset);
    try testing.expectEqualStrings("Hello", buffer[0..5]);
}

test "TestDataGenerator simple object" {
    var generator = TestDataGenerator.init(testing.allocator);
    
    const json_obj = try generator.simpleObject();
    defer testing.allocator.free(json_obj);
    
    try testing.expect(JsonComparator.isValidJson(json_obj));
    try testing.expect(std.mem.indexOf(u8, json_obj, "name") != null);
    try testing.expect(std.mem.indexOf(u8, json_obj, "42") != null);
}

test "TestDataGenerator nested object" {
    var generator = TestDataGenerator.init(testing.allocator);
    
    const nested_json = try generator.nestedObject(3);
    defer testing.allocator.free(nested_json);
    
    try testing.expect(JsonComparator.isValidJson(nested_json));
    
    // Count the nesting depth
    var brace_count: u32 = 0;
    var max_depth: u32 = 0;
    var current_depth: u32 = 0;
    
    for (nested_json) |char| {
        switch (char) {
            '{' => {
                current_depth += 1;
                max_depth = @max(max_depth, current_depth);
                brace_count += 1;
            },
            '}' => current_depth -= 1,
            else => {},
        }
    }
    
    try testing.expectEqual(@as(u32, 3), max_depth);
}

test "TestDataGenerator JSON array" {
    var generator = TestDataGenerator.init(testing.allocator);
    
    const array_json = try generator.jsonArray(5);
    defer testing.allocator.free(array_json);
    
    try testing.expect(JsonComparator.isValidJson(array_json));
    try testing.expect(std.mem.startsWith(u8, array_json, "["));
    try testing.expect(std.mem.endsWith(u8, array_json, "]"));
}

test "TestDataGenerator JSONL" {
    var generator = TestDataGenerator.init(testing.allocator);
    
    const jsonl = try generator.jsonLines(3);
    defer testing.allocator.free(jsonl);
    
    // Count newlines
    const newline_count = std.mem.count(u8, jsonl, "\n");
    try testing.expectEqual(@as(usize, 3), newline_count);
    
    // Each line should be valid JSON
    var line_iterator = std.mem.splitScalar(u8, jsonl, '\n');
    var line_count: u32 = 0;
    while (line_iterator.next()) |line| {
        if (line.len > 0) {
            try testing.expect(JsonComparator.isValidJson(line));
            line_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 3), line_count);
}

test "JsonComparator basic validation" {
    // Valid JSON
    try testing.expect(JsonComparator.isValidJson("{\"test\": \"value\"}"));
    try testing.expect(JsonComparator.isValidJson("[1, 2, 3]"));
    try testing.expect(JsonComparator.isValidJson("\"simple string\""));
    
    // Invalid JSON
    try testing.expect(!JsonComparator.isValidJson("{\"unclosed\": "));
    try testing.expect(!JsonComparator.isValidJson("[1, 2, 3"));
    try testing.expect(!JsonComparator.isValidJson("\"unclosed string"));
}

test "JsonComparator string comparison" {
    const json1 = "{\"test\": \"value\"}";
    const json2 = "{\n  \"test\": \"value\"\n}";
    
    try testing.expect(try JsonComparator.compareJsonStrings(json1, json2));
    
    const json3 = "{\"different\": \"value\"}";
    try testing.expect(!try JsonComparator.compareJsonStrings(json1, json3));
}

test "PerformanceMeasurement timing" {
    const TestFunction = struct {
        fn slowFunction() !u32 {
            // Simulate some work
            var sum: u32 = 0;
            for (0..1000) |i| {
                sum += @intCast(i);
            }
            return sum;
        }
    };
    
    const measurement = try PerformanceMeasurement.measureTime(TestFunction.slowFunction, .{});
    
    // Should have taken some measurable time
    try testing.expect(measurement.duration_ns > 0);
    try testing.expectEqual(@as(u32, 499500), measurement.result); // Sum of 0 to 999
}