//! Indentation Engine for CC Streamer
//! 
//! This module provides configurable indentation management for formatting JSON output.
//! It supports:
//! - Configurable indent width (2, 4 spaces or tabs)
//! - Depth tracking for nested structures
//! - Indent/dedent operations
//! - String generation for indentation

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Indentation style configuration
pub const IndentStyle = enum {
    spaces_2,
    spaces_4,
    tabs,
    
    /// Get the string representation of one indentation level
    pub fn getString(self: IndentStyle) []const u8 {
        return switch (self) {
            .spaces_2 => "  ",
            .spaces_4 => "    ",
            .tabs => "\t",
        };
    }
    
    /// Get width of one indentation level (for display purposes)
    pub fn getWidth(self: IndentStyle) u32 {
        return switch (self) {
            .spaces_2 => 2,
            .spaces_4 => 4,
            .tabs => 4, // Assuming tab displays as 4 spaces
        };
    }
};

/// Indentation engine for managing nested structure formatting
pub const IndentationEngine = struct {
    style: IndentStyle,
    current_depth: u32,
    allocator: Allocator,
    
    const Self = @This();
    
    /// Initialize the indentation engine
    pub fn init(allocator: Allocator, style: IndentStyle) Self {
        return Self{
            .style = style,
            .current_depth = 0,
            .allocator = allocator,
        };
    }
    
    /// Increase indentation depth
    pub fn indent(self: *Self) void {
        self.current_depth += 1;
    }
    
    /// Decrease indentation depth
    pub fn dedent(self: *Self) void {
        if (self.current_depth > 0) {
            self.current_depth -= 1;
        }
    }
    
    /// Get current indentation depth
    pub fn getDepth(self: *const Self) u32 {
        return self.current_depth;
    }
    
    /// Reset indentation to root level
    pub fn reset(self: *Self) void {
        self.current_depth = 0;
    }
    
    /// Generate indentation string for current depth
    /// Caller owns the returned memory
    pub fn generateString(self: *const Self) ![]u8 {
        if (self.current_depth == 0) {
            return try self.allocator.dupe(u8, "");
        }
        
        const single_indent = self.style.getString();
        const total_len = single_indent.len * self.current_depth;
        
        var result = try self.allocator.alloc(u8, total_len);
        
        var pos: usize = 0;
        for (0..self.current_depth) |_| {
            @memcpy(result[pos..pos + single_indent.len], single_indent);
            pos += single_indent.len;
        }
        
        return result;
    }
    
    /// Generate indentation string for specific depth
    /// Caller owns the returned memory
    pub fn generateStringForDepth(self: *const Self, depth: u32) ![]u8 {
        if (depth == 0) {
            return try self.allocator.dupe(u8, "");
        }
        
        const single_indent = self.style.getString();
        const total_len = single_indent.len * depth;
        
        var result = try self.allocator.alloc(u8, total_len);
        
        var pos: usize = 0;
        for (0..depth) |_| {
            @memcpy(result[pos..pos + single_indent.len], single_indent);
            pos += single_indent.len;
        }
        
        return result;
    }
    
    /// Check if indentation has trailing whitespace (should not)
    pub fn hasTrailingWhitespace(_: *const Self, text: []const u8) bool {
        if (text.len == 0) return false;
        
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                const last_char = line[line.len - 1];
                if (last_char == ' ' or last_char == '\t') {
                    return true;
                }
            }
        }
        
        return false;
    }
};

// ================================
// TESTS (Writing failing tests first following TDD)
// ================================

test "IndentStyle.getString returns correct strings" {
    try testing.expectEqualStrings("  ", IndentStyle.spaces_2.getString());
    try testing.expectEqualStrings("    ", IndentStyle.spaces_4.getString());
    try testing.expectEqualStrings("\t", IndentStyle.tabs.getString());
}

test "IndentStyle.getWidth returns correct widths" {
    try testing.expectEqual(@as(u32, 2), IndentStyle.spaces_2.getWidth());
    try testing.expectEqual(@as(u32, 4), IndentStyle.spaces_4.getWidth());
    try testing.expectEqual(@as(u32, 4), IndentStyle.tabs.getWidth());
}

test "IndentationEngine.init creates engine with zero depth" {
    const engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    try testing.expectEqual(IndentStyle.spaces_2, engine.style);
    try testing.expectEqual(@as(u32, 0), engine.current_depth);
}

test "IndentationEngine.indent increases depth" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // Initial depth should be 0
    try testing.expectEqual(@as(u32, 0), engine.getDepth());
    
    // First indent
    engine.indent();
    try testing.expectEqual(@as(u32, 1), engine.getDepth());
    
    // Second indent
    engine.indent();
    try testing.expectEqual(@as(u32, 2), engine.getDepth());
}

test "IndentationEngine.dedent decreases depth" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // Start with some depth
    engine.indent();
    engine.indent();
    try testing.expectEqual(@as(u32, 2), engine.getDepth());
    
    // First dedent
    engine.dedent();
    try testing.expectEqual(@as(u32, 1), engine.getDepth());
    
    // Second dedent
    engine.dedent();
    try testing.expectEqual(@as(u32, 0), engine.getDepth());
}

test "IndentationEngine.dedent does not go below zero" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // Try to dedent from zero
    engine.dedent();
    try testing.expectEqual(@as(u32, 0), engine.getDepth());
    
    // Multiple dedents
    engine.dedent();
    engine.dedent();
    try testing.expectEqual(@as(u32, 0), engine.getDepth());
}

test "IndentationEngine.reset sets depth to zero" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // Build up some depth
    engine.indent();
    engine.indent();
    engine.indent();
    try testing.expectEqual(@as(u32, 3), engine.getDepth());
    
    // Reset should go back to zero
    engine.reset();
    try testing.expectEqual(@as(u32, 0), engine.getDepth());
}

test "IndentationEngine.generateString creates correct indentation - spaces_2" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // Zero depth - empty string
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("", indent_str);
    }
    
    // One level
    engine.indent();
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("  ", indent_str);
    }
    
    // Two levels
    engine.indent();
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("    ", indent_str);
    }
    
    // Three levels
    engine.indent();
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("      ", indent_str);
    }
}

test "IndentationEngine.generateString creates correct indentation - spaces_4" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_4);
    
    // Zero depth
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("", indent_str);
    }
    
    // One level
    engine.indent();
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("    ", indent_str);
    }
    
    // Two levels
    engine.indent();
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("        ", indent_str);
    }
}

test "IndentationEngine.generateString creates correct indentation - tabs" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.tabs);
    
    // Zero depth
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("", indent_str);
    }
    
    // One level
    engine.indent();
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("\t", indent_str);
    }
    
    // Two levels
    engine.indent();
    {
        const indent_str = try engine.generateString();
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("\t\t", indent_str);
    }
}

test "IndentationEngine.generateStringForDepth works with specific depth" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // Test various depths without changing engine state
    {
        const indent_str = try engine.generateStringForDepth(0);
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("", indent_str);
    }
    
    {
        const indent_str = try engine.generateStringForDepth(1);
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("  ", indent_str);
    }
    
    {
        const indent_str = try engine.generateStringForDepth(3);
        defer testing.allocator.free(indent_str);
        try testing.expectEqualStrings("      ", indent_str);
    }
    
    // Engine depth should still be 0
    try testing.expectEqual(@as(u32, 0), engine.getDepth());
}

test "IndentationEngine.hasTrailingWhitespace detects trailing spaces" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // No trailing whitespace
    try testing.expect(!engine.hasTrailingWhitespace("hello world"));
    try testing.expect(!engine.hasTrailingWhitespace(""));
    try testing.expect(!engine.hasTrailingWhitespace("line1\nline2"));
    
    // Has trailing whitespace
    try testing.expect(engine.hasTrailingWhitespace("hello "));
    try testing.expect(engine.hasTrailingWhitespace("hello\t"));
    try testing.expect(engine.hasTrailingWhitespace("line1 \nline2"));
    try testing.expect(engine.hasTrailingWhitespace("line1\nline2 "));
}

test "IndentationEngine deep nesting stress test" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // Test deep nesting (20 levels)
    const target_depth = 20;
    
    // Indent to target depth
    for (0..target_depth) |_| {
        engine.indent();
    }
    
    try testing.expectEqual(target_depth, engine.getDepth());
    
    // Generate string for deep nesting
    const indent_str = try engine.generateString();
    defer testing.allocator.free(indent_str);
    
    // Should be 40 spaces (20 * 2)
    try testing.expectEqual(@as(usize, 40), indent_str.len);
    
    // All characters should be spaces
    for (indent_str) |char| {
        try testing.expectEqual(@as(u8, ' '), char);
    }
    
    // Dedent back to zero
    for (0..target_depth) |_| {
        engine.dedent();
    }
    
    try testing.expectEqual(@as(u32, 0), engine.getDepth());
}

test "IndentationEngine memory management" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_4);
    
    // Generate multiple indentation strings
    var strings = std.ArrayList([]u8).init(testing.allocator);
    defer {
        for (strings.items) |str| {
            testing.allocator.free(str);
        }
        strings.deinit();
    }
    
    // Create strings for different depths
    for (0..5) |depth| {
        const depth_u32: u32 = @intCast(depth);
        const indent_str = try engine.generateStringForDepth(depth_u32);
        try strings.append(indent_str);
        
        // Verify length is correct
        try testing.expectEqual(depth * 4, indent_str.len);
    }
}

test "IndentationEngine edge cases" {
    var engine = IndentationEngine.init(testing.allocator, IndentStyle.spaces_2);
    
    // Test with maximum reasonable depth
    const max_depth = 100;
    
    for (0..max_depth) |_| {
        engine.indent();
    }
    
    try testing.expectEqual(max_depth, engine.getDepth());
    
    // Should still be able to generate string
    const indent_str = try engine.generateString();
    defer testing.allocator.free(indent_str);
    
    try testing.expectEqual(max_depth * 2, indent_str.len);
    
    // Reset and verify
    engine.reset();
    try testing.expectEqual(@as(u32, 0), engine.getDepth());
}