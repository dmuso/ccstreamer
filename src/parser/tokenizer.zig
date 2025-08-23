//! JSON Tokenizer for CC Streamer
//! 
//! This module implements a streaming JSON tokenizer that converts JSON text
//! into a stream of tokens. It supports:
//! - All JSON value types (strings, numbers, booleans, null, objects, arrays)
//! - Unicode escape sequences in strings
//! - Scientific notation in numbers  
//! - Error recovery for malformed JSON
//! - Streaming mode with minimal memory usage

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// JSON token types
pub const TokenType = enum {
    // Structural tokens
    left_brace,       // {
    right_brace,      // }
    left_bracket,     // [
    right_bracket,    // ]
    comma,            // ,
    colon,            // :
    
    // Literal tokens
    string,           // "text"
    number,           // 123, 45.67, -89, 1.23e-4
    true_literal,     // true
    false_literal,    // false
    null_literal,     // null
    
    // Special tokens
    eof,              // End of input
    invalid,          // Invalid/malformed token
};

/// Token position information for error reporting
pub const Position = struct {
    line: u32,
    column: u32,
};

/// A JSON token with its value and position
pub const Token = struct {
    type: TokenType,
    value: []const u8,
    position: Position,
    
    /// Create a new token
    pub fn init(token_type: TokenType, value: []const u8, position: Position) Token {
        return Token{
            .type = token_type,
            .value = value,
            .position = position,
        };
    }
};

/// JSON tokenization errors
pub const TokenizerError = error{
    InvalidToken,
    UnterminatedString,
    InvalidEscapeSequence,
    InvalidUnicodeSequence,
    InvalidNumber,
    OutOfMemory,
};

/// JSON Tokenizer state machine
pub const Tokenizer = struct {
    input: []const u8,
    position: usize,
    line: u32,
    column: u32,
    allocator: Allocator,
    
    const Self = @This();
    
    /// Initialize a new tokenizer with input text
    pub fn init(allocator: Allocator, input: []const u8) Self {
        return Self{
            .input = input,
            .position = 0,
            .line = 1,
            .column = 1,
            .allocator = allocator,
        };
    }
    
    /// Get the next token from the input stream
    pub fn nextToken(self: *Self) TokenizerError!Token {
        // Skip whitespace
        self.skipWhitespace();
        
        if (self.position >= self.input.len) {
            return Token.init(.eof, "", self.getCurrentPosition());
        }
        
        const current_pos = self.getCurrentPosition();
        const current_char = self.input[self.position];
        
        return switch (current_char) {
            '{' => self.consumeSingleCharToken(.left_brace),
            '}' => self.consumeSingleCharToken(.right_brace),
            '[' => self.consumeSingleCharToken(.left_bracket),
            ']' => self.consumeSingleCharToken(.right_bracket),
            ',' => self.consumeSingleCharToken(.comma),
            ':' => self.consumeSingleCharToken(.colon),
            '"' => self.tokenizeString(),
            't' => self.tokenizeKeyword("true", .true_literal),
            'f' => self.tokenizeKeyword("false", .false_literal),
            'n' => self.tokenizeKeyword("null", .null_literal),
            '-', '0'...'9' => self.tokenizeNumber(),
            else => {
                const invalid_token = Token.init(.invalid, self.input[self.position..self.position + 1], current_pos);
                self.advance(); // Always advance on invalid token to avoid infinite loops
                return invalid_token;
            },
        };
    }
    
    /// Peek at the next token without consuming it
    pub fn peekToken(self: *Self) TokenizerError!Token {
        const saved_position = self.position;
        const saved_line = self.line;
        const saved_column = self.column;
        
        const token = try self.nextToken();
        
        // Restore state
        self.position = saved_position;
        self.line = saved_line;
        self.column = saved_column;
        
        return token;
    }
    
    /// Get current position in the input
    fn getCurrentPosition(self: *const Self) Position {
        return Position{
            .line = self.line,
            .column = self.column,
        };
    }
    
    /// Advance position by one character, updating line/column
    fn advance(self: *Self) void {
        if (self.position < self.input.len) {
            if (self.input[self.position] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.position += 1;
        }
    }
    
    /// Skip whitespace characters
    fn skipWhitespace(self: *Self) void {
        while (self.position < self.input.len) {
            switch (self.input[self.position]) {
                ' ', '\t', '\n', '\r' => self.advance(),
                else => break,
            }
        }
    }
    
    /// Consume a single character token
    fn consumeSingleCharToken(self: *Self, token_type: TokenType) Token {
        const pos = self.getCurrentPosition();
        const value = self.input[self.position..self.position + 1];
        self.advance();
        return Token.init(token_type, value, pos);
    }
    
    /// Tokenize a string literal
    fn tokenizeString(self: *Self) TokenizerError!Token {
        const start_pos = self.getCurrentPosition();
        const start_index = self.position;
        
        // Skip opening quote
        if (self.input[self.position] != '"') {
            return TokenizerError.InvalidToken;
        }
        self.advance();
        
        while (self.position < self.input.len) {
            const current_char = self.input[self.position];
            
            if (current_char == '"') {
                // Found closing quote
                self.advance();
                const value = self.input[start_index..self.position];
                return Token.init(.string, value, start_pos);
            } else if (current_char == '\\') {
                // Handle escape sequence
                self.advance();
                if (self.position >= self.input.len) {
                    return TokenizerError.UnterminatedString;
                }
                
                const escaped_char = self.input[self.position];
                switch (escaped_char) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                        self.advance();
                    },
                    'u' => {
                        // Handle unicode escape sequence \uXXXX
                        self.advance();
                        for (0..4) |_| {
                            if (self.position >= self.input.len) {
                                return TokenizerError.InvalidUnicodeSequence;
                            }
                            const hex_char = self.input[self.position];
                            if (!std.ascii.isHex(hex_char)) {
                                return TokenizerError.InvalidUnicodeSequence;
                            }
                            self.advance();
                        }
                    },
                    else => {
                        return TokenizerError.InvalidEscapeSequence;
                    },
                }
            } else if (std.ascii.isControl(current_char)) {
                // Control characters must be escaped
                return TokenizerError.InvalidToken;
            } else {
                // Regular character
                self.advance();
            }
        }
        
        // Reached end without finding closing quote
        return TokenizerError.UnterminatedString;
    }
    
    /// Tokenize a keyword (true, false, null)
    fn tokenizeKeyword(self: *Self, expected: []const u8, token_type: TokenType) TokenizerError!Token {
        const start_pos = self.getCurrentPosition();
        const start_index = self.position;
        
        // Check if we have enough characters left
        if (self.position + expected.len > self.input.len) {
            return Token.init(.invalid, self.input[start_index..], start_pos);
        }
        
        // Check if the keyword matches
        const candidate = self.input[self.position..self.position + expected.len];
        if (!std.mem.eql(u8, candidate, expected)) {
            return Token.init(.invalid, self.input[start_index..start_index + 1], start_pos);
        }
        
        // Check that keyword is not followed by alphanumeric characters
        // This prevents matching "truex" as "true"
        if (self.position + expected.len < self.input.len) {
            const next_char = self.input[self.position + expected.len];
            if (std.ascii.isAlphanumeric(next_char) or next_char == '_') {
                return Token.init(.invalid, self.input[start_index..start_index + 1], start_pos);
            }
        }
        
        // Advance position by the keyword length
        for (0..expected.len) |_| {
            self.advance();
        }
        
        const value = self.input[start_index..self.position];
        return Token.init(token_type, value, start_pos);
    }
    
    /// Tokenize a number literal
    fn tokenizeNumber(self: *Self) TokenizerError!Token {
        const start_pos = self.getCurrentPosition();
        const start_index = self.position;
        
        // Handle optional negative sign
        if (self.position < self.input.len and self.input[self.position] == '-') {
            self.advance();
        }
        
        // Must have at least one digit after optional minus
        if (self.position >= self.input.len or !std.ascii.isDigit(self.input[self.position])) {
            return TokenizerError.InvalidNumber;
        }
        
        // Handle integer part
        if (self.input[self.position] == '0') {
            // Zero cannot be followed by more digits (no leading zeros allowed)
            self.advance();
            if (self.position < self.input.len and std.ascii.isDigit(self.input[self.position])) {
                return TokenizerError.InvalidNumber;
            }
        } else {
            // Consume all digits
            while (self.position < self.input.len and std.ascii.isDigit(self.input[self.position])) {
                self.advance();
            }
        }
        
        // Handle optional decimal part
        if (self.position < self.input.len and self.input[self.position] == '.') {
            self.advance();
            
            // Must have at least one digit after decimal point
            if (self.position >= self.input.len or !std.ascii.isDigit(self.input[self.position])) {
                return TokenizerError.InvalidNumber;
            }
            
            // Consume all decimal digits
            while (self.position < self.input.len and std.ascii.isDigit(self.input[self.position])) {
                self.advance();
            }
        }
        
        // Handle optional exponent part
        if (self.position < self.input.len and (self.input[self.position] == 'e' or self.input[self.position] == 'E')) {
            self.advance();
            
            // Optional sign in exponent
            if (self.position < self.input.len and (self.input[self.position] == '+' or self.input[self.position] == '-')) {
                self.advance();
            }
            
            // Must have at least one digit in exponent
            if (self.position >= self.input.len or !std.ascii.isDigit(self.input[self.position])) {
                return TokenizerError.InvalidNumber;
            }
            
            // Consume all exponent digits
            while (self.position < self.input.len and std.ascii.isDigit(self.input[self.position])) {
                self.advance();
            }
        }
        
        const value = self.input[start_index..self.position];
        return Token.init(.number, value, start_pos);
    }
};

// ============================================================================
// TESTS - Following TDD, these are written first
// ============================================================================

test "Tokenizer initialization" {
    const input = "{\"test\": 123}";
    const tokenizer = Tokenizer.init(testing.allocator, input);
    
    try testing.expectEqual(@as(usize, 0), tokenizer.position);
    try testing.expectEqual(@as(u32, 1), tokenizer.line);
    try testing.expectEqual(@as(u32, 1), tokenizer.column);
    try testing.expectEqualStrings(input, tokenizer.input);
}

test "Position tracking" {
    var tokenizer = Tokenizer.init(testing.allocator, "test\nline");
    
    // Initial position
    try testing.expectEqual(@as(u32, 1), tokenizer.line);
    try testing.expectEqual(@as(u32, 1), tokenizer.column);
    
    // Advance through characters
    tokenizer.advance(); // t
    try testing.expectEqual(@as(u32, 1), tokenizer.line);
    try testing.expectEqual(@as(u32, 2), tokenizer.column);
    
    tokenizer.advance(); // e
    tokenizer.advance(); // s
    tokenizer.advance(); // t
    try testing.expectEqual(@as(u32, 1), tokenizer.line);
    try testing.expectEqual(@as(u32, 5), tokenizer.column);
    
    tokenizer.advance(); // \n
    try testing.expectEqual(@as(u32, 2), tokenizer.line);
    try testing.expectEqual(@as(u32, 1), tokenizer.column);
}

test "Skip whitespace" {
    var tokenizer = Tokenizer.init(testing.allocator, "   \t\n\r  abc");
    
    tokenizer.skipWhitespace();
    
    try testing.expectEqual(@as(u8, 'a'), tokenizer.input[tokenizer.position]);
    try testing.expectEqual(@as(u32, 2), tokenizer.line);
}

test "Single character tokens" {
    var tokenizer = Tokenizer.init(testing.allocator, "{}[],:");
    
    const expected_types = [_]TokenType{ .left_brace, .right_brace, .left_bracket, .right_bracket, .comma, .colon };
    
    for (expected_types) |expected_type| {
        const token = try tokenizer.nextToken();
        try testing.expectEqual(expected_type, token.type);
        try testing.expectEqual(@as(usize, 1), token.value.len);
    }
    
    // Should reach EOF
    const eof_token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.eof, eof_token.type);
}

test "Single character tokens with whitespace" {
    var tokenizer = Tokenizer.init(testing.allocator, " { } [ ] , : ");
    
    const expected_types = [_]TokenType{ .left_brace, .right_brace, .left_bracket, .right_bracket, .comma, .colon };
    
    for (expected_types) |expected_type| {
        const token = try tokenizer.nextToken();
        try testing.expectEqual(expected_type, token.type);
    }
}

test "String tokenization works now" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"hello\"");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.string, token.type);
    try testing.expectEqualStrings("\"hello\"", token.value);
}

test "Number tokenization works now" {
    var tokenizer = Tokenizer.init(testing.allocator, "123");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("123", token.value);
}

test "Keyword tokenization works now" {
    var tokenizer = Tokenizer.init(testing.allocator, "true");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.true_literal, token.type);
    try testing.expectEqualStrings("true", token.value);
}

test "Invalid token detection" {
    var tokenizer = Tokenizer.init(testing.allocator, "@#$");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.invalid, token.type);
    try testing.expectEqualStrings("@", token.value);
}

test "EOF token" {
    var tokenizer = Tokenizer.init(testing.allocator, "");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.eof, token.type);
    try testing.expectEqualStrings("", token.value);
}

test "Peek token doesn't advance position" {
    var tokenizer = Tokenizer.init(testing.allocator, "{");
    
    const peeked_token = try tokenizer.peekToken();
    try testing.expectEqual(TokenType.left_brace, peeked_token.type);
    
    // Position should not have advanced
    try testing.expectEqual(@as(usize, 0), tokenizer.position);
    
    // Next token should be the same
    const next_token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.left_brace, next_token.type);
    
    // Now position should have advanced
    try testing.expectEqual(@as(usize, 1), tokenizer.position);
}

// STRING TOKENIZATION TESTS - These should initially fail
test "Simple string tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"hello\"");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.string, token.type);
    try testing.expectEqualStrings("\"hello\"", token.value);
}

test "Empty string tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"\"");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.string, token.type);
    try testing.expectEqualStrings("\"\"", token.value);
}

test "String with escaped quotes" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"He said \\\"hello\\\"\"");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.string, token.type);
    try testing.expectEqualStrings("\"He said \\\"hello\\\"\"", token.value);
}

test "String with basic escape sequences" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"line1\\nline2\\ttab\"");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.string, token.type);
    try testing.expectEqualStrings("\"line1\\nline2\\ttab\"", token.value);
}

test "String with unicode escape sequences" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"\\u0048\\u0065\\u006c\\u006c\\u006f\"");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.string, token.type);
    try testing.expectEqualStrings("\"\\u0048\\u0065\\u006c\\u006c\\u006f\"", token.value);
}

test "Unterminated string error" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"unterminated string");
    
    try testing.expectError(TokenizerError.UnterminatedString, tokenizer.nextToken());
}

test "Invalid escape sequence error" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"invalid\\x escape\"");
    
    try testing.expectError(TokenizerError.InvalidEscapeSequence, tokenizer.nextToken());
}

test "Invalid unicode sequence error" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"\\uXYZW\"");
    
    try testing.expectError(TokenizerError.InvalidUnicodeSequence, tokenizer.nextToken());
}

// NUMBER TOKENIZATION TESTS - These should initially fail
test "Simple integer tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "123");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("123", token.value);
}

test "Negative integer tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "-456");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("-456", token.value);
}

test "Zero tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "0");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("0", token.value);
}

test "Decimal number tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "123.456");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("123.456", token.value);
}

test "Scientific notation positive exponent" {
    var tokenizer = Tokenizer.init(testing.allocator, "1.23e+10");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("1.23e+10", token.value);
}

test "Scientific notation negative exponent" {
    var tokenizer = Tokenizer.init(testing.allocator, "1.23e-10");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("1.23e-10", token.value);
}

test "Scientific notation uppercase E" {
    var tokenizer = Tokenizer.init(testing.allocator, "1.23E10");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("1.23E10", token.value);
}

test "Invalid number leading zero" {
    var tokenizer = Tokenizer.init(testing.allocator, "01");
    
    try testing.expectError(TokenizerError.InvalidNumber, tokenizer.nextToken());
}

test "Invalid number multiple decimal points" {
    var tokenizer = Tokenizer.init(testing.allocator, "123.45.67");
    
    // This should parse 123.45 as a valid number, then encounter the second decimal as invalid
    const token1 = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token1.type);
    try testing.expectEqualStrings("123.45", token1.value);
    
    // The next token should be invalid due to the second decimal point
    const token2 = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.invalid, token2.type);
}

test "Invalid number ending with decimal" {
    var tokenizer = Tokenizer.init(testing.allocator, "123.");
    
    try testing.expectError(TokenizerError.InvalidNumber, tokenizer.nextToken());
}

// KEYWORD TOKENIZATION TESTS - These should initially fail
test "True literal tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "true");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.true_literal, token.type);
    try testing.expectEqualStrings("true", token.value);
}

test "False literal tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "false");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.false_literal, token.type);
    try testing.expectEqualStrings("false", token.value);
}

test "Null literal tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, "null");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.null_literal, token.type);
    try testing.expectEqualStrings("null", token.value);
}

test "Invalid keyword partial match" {
    var tokenizer = Tokenizer.init(testing.allocator, "tru");
    
    // This should be treated as an invalid token, not as a partial keyword
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.invalid, token.type);
}

test "Keyword with trailing chars" {
    var tokenizer = Tokenizer.init(testing.allocator, "truex");
    
    // This should be treated as an invalid token since "truex" is not a valid keyword
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.invalid, token.type);
}

// INTEGRATION TESTS - Test complex JSON structures
test "Complex JSON object tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, 
        \\{"name": "test", "value": 42, "active": true, "data": null}
    );
    
    const expected_tokens = [_]TokenType{
        .left_brace, .string, .colon, .string, .comma,
        .string, .colon, .number, .comma,
        .string, .colon, .true_literal, .comma,
        .string, .colon, .null_literal,
        .right_brace
    };
    
    for (expected_tokens) |expected_type| {
        const token = try tokenizer.nextToken();
        try testing.expectEqual(expected_type, token.type);
    }
    
    const eof_token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.eof, eof_token.type);
}

test "Complex JSON array tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, 
        \\[123, -45.67, "hello", true, false, null]
    );
    
    const expected_tokens = [_]TokenType{
        .left_bracket, .number, .comma, .number, .comma, 
        .string, .comma, .true_literal, .comma, .false_literal, .comma, .null_literal,
        .right_bracket
    };
    
    for (expected_tokens) |expected_type| {
        const token = try tokenizer.nextToken();
        try testing.expectEqual(expected_type, token.type);
    }
    
    const eof_token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.eof, eof_token.type);
}

test "Nested JSON structure tokenization" {
    var tokenizer = Tokenizer.init(testing.allocator, 
        \\{"outer": {"inner": [1, 2, 3]}}
    );
    
    const expected_tokens = [_]TokenType{
        .left_brace, .string, .colon, .left_brace,
        .string, .colon, .left_bracket,
        .number, .comma, .number, .comma, .number,
        .right_bracket, .right_brace, .right_brace
    };
    
    for (expected_tokens) |expected_type| {
        const token = try tokenizer.nextToken();
        try testing.expectEqual(expected_type, token.type);
    }
    
    const eof_token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.eof, eof_token.type);
}

test "Scientific notation edge cases" {
    var tokenizer = Tokenizer.init(testing.allocator, "1e10 2E+5 3e-10");
    
    // First number: 1e10
    var token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("1e10", token.value);
    
    // Second number: 2E+5
    token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("2E+5", token.value);
    
    // Third number: 3e-10
    token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.number, token.type);
    try testing.expectEqualStrings("3e-10", token.value);
}

test "Unicode string handling" {
    var tokenizer = Tokenizer.init(testing.allocator, "\"Hello \\u4e2d\\u6587 World\"");
    
    const token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.string, token.type);
    try testing.expectEqualStrings("\"Hello \\u4e2d\\u6587 World\"", token.value);
}

test "Error recovery continues after invalid token" {
    var tokenizer = Tokenizer.init(testing.allocator, "@{\"valid\": true}");
    
    // First token should be invalid (@)
    var token = try tokenizer.nextToken();
    try testing.expectEqual(TokenType.invalid, token.type);
    try testing.expectEqualStrings("@", token.value);
    
    // Should continue with valid tokens
    token = try tokenizer.nextToken(); // {
    try testing.expectEqual(TokenType.left_brace, token.type);
    
    token = try tokenizer.nextToken(); // "valid"
    try testing.expectEqual(TokenType.string, token.type);
    
    token = try tokenizer.nextToken(); // :
    try testing.expectEqual(TokenType.colon, token.type);
    
    token = try tokenizer.nextToken(); // true
    try testing.expectEqual(TokenType.true_literal, token.type);
    
    token = try tokenizer.nextToken(); // }
    try testing.expectEqual(TokenType.right_brace, token.type);
}