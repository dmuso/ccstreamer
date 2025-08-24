//! End-to-End Tests for CC Streamer v2
//!
//! These tests verify that the complete v2 implementation meets the PRD v2 requirements:
//! - Content-focused display (extracts message.content)
//! - Dynamic color assignment for message types
//! - Proper escape sequence rendering (\n -> newline)
//! - Type-specific formatting
//! - Error handling and recovery

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqualStrings = testing.expectEqualStrings;

// Import the main application components
const main = @import("../src/main.zig");
const lib = @import("cc_streamer_lib");

// Test helper for capturing output
const TestOutputCapture = struct {
    buffer: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn writer(self: *Self) std.ArrayList(u8).Writer {
        return self.buffer.writer();
    }

    pub fn getOutput(self: *const Self) []const u8 {
        return self.buffer.items;
    }

    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
    }
};

// =====================================
// PRD v2 REQUIREMENT VERIFICATION TESTS
// =====================================

test "E2E: PRD Example Transformation - Text Message" {
    // From PRD v2: Transform JSON to content-focused display
    // Input: {"type":"text","message":{"content":"Hello, I'll help you with that task.\nLet me check the files."},"timestamp":"..."}
    // Expected output: Content with rendered newlines, no JSON structure

    var pipeline = try main.MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();

    // Disable colors for predictable test output
    pipeline.color_manager.setEnabled(false);

    const input =
        \\{"type":"text","message":{"content":"Hello, I'll help you with that task.\nLet me check the files."},"timestamp":"2024-01-01T00:00:00Z"}
    ;

    var capture = TestOutputCapture.init(testing.allocator);
    defer capture.deinit();

    try pipeline.processMessage(input, capture.writer());

    const output = capture.getOutput();

    // PRD Requirement: Content-focused display
    try expect(std.mem.indexOf(u8, output, "Hello, I'll help you with that task.") != null);
    try expect(std.mem.indexOf(u8, output, "Let me check the files.") != null);

    // PRD Requirement: Proper escape sequence rendering (\n -> newline)
    try expect(std.mem.indexOf(u8, output, "\n") != null);
    try expect(std.mem.indexOf(u8, output, "\\n") == null); // No literal \n

    // PRD Requirement: Hide unnecessary JSON structure
    try expect(std.mem.indexOf(u8, output, "timestamp") == null);
    try expect(std.mem.indexOf(u8, output, "2024-01-01") == null);
    try expect(std.mem.indexOf(u8, output, "{") == null);
    try expect(std.mem.indexOf(u8, output, "}") == null);
}

test "E2E: Dynamic Color Assignment System" {
    // PRD Requirement: Dynamic color assignment for message types
    // Same type should get same color, different types should get different colors

    var pipeline = try main.MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();

    // Enable colors for this test
    pipeline.color_manager.setEnabled(true);

    const text_message1 =
        \\{"type":"text","message":{"content":"First text message"}}
    ;
    const text_message2 =
        \\{"type":"text","message":{"content":"Second text message"}}
    ;
    const tool_message =
        \\{"type":"tool_use","message":{"content":"Tool invocation"}}
    ;

    var capture = TestOutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Process first text message
    try pipeline.processMessage(text_message1, capture.writer());
    const output1 = try testing.allocator.dupe(u8, capture.getOutput());
    defer testing.allocator.free(output1);
    capture.reset();

    // Process second text message
    try pipeline.processMessage(text_message2, capture.writer());
    const output2 = try testing.allocator.dupe(u8, capture.getOutput());
    defer testing.allocator.free(output2);
    capture.reset();

    // Process tool message
    try pipeline.processMessage(tool_message, capture.writer());
    const output3 = try testing.allocator.dupe(u8, capture.getOutput());
    defer testing.allocator.free(output3);

    // PRD Requirement: Consistent color assignment for same type
    const color1 = extractAnsiColor(output1);
    const color2 = extractAnsiColor(output2);
    if (color1 != null and color2 != null) {
        try expectEqualStrings(color1.?, color2.?);
    }

    // PRD Requirement: Different colors for different types
    const tool_color = extractAnsiColor(output3);
    if (color1 != null and tool_color != null) {
        try expect(!std.mem.eql(u8, color1.?, tool_color.?));
    }

    // Verify color manager tracked the types
    const stats = pipeline.color_manager.getStats();
    try expect(stats.total_types >= 2); // At least text and tool_use
}

test "E2E: Type-Based Formatting System" {
    // PRD Requirement: Different display strategies for different types

    var pipeline = try main.MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    pipeline.color_manager.setEnabled(false); // Focus on formatting, not colors

    var capture = TestOutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Test text message (no prefix per PRD)
    const text_msg =
        \\{"type":"text","message":{"content":"Plain text content"}}
    ;
    try pipeline.processMessage(text_msg, capture.writer());
    const text_output = try testing.allocator.dupe(u8, capture.getOutput());
    defer testing.allocator.free(text_output);
    capture.reset();

    // Text messages should not have type indicators per PRD
    try expect(std.mem.indexOf(u8, text_output, "[") == null);
    try expect(std.mem.indexOf(u8, text_output, "Plain text content") != null);

    // Test tool message (should have [TOOL] prefix)
    const tool_msg =
        \\{"type":"tool_use","message":{"content":"Tool operation"}}
    ;
    try pipeline.processMessage(tool_msg, capture.writer());
    const tool_output = try testing.allocator.dupe(u8, capture.getOutput());
    defer testing.allocator.free(tool_output);
    capture.reset();

    try expect(std.mem.indexOf(u8, tool_output, "[TOOL]") != null);
    try expect(std.mem.indexOf(u8, tool_output, "Tool operation") != null);

    // Test error message (should have [ERROR] prefix and red color if enabled)
    const error_msg =
        \\{"type":"error","message":{"content":"Something failed"}}
    ;
    try pipeline.processMessage(error_msg, capture.writer());
    const error_output = try testing.allocator.dupe(u8, capture.getOutput());
    defer testing.allocator.free(error_output);

    try expect(std.mem.indexOf(u8, error_output, "[ERROR]") != null);
    try expect(std.mem.indexOf(u8, error_output, "Something failed") != null);
}

test "E2E: Comprehensive Escape Sequence Rendering" {
    // PRD Requirement: Render all standard JSON escape sequences correctly

    var pipeline = try main.MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    pipeline.color_manager.setEnabled(false);

    const message_with_escapes =
        \\{"type":"text","message":{"content":"Line 1\nLine 2\tTabbed\r\nWindows line\b\f\"Quoted\""}}
    ;

    var capture = TestOutputCapture.init(testing.allocator);
    defer capture.deinit();

    try pipeline.processMessage(message_with_escapes, capture.writer());
    const output = capture.getOutput();

    // Verify all escape sequences are rendered correctly
    try expect(std.mem.indexOf(u8, output, "Line 1\nLine 2") != null); // \n -> newline
    try expect(std.mem.indexOf(u8, output, "\t") != null); // \t -> tab
    try expect(std.mem.indexOf(u8, output, "\r") != null); // \r -> carriage return
    try expect(std.mem.indexOf(u8, output, "\"Quoted\"") != null); // \" -> quote

    // Verify literals are not present
    try expect(std.mem.indexOf(u8, output, "\\n") == null);
    try expect(std.mem.indexOf(u8, output, "\\t") == null);
    try expect(std.mem.indexOf(u8, output, "\\r") == null);
    try expect(std.mem.indexOf(u8, output, "\\\"") == null);
}

test "E2E: Error Recovery and Graceful Degradation" {
    // PRD Requirement: Robust error handling that continues processing

    var pipeline = try main.MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();

    var capture = TestOutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Test 1: Malformed JSON
    try pipeline.processMessage("invalid json {", capture.writer());
    var output = capture.getOutput();
    try expect(std.mem.indexOf(u8, output, "[PARSE ERROR]") != null);
    capture.reset();

    // Test 2: Missing message.content (should use fallback)
    try pipeline.processMessage(
        \\{"type":"status","data":"some data"}
    , capture.writer());
    output = capture.getOutput();
    try expect(output.len > 0); // Should produce fallback output
    try expect(std.mem.indexOf(u8, output, "[status]") != null);
    capture.reset();

    // Test 3: Empty content
    try pipeline.processMessage(
        \\{"type":"text","message":{"content":""}}
    , capture.writer());
    output = capture.getOutput();
    try expect(output.len > 0); // Should still produce output (even if minimal)
}

test "E2E: NO_COLOR Environment Variable Support" {
    // PRD Requirement: Support NO_COLOR environment variable for accessibility

    var pipeline = try main.MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();

    // Force disable colors to simulate NO_COLOR
    pipeline.color_manager.setEnabled(false);

    const colorful_message =
        \\{"type":"error","message":{"content":"Error message"}}
    ;

    var capture = TestOutputCapture.init(testing.allocator);
    defer capture.deinit();

    try pipeline.processMessage(colorful_message, capture.writer());
    const output = capture.getOutput();

    // Should contain error indicator but no ANSI color codes
    try expect(std.mem.indexOf(u8, output, "[ERROR]") != null);
    try expect(std.mem.indexOf(u8, output, "Error message") != null);
    try expect(std.mem.indexOf(u8, output, "\x1b[") == null); // No ANSI codes
}

test "E2E: Streaming Performance with Multiple Messages" {
    // PRD Requirement: Maintain real-time streaming capability

    var pipeline = try main.MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();

    var capture = TestOutputCapture.init(testing.allocator);
    defer capture.deinit();

    const message_template =
        \\{"type":"text","message":{"content":"Message {d}"}}
    ;

    // Simulate processing a stream of messages
    const start_time = std.time.milliTimestamp();

    for (0..100) |i| {
        const message = try std.fmt.allocPrint(testing.allocator, message_template, .{i});
        defer testing.allocator.free(message);

        try pipeline.processMessage(message, capture.writer());

        // Each message should produce output
        try expect(capture.getOutput().len > 0);
        capture.reset();
    }

    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;

    // Should process 100 messages in reasonable time (less than 100ms on modern hardware)
    // This is a loose performance check - main goal is to ensure no major performance regression
    try expect(duration_ms < 1000); // Less than 1 second for 100 messages
}

test "E2E: Complete PRD v2 Transformation Examples" {
    // Comprehensive test of all PRD examples working together

    var pipeline = try main.MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    pipeline.color_manager.setEnabled(true);

    var capture = TestOutputCapture.init(testing.allocator);
    defer capture.deinit();

    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        should_contain: []const []const u8,
        should_not_contain: []const []const u8,
    }{
        .{
            .name = "Text Message",
            .input =
            \\{"type":"text","message":{"content":"Hello world\nSecond line"},"timestamp":"ignored"}
            ,
            .should_contain = &[_][]const u8{ "Hello world", "Second line", "\n" },
            .should_not_contain = &[_][]const u8{ "timestamp", "ignored", "\\n", "{", "}" },
        },
        .{
            .name = "Tool Invocation",
            .input =
            \\{"type":"tool_use","message":{"content":"Reading file"},"tool":"read_file"}
            ,
            .should_contain = &[_][]const u8{ "[TOOL]", "Reading file" },
            .should_not_contain = &[_][]const u8{ "tool", "read_file" },
        },
        .{
            .name = "Error Message",
            .input =
            \\{"type":"error","message":{"content":"File not found"},"error_code":"404"}
            ,
            .should_contain = &[_][]const u8{ "[ERROR]", "File not found", "\x1b[31m" }, // Red color
            .should_not_contain = &[_][]const u8{ "error_code", "404" },
        },
        .{
            .name = "Status Message",
            .input =
            \\{"type":"status","message":{"content":"Processing..."}}
            ,
            .should_contain = &[_][]const u8{"Processing..."},
            .should_not_contain = &[_][]const u8{"[STATUS]"}, // Status messages are minimal
        },
    };

    for (test_cases) |test_case| {
        capture.reset();
        try pipeline.processMessage(test_case.input, capture.writer());
        const output = capture.getOutput();

        // Verify required content is present
        for (test_case.should_contain) |required| {
            if (std.mem.indexOf(u8, output, required) == null) {
                std.debug.print("Test case '{}' failed: missing '{}' in output: '{}'\n", .{ test_case.name, required, output });
                return error.TestFailed;
            }
        }

        // Verify unwanted content is absent
        for (test_case.should_not_contain) |forbidden| {
            if (std.mem.indexOf(u8, output, forbidden) != null) {
                std.debug.print("Test case '{}' failed: found forbidden '{}' in output: '{}'\n", .{ test_case.name, forbidden, output });
                return error.TestFailed;
            }
        }
    }
}

// =====================================
// UTILITY FUNCTIONS
// =====================================

/// Extract ANSI color code from output text for testing
fn extractAnsiColor(text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "\x1b[")) |start| {
        const color_start = start;
        if (std.mem.indexOfScalarPos(u8, text, start, 'm')) |end| {
            return text[color_start .. end + 1];
        }
    }
    return null;
}
