//! Integration tests for CC Streamer formatting components
//!
//! This tests the interaction between different formatting components

const std = @import("std");
const testing = std.testing;

// Import formatter components
const indentation = @import("../src/formatter/indentation.zig");
const json_formatter = @import("../src/formatter/json_formatter.zig");
const colors = @import("../src/formatter/colors.zig");

test "Integration: IndentationEngine with JsonFormatter" {
    const indent_engine = indentation.IndentationEngine.init(testing.allocator, indentation.IndentStyle.spaces_2);
    const formatter_options = json_formatter.FormatOptions.default();
    var formatter = json_formatter.JsonFormatter.init(testing.allocator, formatter_options);

    // Verify they use the same indentation style
    try testing.expectEqual(indentation.IndentStyle.spaces_2, indent_engine.style);
    try testing.expectEqual(indentation.IndentStyle.spaces_2, formatter.options.indent_style);
}

test "Integration: ColorFormatter with JSON output" {
    const color_scheme = colors.JsonColorScheme.default();
    const color_formatter = colors.ColorFormatter.initWithEnabled(testing.allocator, color_scheme, true);

    // Test coloring different JSON elements
    const key_colored = try color_formatter.colorizeKey("\"name\"");
    defer testing.allocator.free(key_colored);
    try testing.expect(std.mem.indexOf(u8, key_colored, colors.AnsiCodes.CYAN) != null);

    const string_colored = try color_formatter.colorizeString("\"value\"");
    defer testing.allocator.free(string_colored);
    try testing.expect(std.mem.indexOf(u8, string_colored, colors.AnsiCodes.GREEN) != null);
}

test "Integration: All formatters work together" {
    // Create components
    const formatter_options = json_formatter.FormatOptions.default();
    var json_fmt = json_formatter.JsonFormatter.init(testing.allocator, formatter_options);

    const color_scheme = colors.JsonColorScheme.default();
    const color_fmt = colors.ColorFormatter.initWithEnabled(testing.allocator, color_scheme, true);

    // Format some JSON
    const json_result = try json_fmt.formatJsonString("{\"test\": \"value\"}");
    defer testing.allocator.free(json_result);

    // Apply colors to the result
    const colored_result = try color_fmt.colorizeString(json_result);
    defer testing.allocator.free(colored_result);

    // Verify the result contains both formatting and colors
    try testing.expect(std.mem.indexOf(u8, colored_result, colors.AnsiCodes.GREEN) != null);
    try testing.expect(std.mem.indexOf(u8, colored_result, "formatted") != null);
}

test "Integration: Indentation with different styles" {
    // Test different indentation styles work with formatter
    const styles = [_]indentation.IndentStyle{ .spaces_2, .spaces_4, .tabs };

    for (styles) |style| {
        const options = json_formatter.FormatOptions{
            .indent_style = style,
        };
        var formatter = json_formatter.JsonFormatter.init(testing.allocator, options);
        try testing.expectEqual(style, formatter.options.indent_style);
        try testing.expectEqual(style, formatter.indentation_engine.style);
    }
}

test "Integration: Error handling across components" {
    // Test that components handle errors gracefully
    const color_scheme = colors.JsonColorScheme.default();
    const color_formatter = colors.ColorFormatter.initWithEnabled(testing.allocator, color_scheme, true);

    // Test empty string handling
    const empty_colored = try color_formatter.colorizeString("");
    defer testing.allocator.free(empty_colored);
    try testing.expect(empty_colored.len > 0); // Should have color codes even for empty string
}
