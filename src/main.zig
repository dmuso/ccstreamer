//! CC Streamer v2 - CLI application for formatting streamed JSON output from Claude Code
//!
//! This application implements the PRD v2 specification:
//! - Content-focused display (extracts message.content)
//! - Dynamic color assignment for message types  
//! - Proper escape sequence rendering (\n -> newline)
//! - Type-specific formatting (text, tool, error, status)
//! - Follows TDD principles with comprehensive test coverage

const std = @import("std");
const Allocator = std.mem.Allocator;

/// This imports the separate module containing root.zig. Take a look in build.zig for details.
const lib = @import("cc_streamer_lib");

// v2 Processing components
const ColorManager = lib.color_manager.ColorManager;
const ContentExtractor = lib.content_extractor.ContentExtractor;
const EscapeRenderer = lib.escape_renderer.EscapeRenderer;
const FormatterRegistry = lib.type_formatters.FormatterRegistry;
const FormatContext = lib.type_formatters.FormatContext;

/// v2 Message Processing Pipeline
const MessagePipeline = struct {
    allocator: Allocator,
    color_manager: ColorManager,
    content_extractor: ContentExtractor,
    escape_renderer: EscapeRenderer,
    formatter_registry: FormatterRegistry,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .color_manager = try ColorManager.init(allocator),
            .content_extractor = ContentExtractor.init(allocator, .{}),
            .escape_renderer = EscapeRenderer.init(allocator, .{}),
            .formatter_registry = try FormatterRegistry.init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.color_manager.deinit();
        self.formatter_registry.deinit();
    }
    
    /// Process a JSON message through the v2 pipeline
    pub fn processMessage(self: *Self, json_str: []const u8, writer: anytype) !void {
        // Step 1: Extract content from JSON
        var extraction_result = self.content_extractor.extractFromJsonString(json_str) catch |err| {
            // If extraction fails, show error message
            try writer.print("[PARSE ERROR] Invalid JSON input\n", .{});
            return err;  // Propagate error for exit status
        };
        defer extraction_result.deinit(self.allocator);
        
        // Step 2: Determine message type
        // If content is JSON (array or object), use JSON formatter
        const message_type = blk: {
            if (extraction_result.content_type == .json_array or 
                extraction_result.content_type == .json_object) {
                break :blk "json";
            }
            break :blk extraction_result.original_type orelse "text";
        };
        
        // Step 3: Create format context
        var format_context = FormatContext{
            .allocator = self.allocator,
            .color_manager = &self.color_manager,
            .escape_renderer = &self.escape_renderer,
            .config = .{ .show_type_indicators = true },
        };
        
        // Step 4: Format using appropriate formatter
        var format_result = self.formatter_registry.formatMessage(&format_context, message_type, extraction_result) catch |err| {
            try writer.print("[FORMAT ERROR] Failed to format message: {any}\n", .{err});
            return;
        };
        defer format_result.deinit(self.allocator);
        
        // Step 5: Output formatted result
        try writer.writeAll(format_result.formatted_content);
        try writer.writeAll("\n");
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // Initialize v2 processing pipeline
    var pipeline = MessagePipeline.init(allocator) catch |err| {
        try std.io.getStdErr().writer().print("Error initializing pipeline: {any}\n", .{err});
        std.process.exit(1);
    };
    defer pipeline.deinit();

    // Create stdin stream reader
    const config = lib.stream_reader.StreamConfig{};
    var stream_reader = lib.stream_reader.createStdinReader(allocator, config) catch |err| {
        try std.io.getStdErr().writer().print("Error creating stdin reader: {any}\n", .{err});
        std.process.exit(1);
    };
    defer stream_reader.deinit();

    // Read and process messages line by line
    var processed_any_input = false;
    var had_parse_errors = false;
    
    while (stream_reader.readLine() catch |err| switch (err) {
        error.EndOfStream => null,
        error.NotOpenForReading => null,  // stdin not available - treat as end of stream
        error.BrokenPipe => null,         // broken pipe is normal for CLI tools
        else => {
            try std.io.getStdErr().writer().print("Error reading input: {any}\n", .{err});
            std.process.exit(1);
        },
    }) |line| {
        // Skip empty lines
        if (line.len == 0) continue;
        
        processed_any_input = true;
        
        // Process message through v2 pipeline
        pipeline.processMessage(line, stdout) catch |err| {
            had_parse_errors = true;
            // Don't exit on processing errors, just log and continue
            try std.io.getStdErr().writer().print("Processing error: {any}\n", .{err});
        };
    }

    // If no input was processed, show helpful message  
    if (!processed_any_input) {
        try stdout.print("CC Streamer v2 ready - pipe Claude Code JSON to format\n", .{});
    }

    try bw.flush();
    
    // Exit with error status if we had parse errors
    if (had_parse_errors) {
        std.process.exit(1);
    }
}

// =====================================
// TESTS for v2 Message Processing Pipeline
// =====================================

const testing = std.testing;

test "MessagePipeline.init creates pipeline components" {
    var pipeline = try MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    
    // Pipeline should initialize all components
    try testing.expect(pipeline.color_manager.isEnabled());
}

test "MessagePipeline.processMessage handles text message from PRD example" {
    var pipeline = try MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    
    // Disable colors for predictable test output
    pipeline.color_manager.setEnabled(false);
    
    // PRD example: {"type":"text","message":{"content":"Hello, I'll help you with that task.\nLet me check the files."},"timestamp":"..."}
    const json_input = 
        \\{"type":"text","message":{"content":"Hello, I'll help you with that task.\nLet me check the files."},"timestamp":"2024-01-01T00:00:00Z"}
    ;
    
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    
    try pipeline.processMessage(json_input, output.writer());
    
    const result = output.items;
    
    // Should contain the content with newlines rendered
    try testing.expect(std.mem.indexOf(u8, result, "Hello, I'll help you with that task.") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Let me check the files.") != null);
    
    // Should contain newline character (not \n literal)
    try testing.expect(std.mem.indexOf(u8, result, "\n") != null);
    
    // Should NOT contain literal \n
    try testing.expect(std.mem.indexOf(u8, result, "\\n") == null);
}

test "MessagePipeline.processMessage handles tool message with type indicator" {
    var pipeline = try MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    pipeline.color_manager.setEnabled(false);
    
    const json_input = 
        \\{"type":"tool_use","message":{"content":"Reading file contents..."},"tool":"read_file"}
    ;
    
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    
    try pipeline.processMessage(json_input, output.writer());
    
    const result = output.items;
    
    // Should contain tool indicator
    try testing.expect(std.mem.indexOf(u8, result, "[TOOL]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Reading file contents...") != null);
}

test "MessagePipeline.processMessage handles error message with red formatting" {
    var pipeline = try MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    // Keep colors enabled to test error coloring
    pipeline.color_manager.setEnabled(true);
    
    const json_input = 
        \\{"type":"error","message":{"content":"File not found"},"error_code":"ENOENT"}
    ;
    
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    
    try pipeline.processMessage(json_input, output.writer());
    
    const result = output.items;
    
    // Should contain error indicator
    try testing.expect(std.mem.indexOf(u8, result, "[ERROR]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "File not found") != null);
    
    // Should contain ANSI red color code (31)
    try testing.expect(std.mem.indexOf(u8, result, "\x1b[31m") != null);
}

test "MessagePipeline.processMessage handles malformed JSON gracefully" {
    var pipeline = try MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    
    const invalid_json = "invalid json {";
    
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    
    // Should not throw error, but handle gracefully
    try pipeline.processMessage(invalid_json, output.writer());
    
    const result = output.items;
    try testing.expect(std.mem.indexOf(u8, result, "[PARSE ERROR]") != null);
}

test "MessagePipeline.processMessage handles missing content with fallback" {
    var pipeline = try MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    pipeline.color_manager.setEnabled(false);
    
    const json_input = 
        \\{"type":"status","timestamp":"2024-01-01T00:00:00Z","data":"some data"}
    ;
    
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    
    try pipeline.processMessage(json_input, output.writer());
    
    const result = output.items;
    
    // Should show metadata fallback
    try testing.expect(std.mem.indexOf(u8, result, "[status]") != null);
    try testing.expect(result.len > 0);
}

test "MessagePipeline processes multiple message types consistently" {
    var pipeline = try MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    pipeline.color_manager.setEnabled(true);
    
    const message_inputs = [_][]const u8{
        \\{"type":"text","message":{"content":"Text message"}}\\,
        \\{"type":"tool_use","message":{"content":"Tool message"}}\\,
        \\{"type":"error","message":{"content":"Error message"}}\\,
        \\{"type":"status","message":{"content":"Status message"}}\\,
    };
    
    for (message_inputs) |json_input| {
        var output = std.ArrayList(u8).init(testing.allocator);
        defer output.deinit();
        
        try pipeline.processMessage(json_input, output.writer());
        
        // Each message should produce output
        try testing.expect(output.items.len > 0);
    }
    
    // Color manager should have assigned colors to different types
    const stats = pipeline.color_manager.getStats();
    try testing.expect(stats.total_types >= 3); // At least text, tool_use, error, status
}

test "MessagePipeline memory management with multiple messages" {
    var pipeline = try MessagePipeline.init(testing.allocator);
    defer pipeline.deinit();
    
    // Process many messages to test memory cleanup
    const json_template = 
        \\{"type":"text","message":{"content":"Message {d}"}}
    ;
    
    for (0..50) |i| {
        const json_input = try std.fmt.allocPrint(testing.allocator, json_template, .{i});
        defer testing.allocator.free(json_input);
        
        var output = std.ArrayList(u8).init(testing.allocator);
        defer output.deinit();
        
        try pipeline.processMessage(json_input, output.writer());
        
        try testing.expect(output.items.len > 0);
    }
}

test "library module imports work correctly" {
    // Test that we can access all v2 components
    const TestColorManager = lib.color_manager.ColorManager;
    const TestContentExtractor = lib.content_extractor.ContentExtractor;
    const TestEscapeRenderer = lib.escape_renderer.EscapeRenderer;
    const TestFormatterRegistry = lib.type_formatters.FormatterRegistry;
    
    _ = TestColorManager;
    _ = TestContentExtractor;
    _ = TestEscapeRenderer;
    _ = TestFormatterRegistry;
}
