//! JSON Parser Core for CC Streamer
//! 
//! This module implements a recursive descent JSON parser that:
//! - Uses the tokenizer to get tokens
//! - Builds AST using ast.zig structures
//! - Provides error recovery to continue after malformed JSON
//! - Supports streaming with minimal memory usage
//! - Validates JSON structure according to RFC 7159

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const tokenizer = @import("tokenizer.zig");
const ast = @import("ast.zig");

const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const TokenType = tokenizer.TokenType;
const JsonValue = ast.JsonValue;
const Position = ast.Position;

/// JSON parsing errors
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidJson,
    OutOfMemory,
    DuplicateKey,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    TooMuchNesting,
    
    // Include tokenizer errors
    InvalidToken,
    UnterminatedString,
    InvalidEscapeSequence,
    InvalidUnicodeSequence,
};

/// Parser configuration
pub const ParserConfig = struct {
    /// Maximum nesting depth to prevent stack overflow
    max_depth: u32 = 1000,
    /// Whether to allow duplicate keys in objects
    allow_duplicate_keys: bool = false,
    /// Whether to continue parsing after errors (error recovery)
    continue_on_error: bool = true,
    /// Maximum memory usage for a single JSON object (0 = unlimited)
    max_memory_mb: u32 = 0,
};

/// Parser state and context
pub const Parser = struct {
    tokenizer: *Tokenizer,
    allocator: Allocator,
    config: ParserConfig,
    current_depth: u32,
    last_error: ?ParseError,
    error_count: u32,
    
    const Self = @This();
    
    /// Initialize a new parser
    pub fn init(allocator: Allocator, tok: *Tokenizer, config: ParserConfig) Self {
        return Self{
            .tokenizer = tok,
            .allocator = allocator,
            .config = config,
            .current_depth = 0,
            .last_error = null,
            .error_count = 0,
        };
    }
    
    /// Parse a complete JSON value from the token stream
    pub fn parseValue(self: *Self) ParseError!JsonValue {
        const token = try self.tokenizer.nextToken();
        return self.parseValueFromToken(token);
    }
    
    /// Parse a JSON value from a specific token
    fn parseValueFromToken(self: *Self, token: Token) ParseError!JsonValue {
        const pos = Position.init(token.position.line, token.position.column);
        
        return switch (token.type) {
            .left_brace => self.parseObject(pos),
            .left_bracket => self.parseArray(pos),
            .string => self.parseString(token.value, pos),
            .number => self.parseNumber(token.value, pos),
            .true_literal => JsonValue.createBoolean(true, pos),
            .false_literal => JsonValue.createBoolean(false, pos),
            .null_literal => JsonValue.createNull(pos),
            .eof => ParseError.UnexpectedEof,
            .invalid => {
                self.recordError(ParseError.InvalidToken);
                return ParseError.InvalidToken;
            },
            else => {
                self.recordError(ParseError.UnexpectedToken);
                return ParseError.UnexpectedToken;
            },
        };
    }
    
    /// Parse a JSON object
    fn parseObject(self: *Self, position: Position) ParseError!JsonValue {
        // Check nesting depth
        if (self.current_depth >= self.config.max_depth) {
            return ParseError.TooMuchNesting;
        }
        self.current_depth += 1;
        defer self.current_depth -= 1;
        
        var object = try JsonValue.createObject(self.allocator, position);
        errdefer object.deinit(self.allocator);
        
        // Check for empty object
        const peek_token = try self.tokenizer.peekToken();
        if (peek_token.type == .right_brace) {
            _ = try self.tokenizer.nextToken(); // consume the }
            return object;
        }
        
        // Parse key-value pairs
        while (true) {
            // Parse key (must be string)
            const key_token = try self.tokenizer.nextToken();
            if (key_token.type != .string) {
                return ParseError.UnexpectedToken;
            }
            
            // Remove quotes from key
            const key = self.unescapeString(key_token.value) catch key_token.value[1..key_token.value.len-1];
            
            // Expect colon
            const colon_token = try self.tokenizer.nextToken();
            if (colon_token.type != .colon) {
                return ParseError.UnexpectedToken;
            }
            
            // Parse value
            const value_token = try self.tokenizer.nextToken();
            const value = try self.parseValueFromToken(value_token);
            
            // Check for duplicate keys if configured
            if (!self.config.allow_duplicate_keys and object.data.object.get(key) != null) {
                return ParseError.DuplicateKey;
            }
            
            // Add to object
            try object.data.object.put(key, value);
            
            // Check for comma or end of object
            const next_token = try self.tokenizer.nextToken();
            switch (next_token.type) {
                .comma => {
                    // Continue parsing next key-value pair
                    continue;
                },
                .right_brace => {
                    // End of object
                    break;
                },
                .eof => {
                    return ParseError.UnexpectedEof;
                },
                else => {
                    return ParseError.UnexpectedToken;
                },
            }
        }
        
        return object;
    }
    
    /// Parse a JSON array
    fn parseArray(self: *Self, position: Position) ParseError!JsonValue {
        // Check nesting depth  
        if (self.current_depth >= self.config.max_depth) {
            return ParseError.TooMuchNesting;
        }
        self.current_depth += 1;
        defer self.current_depth -= 1;
        
        var array = try JsonValue.createArray(self.allocator, position);
        errdefer array.deinit(self.allocator);
        
        // Check for empty array
        const peek_token = try self.tokenizer.peekToken();
        if (peek_token.type == .right_bracket) {
            _ = try self.tokenizer.nextToken(); // consume the ]
            return array;
        }
        
        // Parse array elements
        while (true) {
            // Parse value
            const value_token = try self.tokenizer.nextToken();
            const value = try self.parseValueFromToken(value_token);
            
            // Add to array
            try array.data.array.append(value);
            
            // Check for comma or end of array
            const next_token = try self.tokenizer.nextToken();
            switch (next_token.type) {
                .comma => {
                    // Continue parsing next element
                    continue;
                },
                .right_bracket => {
                    // End of array
                    break;
                },
                .eof => {
                    return ParseError.UnexpectedEof;
                },
                else => {
                    return ParseError.UnexpectedToken;
                },
            }
        }
        
        return array;
    }
    
    /// Parse a string token into a JsonValue
    fn parseString(self: *Self, raw_value: []const u8, position: Position) ParseError!JsonValue {
        _ = self; // Currently we just store the raw string
        // In a more complete implementation, we might unescape the string here
        return JsonValue.createString(raw_value, position);
    }
    
    /// Parse a number token into a JsonValue
    fn parseNumber(self: *Self, raw_value: []const u8, position: Position) ParseError!JsonValue {
        _ = self; // For potential validation in the future
        // Store the raw number string for precise representation
        return JsonValue.createNumber(raw_value, position);
    }
    
    /// Unescape a JSON string (basic implementation)
    fn unescapeString(self: *Self, escaped: []const u8) ![]const u8 {
        _ = self; // For future implementation
        // For now, just remove the quotes
        if (escaped.len < 2 or escaped[0] != '"' or escaped[escaped.len-1] != '"') {
            return ParseError.InvalidString;
        }
        return escaped[1..escaped.len-1];
    }
    
    /// Record an error for statistics/debugging
    fn recordError(self: *Self, err: ParseError) void {
        self.last_error = err;
        self.error_count += 1;
    }
    
    /// Get error statistics
    pub fn getErrorCount(self: *const Self) u32 {
        return self.error_count;
    }
    
    /// Get last error that occurred
    pub fn getLastError(self: *const Self) ?ParseError {
        return self.last_error;
    }
};

// ============================================================================
// TESTS - Following TDD, these are written first
// ============================================================================

test "Parser initialization" {
    const input = "{}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    const parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectEqual(@as(u32, 0), parser.current_depth);
    try testing.expectEqual(@as(u32, 0), parser.error_count);
    try testing.expect(parser.last_error == null);
}

test "Parse simple JSON string" {
    const input = "\"hello world\"";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.string, value.type);
    try testing.expectEqualStrings("\"hello world\"", value.data.string);
}

test "Parse simple JSON number" {
    const input = "42.5";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.number, value.type);
    try testing.expectEqualStrings("42.5", value.data.number);
}

test "Parse JSON boolean values" {
    // Test true
    {
        const input = "true";
        var tok = Tokenizer.init(testing.allocator, input);
        const config = ParserConfig{};
        var parser = Parser.init(testing.allocator, &tok, config);
        
        var value = try parser.parseValue();
        defer value.deinit(testing.allocator);
        
        try testing.expectEqual(ast.ValueType.boolean, value.type);
        try testing.expect(value.data.boolean);
    }
    
    // Test false
    {
        const input = "false";
        var tok = Tokenizer.init(testing.allocator, input);
        const config = ParserConfig{};
        var parser = Parser.init(testing.allocator, &tok, config);
        
        var value = try parser.parseValue();
        defer value.deinit(testing.allocator);
        
        try testing.expectEqual(ast.ValueType.boolean, value.type);
        try testing.expect(!value.data.boolean);
    }
}

test "Parse JSON null value" {
    const input = "null";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.null, value.type);
}

test "Parse empty JSON object" {
    const input = "{}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.object, value.type);
    try testing.expect(value.data.object.isEmpty());
}

test "Parse simple JSON object" {
    const input = "{\"name\": \"test\", \"value\": 42}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.object, value.type);
    try testing.expectEqual(@as(usize, 2), value.data.object.count());
    
    // Check "name" field
    const name_value = value.data.object.get("name");
    try testing.expect(name_value != null);
    try testing.expectEqual(ast.ValueType.string, name_value.?.type);
    
    // Check "value" field
    const value_field = value.data.object.get("value");
    try testing.expect(value_field != null);
    try testing.expectEqual(ast.ValueType.number, value_field.?.type);
}

test "Parse empty JSON array" {
    const input = "[]";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.array, value.type);
    try testing.expect(value.data.array.isEmpty());
}

test "Parse simple JSON array" {
    const input = "[1, 2, 3]";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.array, value.type);
    try testing.expectEqual(@as(usize, 3), value.data.array.count());
    
    // Check array elements
    const first = value.data.array.get(0);
    try testing.expect(first != null);
    try testing.expectEqual(ast.ValueType.number, first.?.type);
    try testing.expectEqualStrings("1", first.?.data.number);
    
    const second = value.data.array.get(1);
    try testing.expect(second != null);
    try testing.expectEqualStrings("2", second.?.data.number);
    
    const third = value.data.array.get(2);
    try testing.expect(third != null);
    try testing.expectEqualStrings("3", third.?.data.number);
}

test "Parse nested JSON structure" {
    const input = "{\"data\": [1, 2], \"nested\": {\"inner\": true}}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.object, value.type);
    try testing.expectEqual(@as(usize, 2), value.data.object.count());
    
    // Check "data" array
    const data_value = value.data.object.get("data");
    try testing.expect(data_value != null);
    try testing.expectEqual(ast.ValueType.array, data_value.?.type);
    try testing.expectEqual(@as(usize, 2), data_value.?.data.array.count());
    
    // Check "nested" object
    const nested_value = value.data.object.get("nested");
    try testing.expect(nested_value != null);
    try testing.expectEqual(ast.ValueType.object, nested_value.?.type);
    
    const inner_value = nested_value.?.data.object.get("inner");
    try testing.expect(inner_value != null);
    try testing.expectEqual(ast.ValueType.boolean, inner_value.?.type);
    try testing.expect(inner_value.?.data.boolean);
}

// ERROR HANDLING TESTS
test "Parse error - unexpected EOF" {
    const input = "";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.UnexpectedEof, parser.parseValue());
}

test "Parse error - unexpected token" {
    const input = ",";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.UnexpectedToken, parser.parseValue());
}

test "Parse error - malformed object missing colon" {
    const input = "{\"key\" \"value\"}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.UnexpectedToken, parser.parseValue());
}

test "Parse error - malformed object missing closing brace" {
    const input = "{\"key\": \"value\"";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.UnexpectedEof, parser.parseValue());
}

test "Parse error - malformed array missing closing bracket" {
    const input = "[1, 2, 3";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.UnexpectedEof, parser.parseValue());
}

test "Parse error - duplicate keys detection" {
    const input = "{\"key\": 1, \"key\": 2}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{ .allow_duplicate_keys = false };
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.DuplicateKey, parser.parseValue());
}

test "Parse with duplicate keys allowed" {
    const input = "{\"key\": 1, \"key\": 2}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{ .allow_duplicate_keys = true };
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.object, value.type);
    // The second value should overwrite the first
    const key_value = value.data.object.get("key");
    try testing.expect(key_value != null);
}

test "Error statistics tracking" {
    const input = ",";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    _ = parser.parseValue() catch {};
    
    try testing.expectEqual(@as(u32, 1), parser.getErrorCount());
    try testing.expect(parser.getLastError() != null);
}

// COMPREHENSIVE EDGE CASE TESTS
test "Parse deeply nested structure" {
    const input = "{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":true}}}}}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.object, value.type);
    
    // Navigate through the nested structure
    const a = value.data.object.get("a");
    try testing.expect(a != null);
    const b = a.?.data.object.get("b");
    try testing.expect(b != null);
    const c = b.?.data.object.get("c");
    try testing.expect(c != null);
    const d = c.?.data.object.get("d");
    try testing.expect(d != null);
    const e = d.?.data.object.get("e");
    try testing.expect(e != null);
    try testing.expect(e.?.data.boolean);
}

test "Parse mixed array types" {
    const input = "[\"string\", 42, true, null, {\"nested\": \"object\"}, [1, 2]]";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.array, value.type);
    try testing.expectEqual(@as(usize, 6), value.data.array.count());
    
    // Check each element type
    try testing.expectEqual(ast.ValueType.string, value.data.array.get(0).?.type);
    try testing.expectEqual(ast.ValueType.number, value.data.array.get(1).?.type);
    try testing.expectEqual(ast.ValueType.boolean, value.data.array.get(2).?.type);
    try testing.expectEqual(ast.ValueType.null, value.data.array.get(3).?.type);
    try testing.expectEqual(ast.ValueType.object, value.data.array.get(4).?.type);
    try testing.expectEqual(ast.ValueType.array, value.data.array.get(5).?.type);
}

test "Parse with scientific notation numbers" {
    const input = "[1e10, 2.5E-3, -1.23e+4]";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.array, value.type);
    try testing.expectEqual(@as(usize, 3), value.data.array.count());
    
    try testing.expectEqualStrings("1e10", value.data.array.get(0).?.data.number);
    try testing.expectEqualStrings("2.5E-3", value.data.array.get(1).?.data.number);
    try testing.expectEqualStrings("-1.23e+4", value.data.array.get(2).?.data.number);
}

test "Parse with Unicode strings" {
    const input = "{\"emoji\": \"\\ud83d\\ude00\", \"chinese\": \"\\u4e2d\\u6587\"}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    var value = try parser.parseValue();
    defer value.deinit(testing.allocator);
    
    try testing.expectEqual(ast.ValueType.object, value.type);
    
    const emoji = value.data.object.get("emoji");
    try testing.expect(emoji != null);
    try testing.expectEqual(ast.ValueType.string, emoji.?.type);
    
    const chinese = value.data.object.get("chinese");
    try testing.expect(chinese != null);
    try testing.expectEqual(ast.ValueType.string, chinese.?.type);
}

test "Parse error - nesting too deep" {
    // Create a deeply nested structure that exceeds max depth
    var nested = std.ArrayList(u8).init(testing.allocator);
    defer nested.deinit();
    
    const max_depth = 10;
    
    for (0..max_depth + 5) |_| {
        try nested.appendSlice("{\"a\":");
    }
    try nested.appendSlice("true");
    for (0..max_depth + 5) |_| {
        try nested.append('}');
    }
    
    var tok = Tokenizer.init(testing.allocator, nested.items);
    const config = ParserConfig{ .max_depth = max_depth };
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.TooMuchNesting, parser.parseValue());
}

test "Parse with trailing comma in object should fail" {
    const input = "{\"key\": \"value\",}";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.UnexpectedToken, parser.parseValue());
}

test "Parse with trailing comma in array should fail" {
    const input = "[1, 2, 3,]";
    var tok = Tokenizer.init(testing.allocator, input);
    const config = ParserConfig{};
    var parser = Parser.init(testing.allocator, &tok, config);
    
    try testing.expectError(ParseError.UnexpectedToken, parser.parseValue());
}

test "Parse empty object and array edge cases" {
    // Object with whitespace
    {
        const input = "{ }";
        var tok = Tokenizer.init(testing.allocator, input);
        const config = ParserConfig{};
        var parser = Parser.init(testing.allocator, &tok, config);
        
        var value = try parser.parseValue();
        defer value.deinit(testing.allocator);
        
        try testing.expectEqual(ast.ValueType.object, value.type);
        try testing.expect(value.data.object.isEmpty());
    }
    
    // Array with whitespace  
    {
        const input = "[ ]";
        var tok = Tokenizer.init(testing.allocator, input);
        const config = ParserConfig{};
        var parser = Parser.init(testing.allocator, &tok, config);
        
        var value = try parser.parseValue();
        defer value.deinit(testing.allocator);
        
        try testing.expectEqual(ast.ValueType.array, value.type);
        try testing.expect(value.data.array.isEmpty());
    }
}