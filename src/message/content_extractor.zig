//! Message Content Extractor for CC Streamer v2
//!
//! This module extracts meaningful content from Claude Code JSON messages.
//! It implements the content-focused display strategy from PRD v2:
//! - Extract `message.content` field as primary content
//! - Implement intelligent fallback strategies for missing fields
//! - Handle different content types (string, array, object)
//! - Preserve formatting while focusing on readability

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const json = std.json;

/// Errors that can occur during content extraction
pub const ContentExtractionError = error{
    InvalidJson,
    MissingContent,
    UnsupportedContentType,
    OutOfMemory,
} || json.ParseError(json.Scanner);

/// Configuration for content extraction behavior
pub const ContentExtractionConfig = struct {
    /// Maximum content length before truncation (0 = no limit)
    max_content_length: usize = 0,
    /// Whether to include metadata when content is missing
    include_metadata_fallback: bool = true,
    /// Whether to pretty-format JSON objects as content
    pretty_format_objects: bool = true,
    /// Indentation for pretty-formatted JSON
    indent_spaces: u8 = 2,
};

/// Result of content extraction operation
pub const ExtractionResult = struct {
    content: []const u8,
    content_type: ContentType,
    fallback_used: bool,
    original_type: ?[]const u8,

    /// Types of extracted content
    pub const ContentType = enum {
        text,           // String content
        json_object,    // Formatted JSON object
        json_array,     // Formatted JSON array  
        metadata,       // Fallback metadata content
        empty,          // No content found
    };

    pub fn deinit(self: *ExtractionResult, allocator: Allocator) void {
        allocator.free(self.content);
        if (self.original_type) |typ| {
            allocator.free(typ);
        }
    }
};

/// Extracts content from Claude Code JSON messages
pub const ContentExtractor = struct {
    allocator: Allocator,
    config: ContentExtractionConfig,

    const Self = @This();

    pub fn init(allocator: Allocator, config: ContentExtractionConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Extract content from JSON string
    pub fn extractFromJsonString(self: *Self, json_str: []const u8) !ExtractionResult {
        // Parse JSON
        var parsed = json.parseFromSlice(json.Value, self.allocator, json_str, .{}) catch |err| {
            return switch (err) {
                error.SyntaxError, error.UnexpectedToken, error.InvalidNumber => ContentExtractionError.InvalidJson,
                else => err,
            };
        };
        defer parsed.deinit();

        return self.extractFromJsonValue(parsed.value);
    }

    /// Extract content from parsed JSON value
    pub fn extractFromJsonValue(self: *Self, json_value: json.Value) !ExtractionResult {
        switch (json_value) {
            .object => |obj| {
                // Try to extract message.content first
                if (self.extractMessageContent(obj)) |result| {
                    return result;
                } else |_| {
                    // Try fallback strategies
                    return self.extractWithFallback(obj);
                }
            },
            .array => {
                // For arrays, try to extract from first object
                if (json_value.array.items.len > 0) {
                    return self.extractFromJsonValue(json_value.array.items[0]);
                }
                return self.createEmptyResult();
            },
            .string => |str| {
                return self.createTextResult(str, false);
            },
            else => {
                return self.createEmptyResult();
            }
        }
    }

    /// Extract message.content field from JSON object
    fn extractMessageContent(self: *Self, obj: json.ObjectMap) !ExtractionResult {
        // Look for message field
        const message_value = obj.get("message") orelse return ContentExtractionError.MissingContent;
        
        switch (message_value) {
            .object => |message_obj| {
                // Extract content field from message object
                const content_value = message_obj.get("content") orelse return ContentExtractionError.MissingContent;
                return self.extractContentValue(content_value, obj);
            },
            .string => |content_str| {
                // Direct string content
                return self.createTextResult(content_str, false);
            },
            else => return ContentExtractionError.UnsupportedContentType,
        }
    }

    /// Extract content from a content value (handles different types)
    fn extractContentValue(self: *Self, content_value: json.Value, original_obj: json.ObjectMap) !ExtractionResult {
        switch (content_value) {
            .string => |str| {
                var result = try self.createTextResult(str, false);
                result.original_type = try self.extractOriginalType(original_obj);
                return result;
            },
            .array => |arr| {
                // Join array elements with newlines
                var content_parts = ArrayList([]const u8).init(self.allocator);
                defer content_parts.deinit();
                
                // Track allocated strings that need to be freed
                var allocated_strings = ArrayList([]const u8).init(self.allocator);
                defer {
                    for (allocated_strings.items) |str| {
                        self.allocator.free(str);
                    }
                    allocated_strings.deinit();
                }

                for (arr.items) |item| {
                    switch (item) {
                        .string => |str| try content_parts.append(str),
                        else => {
                            // Convert non-string array items to JSON
                            const json_str = try self.valueToJsonString(item);
                            try allocated_strings.append(json_str);
                            try content_parts.append(json_str);
                        }
                    }
                }

                const joined = try std.mem.join(self.allocator, "\n", content_parts.items);
                return ExtractionResult{
                    .content = joined,
                    .content_type = .json_array,
                    .fallback_used = false,
                    .original_type = try self.extractOriginalType(original_obj),
                };
            },
            .object => {
                // Pretty-format the object
                const formatted = try self.formatJsonObject(content_value);
                return ExtractionResult{
                    .content = formatted,
                    .content_type = .json_object,
                    .fallback_used = false,
                    .original_type = try self.extractOriginalType(original_obj),
                };
            },
            else => {
                // Convert other types to string
                const str = try self.valueToString(content_value);
                var result = try self.createTextResult(str, false);
                result.original_type = try self.extractOriginalType(original_obj);
                return result;
            }
        }
    }

    /// Implement fallback strategies when message.content is not found
    fn extractWithFallback(self: *Self, obj: json.ObjectMap) !ExtractionResult {
        if (!self.config.include_metadata_fallback) {
            return self.createEmptyResult();
        }

        // Strategy 1: Look for other common content fields
        const fallback_fields = [_][]const u8{ "text", "data", "body", "value", "result" };
        for (fallback_fields) |field| {
            if (obj.get(field)) |value| {
                switch (value) {
                    .string => |str| {
                        var result = try self.createTextResult(str, true);
                        result.original_type = try self.extractOriginalType(obj);
                        return result;
                    },
                    .integer, .float, .bool => {
                        const str = try self.valueToString(value);
                        defer self.allocator.free(str);
                        var result = try self.createTextResult(str, true);
                        result.original_type = try self.extractOriginalType(obj);
                        return result;
                    },
                    .object, .array => {
                        const formatted = try self.valueToJsonString(value);
                        defer self.allocator.free(formatted);
                        var result = try self.createTextResult(formatted, true);
                        result.original_type = try self.extractOriginalType(obj);
                        return result;
                    },
                    else => {}
                }
            }
        }

        // Strategy 2: Create metadata summary
        return self.createMetadataResult(obj);
    }

    /// Create a metadata summary as fallback content
    fn createMetadataResult(self: *Self, obj: json.ObjectMap) !ExtractionResult {
        var metadata_parts = ArrayList([]const u8).init(self.allocator);
        defer metadata_parts.deinit();

        // Include type if present
        if (obj.get("type")) |type_value| {
            switch (type_value) {
                .string => |type_str| {
                    const type_info = try std.fmt.allocPrint(self.allocator, "[{s}]", .{type_str});
                    try metadata_parts.append(type_info);
                },
                else => {}
            }
        }

        // Include timestamp if present  
        if (obj.get("timestamp")) |ts_value| {
            switch (ts_value) {
                .string => |ts_str| {
                    const ts_info = try std.fmt.allocPrint(self.allocator, "at {s}", .{ts_str});
                    try metadata_parts.append(ts_info);
                },
                else => {}
            }
        }

        // If no useful metadata, show field count
        if (metadata_parts.items.len == 0) {
            const field_info = try std.fmt.allocPrint(self.allocator, "[{d} fields]", .{obj.count()});
            try metadata_parts.append(field_info);
        }

        const metadata = try std.mem.join(self.allocator, " ", metadata_parts.items);
        
        // Clean up individual parts
        for (metadata_parts.items) |part| {
            self.allocator.free(part);
        }

        return ExtractionResult{
            .content = metadata,
            .content_type = .metadata,
            .fallback_used = true,
            .original_type = try self.extractOriginalType(obj),
        };
    }

    /// Create text result
    fn createTextResult(self: *Self, text: []const u8, fallback: bool) !ExtractionResult {
        const content = try self.processTextContent(text);
        return ExtractionResult{
            .content = content,
            .content_type = .text,
            .fallback_used = fallback,
            .original_type = null, // Will be set by caller if needed
        };
    }

    /// Create empty result
    fn createEmptyResult(self: *Self) ExtractionResult {
        _ = self;
        return ExtractionResult{
            .content = "",
            .content_type = .empty,
            .fallback_used = true,
            .original_type = null,
        };
    }

    /// Process text content (handle length limits, etc.)
    fn processTextContent(self: *Self, text: []const u8) ![]const u8 {
        if (self.config.max_content_length > 0 and text.len > self.config.max_content_length) {
            // Truncate with ellipsis
            const truncated = try self.allocator.alloc(u8, self.config.max_content_length + 3);
            @memcpy(truncated[0..self.config.max_content_length], text[0..self.config.max_content_length]);
            @memcpy(truncated[self.config.max_content_length..], "...");
            return truncated;
        }
        return try self.allocator.dupe(u8, text);
    }

    /// Extract original message type for context
    fn extractOriginalType(self: *Self, obj: json.ObjectMap) !?[]const u8 {
        if (obj.get("type")) |type_value| {
            switch (type_value) {
                .string => |type_str| return try self.allocator.dupe(u8, type_str),
                else => return null,
            }
        }
        return null;
    }

    /// Convert JSON value to formatted string
    fn valueToJsonString(self: *Self, value: json.Value) ![]const u8 {
        var string = std.ArrayList(u8).init(self.allocator);
        errdefer string.deinit();

        try json.stringify(value, .{}, string.writer());
        return try string.toOwnedSlice();
    }

    /// Convert JSON value to simple string representation
    fn valueToString(self: *Self, value: json.Value) ![]const u8 {
        switch (value) {
            .string => |str| return try self.allocator.dupe(u8, str),
            .integer => |int| return try std.fmt.allocPrint(self.allocator, "{d}", .{int}),
            .float => |float| return try std.fmt.allocPrint(self.allocator, "{d}", .{float}),
            .bool => |b| return try self.allocator.dupe(u8, if (b) "true" else "false"),
            .null => return try self.allocator.dupe(u8, "null"),
            else => return self.valueToJsonString(value),
        }
    }

    /// Format JSON object for display
    fn formatJsonObject(self: *Self, value: json.Value) ![]const u8 {
        if (!self.config.pretty_format_objects) {
            return self.valueToJsonString(value);
        }

        var string = std.ArrayList(u8).init(self.allocator);
        errdefer string.deinit();

        const options = json.StringifyOptions{
            .whitespace = .indent_tab,
        };
        
        try json.stringify(value, options, string.writer());
        return try string.toOwnedSlice();
    }
};

// =====================================
// TESTS (TDD - Comprehensive test coverage)
// =====================================

test "ContentExtractor.init creates extractor with config" {
    const config = ContentExtractionConfig{};
    const extractor = ContentExtractor.init(testing.allocator, config);
    
    try testing.expectEqual(config.max_content_length, extractor.config.max_content_length);
    try testing.expect(extractor.config.include_metadata_fallback);
}

test "ContentExtractor.extractFromJsonString handles valid Claude Code message" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"text","message":{"content":"Hello, I'll help you with that task.\nLet me check the files."},"timestamp":"2024-01-01T00:00:00Z"}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqualStrings("Hello, I'll help you with that task.\nLet me check the files.", result.content);
    try testing.expectEqual(ExtractionResult.ContentType.text, result.content_type);
    try testing.expect(!result.fallback_used);
    try testing.expectEqualStrings("text", result.original_type.?);
}

test "ContentExtractor.extractFromJsonString handles missing message field" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"error","error":"Something went wrong","timestamp":"2024-01-01T00:00:00Z"}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqual(ExtractionResult.ContentType.metadata, result.content_type);
    try testing.expect(result.fallback_used);
    try testing.expect(std.mem.indexOf(u8, result.content, "[error]") != null);
}

test "ContentExtractor.extractFromJsonString handles direct string message" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"status","message":"Process completed successfully"}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqualStrings("Process completed successfully", result.content);
    try testing.expectEqual(ExtractionResult.ContentType.text, result.content_type);
    try testing.expect(!result.fallback_used);
}

test "ContentExtractor.extractFromJsonString handles array content" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"list","message":{"content":["Item 1","Item 2","Item 3"]}}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqualStrings("Item 1\nItem 2\nItem 3", result.content);
    try testing.expectEqual(ExtractionResult.ContentType.json_array, result.content_type);
}

test "ContentExtractor.extractFromJsonString handles object content" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"data","message":{"content":{"key":"value","number":42}}}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqual(ExtractionResult.ContentType.json_object, result.content_type);
    try testing.expect(std.mem.indexOf(u8, result.content, "key") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "value") != null);
}

test "ContentExtractor.extractFromJsonString handles malformed JSON" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = "invalid json {";
    
    const result = extractor.extractFromJsonString(json_input);
    try testing.expectError(ContentExtractionError.InvalidJson, result);
}

test "ContentExtractor.extractFromJsonString with max_content_length truncates" {
    const config = ContentExtractionConfig{ .max_content_length = 10 };
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"message":{"content":"This is a very long message that should be truncated"}}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqual(@as(usize, 13), result.content.len); // 10 chars + "..."
    try testing.expect(std.mem.endsWith(u8, result.content, "..."));
}

test "ContentExtractor.extractFromJsonString with fallback disabled returns empty" {
    const config = ContentExtractionConfig{ .include_metadata_fallback = false };
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"error","error":"Something went wrong"}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqual(ExtractionResult.ContentType.empty, result.content_type);
    try testing.expectEqualStrings("", result.content);
}

test "ContentExtractor.extractFromJsonString handles nested message structure" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"tool_result","message":{"content":{"result":"Success","details":"Operation completed"}}}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqual(ExtractionResult.ContentType.json_object, result.content_type);
    try testing.expect(std.mem.indexOf(u8, result.content, "Success") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "details") != null);
}

test "ContentExtractor handles fallback field extraction" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"custom","text":"Fallback content here"}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqualStrings("Fallback content here", result.content);
    try testing.expectEqual(ExtractionResult.ContentType.text, result.content_type);
    try testing.expect(result.fallback_used);
}

test "ContentExtractor metadata result includes type and timestamp" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_input = 
        \\{"type":"status","timestamp":"2024-01-01T12:00:00Z","data":"some data"}
    ;
    
    var result = try extractor.extractFromJsonString(json_input);
    defer result.deinit(testing.allocator);
    
    try testing.expectEqual(ExtractionResult.ContentType.metadata, result.content_type);
    try testing.expect(std.mem.indexOf(u8, result.content, "[status]") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "2024-01-01T12:00:00Z") != null);
}

test "ContentExtractor handles different JSON value types" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    // Number content
    const json_number = 
        \\{"message":{"content":42}}
    ;
    var result_num = try extractor.extractFromJsonString(json_number);
    defer result_num.deinit(testing.allocator);
    try testing.expectEqualStrings("42", result_num.content);
    
    // Boolean content
    const json_bool = 
        \\{"message":{"content":true}}
    ;
    var result_bool = try extractor.extractFromJsonString(json_bool);
    defer result_bool.deinit(testing.allocator);
    try testing.expectEqualStrings("true", result_bool.content);
    
    // Null content
    const json_null = 
        \\{"message":{"content":null}}
    ;
    var result_null = try extractor.extractFromJsonString(json_null);
    defer result_null.deinit(testing.allocator);
    try testing.expectEqualStrings("null", result_null.content);
}

test "ContentExtractor memory management with multiple extractions" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    const json_inputs = [_][]const u8{
        \\{"type":"text","message":{"content":"First message"}}\\,
        \\{"type":"tool","message":{"content":"Second message"}}\\,
        \\{"type":"error","message":{"content":"Third message"}}\\,
    };
    
    var results = ArrayList(ExtractionResult).init(testing.allocator);
    defer {
        for (results.items) |*result| {
            result.deinit(testing.allocator);
        }
        results.deinit();
    }
    
    for (json_inputs) |json_input| {
        const result = try extractor.extractFromJsonString(json_input);
        try results.append(result);
    }
    
    try testing.expectEqual(@as(usize, 3), results.items.len);
    for (results.items) |result| {
        try testing.expect(result.content.len > 0);
        try testing.expectEqual(ExtractionResult.ContentType.text, result.content_type);
    }
}

test "ContentExtractor edge cases" {
    const config = ContentExtractionConfig{};
    var extractor = ContentExtractor.init(testing.allocator, config);
    
    // Empty JSON object
    var result_empty = try extractor.extractFromJsonString("{}");
    defer result_empty.deinit(testing.allocator);
    try testing.expectEqual(ExtractionResult.ContentType.metadata, result_empty.content_type);
    
    // JSON array input
    var result_array = try extractor.extractFromJsonString("[1,2,3]");
    defer result_array.deinit(testing.allocator);
    try testing.expectEqual(ExtractionResult.ContentType.empty, result_array.content_type);
    
    // Simple string input
    var result_string = try extractor.extractFromJsonString("\"simple string\"");
    defer result_string.deinit(testing.allocator);
    try testing.expectEqualStrings("simple string", result_string.content);
    try testing.expectEqual(ExtractionResult.ContentType.text, result_string.content_type);
}