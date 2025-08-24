//! Type-Specific Message Formatters for CC Streamer v2
//!
//! This module implements the type-based formatting strategy from PRD v2:
//! - Text messages: Clean display with optional type indicators
//! - Tool messages: Clear tool name and parameter formatting  
//! - Error messages: Prominent red formatting
//! - Status messages: Dimmed appearance
//! - Custom formatters for different message types

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;

const ColorManager = @import("../colorizer/color_manager.zig").ColorManager;
const Color = @import("../colorizer/color_manager.zig").Color;
const ContentExtractor = @import("content_extractor.zig").ContentExtractor;
const ExtractionResult = @import("content_extractor.zig").ExtractionResult;
const EscapeRenderer = @import("escape_renderer.zig").EscapeRenderer;

/// Errors that can occur during formatting
pub const FormatError = error{
    UnknownMessageType,
    InvalidContent,
    FormattingFailed,
    OutOfMemory,
    InvalidEscapeSequence,
    InvalidUnicodeSequence,
};

/// Configuration for message formatting
pub const FormatConfig = struct {
    /// Whether to show type indicators/prefixes
    show_type_indicators: bool = true,
    /// Maximum line width for wrapping (0 = no wrapping)
    max_line_width: usize = 0,
    /// Indentation for continued lines
    continuation_indent: u8 = 7, // Length of "[TYPE] " prefix
    /// Whether to use bright colors for better visibility
    use_bright_colors: bool = false,
    /// Whether to show timestamps when available
    show_timestamps: bool = false,
};

/// Result of message formatting operation  
pub const FormatResult = struct {
    formatted_content: []const u8,
    type_indicator: ?[]const u8,
    message_type: []const u8,
    color_used: ?Color,
    lines_count: u32,
    
    pub fn deinit(self: *FormatResult, allocator: Allocator) void {
        allocator.free(self.formatted_content);
        if (self.type_indicator) |indicator| {
            allocator.free(indicator);
        }
        allocator.free(self.message_type);
    }
};

/// Base formatter interface
pub const MessageFormatter = struct {
    format_fn: *const fn(*MessageFormatter, *FormatContext, ExtractionResult) FormatError!FormatResult,
    
    /// Format a message with the given context
    pub fn format(self: *MessageFormatter, context: *FormatContext, extraction_result: ExtractionResult) FormatError!FormatResult {
        return self.format_fn(self, context, extraction_result);
    }
};

/// Context passed to formatters
pub const FormatContext = struct {
    allocator: Allocator,
    color_manager: *ColorManager,
    escape_renderer: *EscapeRenderer,
    config: FormatConfig,
};

/// Text message formatter - clean, minimal formatting
pub const TextFormatter = struct {
    base: MessageFormatter,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .base = MessageFormatter{ .format_fn = formatImpl },
        };
    }
    
    fn formatImpl(base: *MessageFormatter, context: *FormatContext, extraction_result: ExtractionResult) FormatError!FormatResult {
        _ = base;
        
        // Render escape sequences first
        const rendered_content = try context.escape_renderer.renderEscapeSequences(extraction_result.content);
        errdefer context.allocator.free(rendered_content);
        
        // Get color for text type
        const color = try context.color_manager.getColorForType("text");
        
        // Apply coloring if enabled
        var final_content: []u8 = undefined;
        if (color) |c| {
            final_content = try applyColorToContent(context.allocator, rendered_content, c);
            context.allocator.free(rendered_content);
        } else {
            final_content = rendered_content;
        }
        
        // Count lines
        const lines_count = countLines(final_content);
        
        return FormatResult{
            .formatted_content = final_content,
            .type_indicator = null, // Text messages don't need type indicators per PRD
            .message_type = try context.allocator.dupe(u8, "text"),
            .color_used = color,
            .lines_count = lines_count,
        };
    }
};

/// Tool message formatter - shows tool name and parameters clearly
pub const ToolFormatter = struct {
    base: MessageFormatter,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .base = MessageFormatter{ .format_fn = formatImpl },
        };
    }
    
    fn formatImpl(base: *MessageFormatter, context: *FormatContext, extraction_result: ExtractionResult) FormatError!FormatResult {
        _ = base;
        
        const message_type = extraction_result.original_type orelse "tool";
        
        // Get color for this tool type
        const color = try context.color_manager.getColorForType(message_type);
        
        // Create type indicator
        var type_indicator: ?[]u8 = null;
        if (context.config.show_type_indicators) {
            const indicator_text = if (std.mem.eql(u8, message_type, "tool_use")) "[TOOL]" else "[RESULT]";
            if (color) |c| {
                type_indicator = try applyColorToContent(context.allocator, indicator_text, c);
            } else {
                type_indicator = try context.allocator.dupe(u8, indicator_text);
            }
        }
        errdefer if (type_indicator) |ind| context.allocator.free(ind);
        
        // Render escape sequences in content
        const rendered_content = try context.escape_renderer.renderEscapeSequences(extraction_result.content);
        errdefer context.allocator.free(rendered_content);
        
        // Format the complete message
        var formatted_parts = ArrayList([]const u8).init(context.allocator);
        defer formatted_parts.deinit();
        
        if (type_indicator) |indicator| {
            try formatted_parts.append(indicator);
            try formatted_parts.append(" ");
        }
        
        // Apply line wrapping if configured
        const wrapped_content = if (context.config.max_line_width > 0) 
            try wrapContent(context.allocator, rendered_content, context.config.max_line_width, context.config.continuation_indent)
        else 
            try context.allocator.dupe(u8, rendered_content);
        
        try formatted_parts.append(wrapped_content);
        
        const final_content = try std.mem.join(context.allocator, "", formatted_parts.items);
        
        // Clean up intermediate allocations
        context.allocator.free(rendered_content);
        context.allocator.free(wrapped_content);
        
        return FormatResult{
            .formatted_content = final_content,
            .type_indicator = type_indicator,
            .message_type = try context.allocator.dupe(u8, message_type),
            .color_used = color,
            .lines_count = countLines(final_content),
        };
    }
};

/// Error message formatter - prominent red formatting
pub const ErrorFormatter = struct {
    base: MessageFormatter,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .base = MessageFormatter{ .format_fn = formatImpl },
        };
    }
    
    fn formatImpl(base: *MessageFormatter, context: *FormatContext, extraction_result: ExtractionResult) FormatError!FormatResult {
        _ = base;
        
        // Always use red for errors (reserved color) but register with ColorManager for stats
        _ = try context.color_manager.getColorForType("error"); // Register for stats
        const error_color = Color{ .code = 31, .name = "red" };
        
        // Create error type indicator
        var type_indicator: ?[]u8 = null;
        if (context.config.show_type_indicators) {
            type_indicator = try applyColorToContent(context.allocator, "[ERROR]", error_color);
        }
        errdefer if (type_indicator) |ind| context.allocator.free(ind);
        
        // Render escape sequences
        const rendered_content = try context.escape_renderer.renderEscapeSequences(extraction_result.content);
        errdefer context.allocator.free(rendered_content);
        
        // Apply error coloring to content as well
        const colored_content = try applyColorToContent(context.allocator, rendered_content, error_color);
        context.allocator.free(rendered_content);
        
        // Format with error indicator
        var formatted_parts = ArrayList([]const u8).init(context.allocator);
        defer formatted_parts.deinit();
        
        if (type_indicator) |indicator| {
            try formatted_parts.append(indicator);
            try formatted_parts.append(" ");
        }
        try formatted_parts.append(colored_content);
        
        const final_content = try std.mem.join(context.allocator, "", formatted_parts.items);
        context.allocator.free(colored_content);
        
        return FormatResult{
            .formatted_content = final_content,
            .type_indicator = type_indicator,
            .message_type = try context.allocator.dupe(u8, "error"),
            .color_used = error_color,
            .lines_count = countLines(final_content),
        };
    }
};

/// Status message formatter - dimmed appearance
pub const StatusFormatter = struct {
    base: MessageFormatter,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .base = MessageFormatter{ .format_fn = formatImpl },
        };
    }
    
    fn formatImpl(base: *MessageFormatter, context: *FormatContext, extraction_result: ExtractionResult) FormatError!FormatResult {
        _ = base;
        
        // Get color from ColorManager, but default to gray for status messages
        const status_color = (try context.color_manager.getColorForType("status")) orelse Color{ .code = 90, .name = "gray" };
        
        // Render escape sequences
        const rendered_content = try context.escape_renderer.renderEscapeSequences(extraction_result.content);
        errdefer context.allocator.free(rendered_content);
        
        // Apply status coloring
        const colored_content = try applyColorToContent(context.allocator, rendered_content, status_color);
        context.allocator.free(rendered_content);
        
        return FormatResult{
            .formatted_content = colored_content,
            .type_indicator = null, // Status messages are minimal
            .message_type = try context.allocator.dupe(u8, "status"),
            .color_used = status_color,
            .lines_count = countLines(colored_content),
        };
    }
};

/// JSON formatter - pretty prints JSON content with syntax highlighting
pub const JsonFormatter = struct {
    base: MessageFormatter,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .base = MessageFormatter{ .format_fn = formatImpl },
        };
    }
    
    fn formatImpl(base: *MessageFormatter, context: *FormatContext, extraction_result: ExtractionResult) FormatError!FormatResult {
        _ = base;
        
        const content = extraction_result.content;
        
        // Check if this is a tool_use object
        if (std.mem.indexOf(u8, content, "\"type\":\"tool_use\"") != null and
            std.mem.indexOf(u8, content, "\"name\":") != null) {
            // Format as tool use
            return formatToolUse(context, content);
        }
        
        // Check if this is a tool_result object
        if (std.mem.indexOf(u8, content, "\"type\":\"tool_result\"") != null or
            std.mem.indexOf(u8, content, "\"tool_use_id\":") != null) {
            // Format as tool result
            return formatToolResult(context, content);
        }
        
        // Pretty print JSON with basic indentation
        const formatted = try prettyPrintJson(context.allocator, content);
        defer context.allocator.free(formatted);
        
        // Apply JSON syntax coloring if enabled
        const colored = if (context.color_manager.isEnabled())
            try applyJsonSyntaxColoring(context.allocator, formatted)
        else
            try context.allocator.dupe(u8, formatted);
        
        return FormatResult{
            .formatted_content = colored,
            .type_indicator = null,
            .message_type = try context.allocator.dupe(u8, "json"),
            .color_used = null,
            .lines_count = countLines(colored),
        };
    }
    
    fn formatToolResult(context: *FormatContext, content: []const u8) FormatError!FormatResult {
        // Create formatted output
        var result = std.ArrayList(u8).init(context.allocator);
        errdefer result.deinit();
        
        // Get tool result color (might be different from tool_use)
        const result_color = try context.color_manager.getColorForType("tool_result");
        if (result_color) |color| {
            var buffer: [16]u8 = undefined;
            const ansi_code = color.toAnsiCode(&buffer);
            try result.appendSlice(ansi_code);
        }
        
        // Parse the JSON to extract key fields
        const parsed = std.json.parseFromSlice(std.json.Value, context.allocator, content, .{}) catch {
            // If parsing fails, just show raw content
            try result.appendSlice("\x1b[1m[TOOL RESULT]\x1b[22m\n");
            try result.appendSlice(content);
            if (result_color != null) {
                try result.appendSlice(Color.reset());
            }
            return FormatResult{
                .formatted_content = try result.toOwnedSlice(),
                .type_indicator = null,
                .message_type = try context.allocator.dupe(u8, "tool_result"),
                .color_used = result_color,
                .lines_count = countLines(result.items),
            };
        };
        defer parsed.deinit();
        
        // Add header
        try result.appendSlice("\x1b[1m[TOOL RESULT]\x1b[22m\n");
        
        // Extract and format key fields
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            
            // Show tool_use_id if present
            if (obj.get("tool_use_id")) |id_val| {
                try result.appendSlice("\x1b[1mtool_use_id\x1b[22m: ");
                switch (id_val) {
                    .string => |s| try result.writer().print("{s}\n", .{s}),
                    else => try result.appendSlice("unknown\n"),
                }
            }
            
            // Show is_error status
            if (obj.get("is_error")) |err_val| {
                try result.appendSlice("\x1b[1mis_error\x1b[22m: ");
                switch (err_val) {
                    .bool => |b| try result.writer().print("{}\n", .{b}),
                    else => try result.appendSlice("unknown\n"),
                }
            }
            
            // Show content - this is the main output
            if (obj.get("content")) |content_val| {
                try result.appendSlice("\x1b[1mcontent\x1b[22m:\n");
                switch (content_val) {
                    .string => |s| {
                        // Indent each line of the content
                        var lines = std.mem.tokenizeScalar(u8, s, '\n');
                        while (lines.next()) |line| {
                            try result.appendSlice("  ");
                            try result.appendSlice(line);
                            try result.append('\n');
                        }
                    },
                    .object => {
                        // Format as nested object
                        var json_str = std.ArrayList(u8).init(context.allocator);
                        defer json_str.deinit();
                        try std.json.stringify(content_val, .{}, json_str.writer());
                        const clean = try jsonToCleanFormat(context.allocator, json_str.items, 1);
                        defer context.allocator.free(clean);
                        try result.appendSlice(clean);
                    },
                    else => {
                        try result.appendSlice("  ");
                        try formatJsonValue(&result, content_val, 1);
                        try result.append('\n');
                    },
                }
            }
        }
        
        // Reset color at the end
        if (result_color != null) {
            try result.appendSlice(Color.reset());
        }
        
        return FormatResult{
            .formatted_content = try result.toOwnedSlice(),
            .type_indicator = null,
            .message_type = try context.allocator.dupe(u8, "tool_result"),
            .color_used = result_color,
            .lines_count = countLines(result.items),
        };
    }
    
    fn formatToolUse(context: *FormatContext, content: []const u8) FormatError!FormatResult {
        // Parse to extract tool name and create clean output
        var tool_name: []const u8 = "unknown";
        if (std.mem.indexOf(u8, content, "\"name\":\"")) |name_pos| {
            const start = name_pos + 8;
            if (std.mem.indexOf(u8, content[start..], "\"")) |end_pos| {
                tool_name = content[start..start + end_pos];
            }
        }
        
        // Create formatted output
        var result = std.ArrayList(u8).init(context.allocator);
        errdefer result.deinit();
        
        // Get tool color and apply to entire content
        const tool_color = try context.color_manager.getColorForType("tool_use");
        if (tool_color) |color| {
            var buffer: [16]u8 = undefined;
            const ansi_code = color.toAnsiCode(&buffer);
            try result.appendSlice(ansi_code);
        }
        
        // Add tool indicator with bold
        try result.appendSlice("\x1b[1m"); // Bold
        try result.writer().print("[TOOL: {s}]", .{tool_name});
        try result.appendSlice("\x1b[22m\n"); // Reset bold only
        
        // Convert JSON to clean key: value format
        const clean_format = try jsonToCleanFormat(context.allocator, content, 0);
        defer context.allocator.free(clean_format);
        try result.appendSlice(clean_format);
        
        // Reset color at the end
        if (tool_color != null) {
            try result.appendSlice(Color.reset());
        }
        
        return FormatResult{
            .formatted_content = try result.toOwnedSlice(),
            .type_indicator = null,
            .message_type = try context.allocator.dupe(u8, "tool_use"),
            .color_used = tool_color,
            .lines_count = countLines(result.items),
        };
    }
    
    fn jsonToCleanFormat(allocator: Allocator, json_str: []const u8, indent_level: u32) ![]u8 {
        // Parse JSON and convert to clean key: value format
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        
        // Parse the JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            // If parsing fails, return the original
            return allocator.dupe(u8, json_str);
        };
        defer parsed.deinit();
        
        // Format based on type
        try formatJsonValue(&result, parsed.value, indent_level);
        
        return try result.toOwnedSlice();
    }
    
    fn formatJsonValue(result: *std.ArrayList(u8), value: std.json.Value, indent_level: u32) !void {
        switch (value) {
            .object => |obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    // Add indentation
                    for (0..indent_level * 2) |_| {
                        try result.append(' ');
                    }
                    
                    // Write key with bright/bold modifier, then reset to normal (keeping base color)
                    try result.appendSlice("\x1b[1m"); // Bold/bright
                    try result.writer().print("{s}", .{entry.key_ptr.*});
                    try result.appendSlice("\x1b[22m"); // Reset bold/bright only
                    try result.appendSlice(": ");
                    
                    // Handle the value
                    switch (entry.value_ptr.*) {
                        .string => |s| try result.writer().print("{s}\n", .{s}),
                        .integer => |i| try result.writer().print("{d}\n", .{i}),
                        .float => |f| try result.writer().print("{d}\n", .{f}),
                        .bool => |b| try result.writer().print("{}\n", .{b}),
                        .null => try result.appendSlice("null\n"),
                        .number_string => |ns| try result.writer().print("{s}\n", .{ns}),
                        .array => |arr| {
                            if (arr.items.len == 0) {
                                try result.appendSlice("[]\n");
                            } else if (arr.items.len == 1) {
                                // Single item array, inline it
                                switch (arr.items[0]) {
                                    .object => {
                                        try result.append('\n');
                                        try formatJsonValue(result, arr.items[0], indent_level + 1);
                                    },
                                    else => {
                                        try formatJsonValue(result, arr.items[0], 0);
                                    },
                                }
                            } else {
                                try result.append('\n');
                                for (arr.items, 0..) |item, i| {
                                    // Add array item marker
                                    for (0..(indent_level + 1) * 2) |_| {
                                        try result.append(' ');
                                    }
                                    // Highlight array index
                                    try result.appendSlice("\x1b[1m"); // Bold/bright
                                    try result.writer().print("[{d}]", .{i});
                                    try result.appendSlice("\x1b[22m "); // Reset bold/bright only
                                    
                                    switch (item) {
                                        .object => {
                                            try result.append('\n');
                                            try formatJsonValue(result, item, indent_level + 2);
                                        },
                                        .string => |s| try result.writer().print("{s}\n", .{s}),
                                        else => try formatJsonValue(result, item, 0),
                                    }
                                }
                            }
                        },
                        .object => {
                            try result.append('\n');
                            try formatJsonValue(result, entry.value_ptr.*, indent_level + 1);
                        },
                    }
                }
            },
            .array => |arr| {
                for (arr.items) |item| {
                    try formatJsonValue(result, item, indent_level);
                }
            },
            .string => |s| try result.appendSlice(s),
            .integer => |i| try result.writer().print("{d}", .{i}),
            .float => |f| try result.writer().print("{d}", .{f}),
            .bool => |b| try result.writer().print("{}", .{b}),
            .null => try result.appendSlice("null"),
            .number_string => |ns| try result.appendSlice(ns),
        }
    }
    
    fn prettyPrintJson(allocator: Allocator, json_str: []const u8) ![]u8 {
        // Basic pretty printing with indentation
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        
        var indent_level: u32 = 0;
        var in_string = false;
        var escape_next = false;
        
        for (json_str) |char| {
            if (escape_next) {
                try result.append(char);
                escape_next = false;
                continue;
            }
            
            if (char == '\\' and in_string) {
                escape_next = true;
                try result.append(char);
                continue;
            }
            
            if (char == '"' and !escape_next) {
                in_string = !in_string;
                try result.append(char);
                continue;
            }
            
            if (in_string) {
                try result.append(char);
                continue;
            }
            
            switch (char) {
                '{', '[' => {
                    try result.append(char);
                    indent_level += 1;
                    try result.append('\n');
                    for (0..indent_level * 2) |_| {
                        try result.append(' ');
                    }
                },
                '}', ']' => {
                    indent_level -|= 1;
                    try result.append('\n');
                    for (0..indent_level * 2) |_| {
                        try result.append(' ');
                    }
                    try result.append(char);
                },
                ',' => {
                    try result.append(char);
                    try result.append('\n');
                    for (0..indent_level * 2) |_| {
                        try result.append(' ');
                    }
                },
                ':' => {
                    try result.append(char);
                    try result.append(' ');
                },
                ' ', '\n', '\r', '\t' => {}, // Skip whitespace
                else => try result.append(char),
            }
        }
        
        return try result.toOwnedSlice();
    }
    
    fn applyJsonSyntaxColoring(allocator: Allocator, json: []const u8) ![]u8 {
        // Simple coloring: keys in cyan, strings in green, numbers in yellow
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        
        var in_key = false;
        var in_string = false;
        var in_number = false;
        var escape_next = false;
        var last_char: u8 = 0;
        
        for (json) |char| {
            if (escape_next) {
                try result.append(char);
                escape_next = false;
                last_char = char;
                continue;
            }
            
            if (char == '\\' and (in_string or in_key)) {
                escape_next = true;
                try result.append(char);
                last_char = char;
                continue;
            }
            
            // Handle strings and keys
            if (char == '"' and !escape_next) {
                if (!in_string and !in_key) {
                    // Starting a string or key
                    if (last_char == ':' or last_char == ',' or last_char == '[') {
                        // It's a value string
                        in_string = true;
                        try result.appendSlice("\x1b[32m"); // Green
                    } else {
                        // It's likely a key
                        in_key = true;
                        try result.appendSlice("\x1b[36m"); // Cyan
                    }
                } else {
                    // Ending a string or key
                    try result.append(char);
                    try result.appendSlice("\x1b[0m"); // Reset
                    in_string = false;
                    in_key = false;
                    last_char = char;
                    continue;
                }
            }
            
            // Handle numbers
            if (!in_string and !in_key and !in_number and (std.ascii.isDigit(char) or char == '-')) {
                in_number = true;
                try result.appendSlice("\x1b[33m"); // Yellow
            } else if (in_number and !std.ascii.isDigit(char) and char != '.') {
                try result.appendSlice("\x1b[0m"); // Reset
                in_number = false;
            }
            
            try result.append(char);
            if (char != ' ' and char != '\n' and char != '\t') {
                last_char = char;
            }
        }
        
        // Ensure we reset at the end
        if (in_number or in_string or in_key) {
            try result.appendSlice("\x1b[0m");
        }
        
        return try result.toOwnedSlice();
    }
};

/// Registry for managing different message formatters
pub const FormatterRegistry = struct {
    allocator: Allocator,
    formatters: HashMap([]const u8, *MessageFormatter, StringContext, std.hash_map.default_max_load_percentage),
    default_formatter: *MessageFormatter,
    // Track allocated formatter instances for cleanup
    text_formatter: ?*TextFormatter = null,
    tool_formatter: ?*ToolFormatter = null,
    error_formatter: ?*ErrorFormatter = null,
    status_formatter: ?*StatusFormatter = null,
    json_formatter: ?*JsonFormatter = null,
    
    const Self = @This();
    const StringContext = struct {
        pub fn hash(self: @This(), s: []const u8) u64 {
            _ = self;
            return std.hash_map.hashString(s);
        }
        pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
            _ = self;
            return std.mem.eql(u8, a, b);
        }
    };
    
    pub fn init(allocator: Allocator) !Self {
        // Create formatters first
        const text_formatter = try allocator.create(TextFormatter);
        text_formatter.* = TextFormatter.init();
        
        const tool_formatter = try allocator.create(ToolFormatter);
        tool_formatter.* = ToolFormatter.init();
        
        const error_formatter = try allocator.create(ErrorFormatter);
        error_formatter.* = ErrorFormatter.init();
        
        const status_formatter = try allocator.create(StatusFormatter);
        status_formatter.* = StatusFormatter.init();
        
        const json_formatter = try allocator.create(JsonFormatter);
        json_formatter.* = JsonFormatter.init();
        
        var registry = Self{
            .allocator = allocator,
            .formatters = HashMap([]const u8, *MessageFormatter, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .default_formatter = &text_formatter.base,
            .text_formatter = text_formatter,
            .tool_formatter = tool_formatter,
            .error_formatter = error_formatter,
            .status_formatter = status_formatter,
            .json_formatter = json_formatter,
        };
        
        // Register built-in formatters
        try registry.registerFormatter("text", &text_formatter.base);
        try registry.registerFormatter("tool_use", &tool_formatter.base);
        try registry.registerFormatter("tool_result", &tool_formatter.base);
        try registry.registerFormatter("error", &error_formatter.base);
        try registry.registerFormatter("status", &status_formatter.base);
        try registry.registerFormatter("thinking", &status_formatter.base);
        try registry.registerFormatter("json", &json_formatter.base);
        try registry.registerFormatter("assistant", &json_formatter.base); // Use JSON formatter for assistant messages with arrays
        
        return registry;
    }
    
    pub fn deinit(self: *Self) void {
        // Free all allocated message type strings
        var iter = self.formatters.iterator();
        while (iter.next()) |entry| {
            // Free the duplicated message type string
            self.allocator.free(entry.key_ptr.*);
        }
        
        // Free formatter instances
        if (self.text_formatter) |formatter| {
            self.allocator.destroy(formatter);
        }
        if (self.tool_formatter) |formatter| {
            self.allocator.destroy(formatter);
        }
        if (self.error_formatter) |formatter| {
            self.allocator.destroy(formatter);
        }
        if (self.status_formatter) |formatter| {
            self.allocator.destroy(formatter);
        }
        if (self.json_formatter) |formatter| {
            self.allocator.destroy(formatter);
        }
        
        self.formatters.deinit();
    }
    
    /// Register a formatter for a specific message type
    pub fn registerFormatter(self: *Self, message_type: []const u8, formatter: *MessageFormatter) !void {
        const owned_type = try self.allocator.dupe(u8, message_type);
        try self.formatters.put(owned_type, formatter);
    }
    
    /// Get formatter for a message type
    pub fn getFormatter(self: *Self, message_type: []const u8) *MessageFormatter {
        return self.formatters.get(message_type) orelse self.default_formatter;
    }
    
    /// Format a message using the appropriate formatter
    pub fn formatMessage(self: *Self, context: *FormatContext, message_type: []const u8, extraction_result: ExtractionResult) !FormatResult {
        const formatter = self.getFormatter(message_type);
        return formatter.format(context, extraction_result);
    }
};

// =====================================
// UTILITY FUNCTIONS
// =====================================

/// Apply color to content using ANSI escape sequences
fn applyColorToContent(allocator: Allocator, content: []const u8, color: Color) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    
    var buffer: [16]u8 = undefined;
    const ansi_code = color.toAnsiCode(&buffer);
    try result.appendSlice(ansi_code);
    try result.appendSlice(content);
    try result.appendSlice(Color.reset());
    
    return try result.toOwnedSlice();
}

/// Count number of lines in content
fn countLines(content: []const u8) u32 {
    var count: u32 = 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

/// Wrap content to specified width with continuation indentation
fn wrapContent(allocator: Allocator, content: []const u8, max_width: usize, indent: u8) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    
    var current_line_len: usize = 0;
    var word_start: usize = 0;
    var i: usize = 0;
    
    while (i < content.len) {
        if (content[i] == ' ' or content[i] == '\n' or i == content.len - 1) {
            // Found word boundary
            const word_end = if (i == content.len - 1 and content[i] != ' ' and content[i] != '\n') i + 1 else i;
            const word = content[word_start..word_end];
            
            if (current_line_len + word.len > max_width and current_line_len > 0) {
                // Need to wrap
                try result.append('\n');
                for (0..indent) |_| {
                    try result.append(' ');
                }
                current_line_len = indent;
            }
            
            try result.appendSlice(word);
            current_line_len += word.len;
            
            if (content[i] == '\n') {
                try result.append('\n');
                current_line_len = 0;
            } else if (content[i] == ' ' and i < content.len - 1) {
                try result.append(' ');
                current_line_len += 1;
            }
            
            word_start = i + 1;
        }
        i += 1;
    }
    
    return try result.toOwnedSlice();
}

// =====================================
// TESTS (TDD - Comprehensive test coverage)
// =====================================

test "TextFormatter formats simple text message" {
    const allocator = testing.allocator;
    var color_manager = try ColorManager.init(allocator);
    defer color_manager.deinit();
    color_manager.setEnabled(true);
    
    const escape_config = @import("escape_renderer.zig").EscapeRenderConfig{};
    var escape_renderer = @import("escape_renderer.zig").EscapeRenderer.init(allocator, escape_config);
    
    var context = FormatContext{
        .allocator = allocator,
        .color_manager = &color_manager,
        .escape_renderer = &escape_renderer,
        .config = FormatConfig{},
    };
    
    var text_formatter = TextFormatter.init();
    
    const extraction_result = ExtractionResult{
        .content = "Hello, World!",
        .content_type = .text,
        .fallback_used = false,
        .original_type = null,
    };
    
    var result = try text_formatter.base.format(&context, extraction_result);
    defer result.deinit(allocator);
    
    try testing.expect(std.mem.indexOf(u8, result.formatted_content, "Hello, World!") != null);
    try testing.expectEqualStrings("text", result.message_type);
    try testing.expectEqual(result.type_indicator, null); // Text messages don't have type indicators
}

test "TextFormatter handles escape sequences" {
    const allocator = testing.allocator;
    var color_manager = try ColorManager.init(allocator);
    defer color_manager.deinit();
    color_manager.setEnabled(false); // Disable colors for easier testing
    
    const escape_config = @import("escape_renderer.zig").EscapeRenderConfig{};
    var escape_renderer = @import("escape_renderer.zig").EscapeRenderer.init(allocator, escape_config);
    
    var context = FormatContext{
        .allocator = allocator,
        .color_manager = &color_manager,
        .escape_renderer = &escape_renderer,
        .config = FormatConfig{},
    };
    
    var text_formatter = TextFormatter.init();
    
    const extraction_result = ExtractionResult{
        .content = "Line 1\\nLine 2\\tTabbed",
        .content_type = .text,
        .fallback_used = false,
        .original_type = null,
    };
    
    var result = try text_formatter.base.format(&context, extraction_result);
    defer result.deinit(allocator);
    
    try testing.expect(std.mem.indexOf(u8, result.formatted_content, "Line 1\nLine 2\tTabbed") != null);
    try testing.expectEqual(@as(u32, 2), result.lines_count);
}

test "ToolFormatter creates type indicator" {
    const allocator = testing.allocator;
    var color_manager = try ColorManager.init(allocator);
    defer color_manager.deinit();
    color_manager.setEnabled(false);
    
    const escape_config = @import("escape_renderer.zig").EscapeRenderConfig{};
    var escape_renderer = @import("escape_renderer.zig").EscapeRenderer.init(allocator, escape_config);
    
    var context = FormatContext{
        .allocator = allocator,
        .color_manager = &color_manager,
        .escape_renderer = &escape_renderer,
        .config = FormatConfig{ .show_type_indicators = true },
    };
    
    var tool_formatter = ToolFormatter.init();
    
    const extraction_result = ExtractionResult{
        .content = "File read successfully",
        .content_type = .text,
        .fallback_used = false,
        .original_type = try allocator.dupe(u8, "tool_use"),
    };
    defer allocator.free(extraction_result.original_type.?);
    
    var result = try tool_formatter.base.format(&context, extraction_result);
    defer result.deinit(allocator);
    
    try testing.expect(result.type_indicator != null);
    try testing.expect(std.mem.indexOf(u8, result.type_indicator.?, "[TOOL]") != null);
    try testing.expect(std.mem.indexOf(u8, result.formatted_content, "File read successfully") != null);
}

test "ErrorFormatter uses red color and ERROR indicator" {
    const allocator = testing.allocator;
    var color_manager = try ColorManager.init(allocator);
    defer color_manager.deinit();
    color_manager.setEnabled(true);
    
    const escape_config = @import("escape_renderer.zig").EscapeRenderConfig{};
    var escape_renderer = @import("escape_renderer.zig").EscapeRenderer.init(allocator, escape_config);
    
    var context = FormatContext{
        .allocator = allocator,
        .color_manager = &color_manager,
        .escape_renderer = &escape_renderer,
        .config = FormatConfig{ .show_type_indicators = true },
    };
    
    var error_formatter = ErrorFormatter.init();
    
    const extraction_result = ExtractionResult{
        .content = "File not found",
        .content_type = .text,
        .fallback_used = false,
        .original_type = try allocator.dupe(u8, "error"),
    };
    defer allocator.free(extraction_result.original_type.?);
    
    var result = try error_formatter.base.format(&context, extraction_result);
    defer result.deinit(allocator);
    
    try testing.expect(result.type_indicator != null);
    try testing.expect(std.mem.indexOf(u8, result.type_indicator.?, "[ERROR]") != null);
    try testing.expect(result.color_used != null);
    try testing.expectEqual(@as(u8, 31), result.color_used.?.code); // Red color
    try testing.expectEqualStrings("error", result.message_type);
}

test "StatusFormatter creates dimmed output" {
    const allocator = testing.allocator;
    var color_manager = try ColorManager.init(allocator);
    defer color_manager.deinit();
    color_manager.setEnabled(true);
    
    const escape_config = @import("escape_renderer.zig").EscapeRenderConfig{};
    var escape_renderer = @import("escape_renderer.zig").EscapeRenderer.init(allocator, escape_config);
    
    var context = FormatContext{
        .allocator = allocator,
        .color_manager = &color_manager,
        .escape_renderer = &escape_renderer,
        .config = FormatConfig{},
    };
    
    var status_formatter = StatusFormatter.init();
    
    const extraction_result = ExtractionResult{
        .content = "Processing...",
        .content_type = .text,
        .fallback_used = false,
        .original_type = try allocator.dupe(u8, "status"),
    };
    defer allocator.free(extraction_result.original_type.?);
    
    var result = try status_formatter.base.format(&context, extraction_result);
    defer result.deinit(allocator);
    
    try testing.expectEqual(result.type_indicator, null); // Status messages are minimal
    try testing.expect(result.color_used != null);
    try testing.expectEqual(@as(u8, 90), result.color_used.?.code); // Gray color
    try testing.expectEqualStrings("status", result.message_type);
}

test "FormatterRegistry.init creates registry with built-in formatters" {
    var registry = try FormatterRegistry.init(testing.allocator);
    defer registry.deinit();
    
    // Test that built-in formatters are registered
    const text_formatter = registry.getFormatter("text");
    const tool_formatter = registry.getFormatter("tool_use");
    const error_formatter = registry.getFormatter("error");
    const status_formatter = registry.getFormatter("status");
    
    try testing.expect(text_formatter != null);
    try testing.expect(tool_formatter != null);
    try testing.expect(error_formatter != null);
    try testing.expect(status_formatter != null);
}

test "FormatterRegistry returns default formatter for unknown types" {
    var registry = try FormatterRegistry.init(testing.allocator);
    defer registry.deinit();
    
    const unknown_formatter = registry.getFormatter("unknown_type");
    const default_formatter = registry.default_formatter;
    
    try testing.expectEqual(default_formatter, unknown_formatter);
}

test "FormatterRegistry.formatMessage routes to correct formatter" {
    const allocator = testing.allocator;
    var registry = try FormatterRegistry.init(allocator);
    defer registry.deinit();
    
    var color_manager = try ColorManager.init(allocator);
    defer color_manager.deinit();
    color_manager.setEnabled(false);
    
    const escape_config = @import("escape_renderer.zig").EscapeRenderConfig{};
    var escape_renderer = @import("escape_renderer.zig").EscapeRenderer.init(allocator, escape_config);
    
    var context = FormatContext{
        .allocator = allocator,
        .color_manager = &color_manager,
        .escape_renderer = &escape_renderer,
        .config = FormatConfig{},
    };
    
    const extraction_result = ExtractionResult{
        .content = "Test message",
        .content_type = .text,
        .fallback_used = false,
        .original_type = null,
    };
    
    // Test text formatting
    var text_result = try registry.formatMessage(&context, "text", extraction_result);
    defer text_result.deinit(allocator);
    try testing.expectEqualStrings("text", text_result.message_type);
    
    // Test error formatting (should use error formatter)
    var error_result = try registry.formatMessage(&context, "error", extraction_result);
    defer error_result.deinit(allocator);
    try testing.expectEqualStrings("error", error_result.message_type);
}

test "applyColorToContent creates ANSI colored string" {
    const content = "Test content";
    const color = Color{ .code = 32, .name = "green" };
    
    const colored = try applyColorToContent(testing.allocator, content, color);
    defer testing.allocator.free(colored);
    
    try testing.expect(std.mem.startsWith(u8, colored, "\x1b[32m"));
    try testing.expect(std.mem.endsWith(u8, colored, "\x1b[0m"));
    try testing.expect(std.mem.indexOf(u8, colored, content) != null);
}

test "countLines counts newlines correctly" {
    try testing.expectEqual(@as(u32, 1), countLines("Single line"));
    try testing.expectEqual(@as(u32, 2), countLines("Two\nlines"));
    try testing.expectEqual(@as(u32, 3), countLines("Three\nlines\nhere"));
    try testing.expectEqual(@as(u32, 2), countLines("Trailing\n"));
}

test "wrapContent wraps text at specified width" {
    const content = "This is a very long line that should be wrapped at the specified width";
    const wrapped = try wrapContent(testing.allocator, content, 20, 4);
    defer testing.allocator.free(wrapped);
    
    // Should contain newlines for wrapping
    try testing.expect(std.mem.indexOf(u8, wrapped, "\n") != null);
    
    // Should contain indentation after newlines
    try testing.expect(std.mem.indexOf(u8, wrapped, "\n    ") != null);
}

test "wrapContent preserves existing newlines" {
    const content = "Line 1\nLine 2 that is longer than the wrap width\nLine 3";
    const wrapped = try wrapContent(testing.allocator, content, 15, 2);
    defer testing.allocator.free(wrapped);
    
    // Should preserve the original newlines and add new ones for wrapping
    const newline_count = std.mem.count(u8, wrapped, "\n");
    try testing.expect(newline_count >= 2); // At least the original newlines
}

test "formatter memory management with multiple formats" {
    const allocator = testing.allocator;
    var registry = try FormatterRegistry.init(allocator);
    defer registry.deinit();
    
    var color_manager = try ColorManager.init(allocator);
    defer color_manager.deinit();
    color_manager.setEnabled(false);
    
    const escape_config = @import("escape_renderer.zig").EscapeRenderConfig{};
    var escape_renderer = @import("escape_renderer.zig").EscapeRenderer.init(allocator, escape_config);
    
    var context = FormatContext{
        .allocator = allocator,
        .color_manager = &color_manager,
        .escape_renderer = &escape_renderer,
        .config = FormatConfig{},
    };
    
    // Create multiple format results
    var results = ArrayList(FormatResult).init(allocator);
    defer {
        for (results.items) |*result| {
            result.deinit(allocator);
        }
        results.deinit();
    }
    
    const message_types = [_][]const u8{ "text", "tool_use", "error", "status" };
    
    for (message_types) |message_type| {
        const extraction_result = ExtractionResult{
            .content = "Test content",
            .content_type = .text,
            .fallback_used = false,
            .original_type = null,
        };
        
        const result = try registry.formatMessage(&context, message_type, extraction_result);
        try results.append(result);
    }
    
    try testing.expectEqual(@as(usize, 4), results.items.len);
    
    // Verify all results have content
    for (results.items) |result| {
        try testing.expect(result.formatted_content.len > 0);
        try testing.expect(result.message_type.len > 0);
    }
}