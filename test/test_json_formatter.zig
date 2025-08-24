//! Test file for JSON formatter with inline dependencies
//! This allows us to test the formatter in isolation during TDD

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// Include necessary types from AST inline for testing
pub const Position = struct {
    line: u32,
    column: u32,

    pub fn init(line: u32, column: u32) Position {
        return Position{ .line = line, .column = column };
    }
};

pub const ValueType = enum {
    object,
    array,
    string,
    number,
    boolean,
    null,
};

// Simplified AST types for testing
pub const JsonValue = struct {
    type: ValueType,
    position: Position,
    data: Data,

    pub const Data = union(ValueType) {
        object: JsonObject,
        array: JsonArray,
        string: []const u8,
        number: []const u8,
        boolean: bool,
        null: void,
    };

    pub fn init(value_type: ValueType, position: Position, data: Data) JsonValue {
        return JsonValue{
            .type = value_type,
            .position = position,
            .data = data,
        };
    }

    pub fn createObject(allocator: Allocator, position: Position) !JsonValue {
        const object = JsonObject.init(allocator);
        return JsonValue{
            .type = .object,
            .position = position,
            .data = Data{ .object = object },
        };
    }

    pub fn createArray(allocator: Allocator, position: Position) !JsonValue {
        const array = JsonArray.init(allocator);
        return JsonValue{
            .type = .array,
            .position = position,
            .data = Data{ .array = array },
        };
    }

    pub fn createString(value: []const u8, position: Position) JsonValue {
        return JsonValue{
            .type = .string,
            .position = position,
            .data = Data{ .string = value },
        };
    }

    pub fn createNumber(value: []const u8, position: Position) JsonValue {
        return JsonValue{
            .type = .number,
            .position = position,
            .data = Data{ .number = value },
        };
    }

    pub fn createBoolean(value: bool, position: Position) JsonValue {
        return JsonValue{
            .type = .boolean,
            .position = position,
            .data = Data{ .boolean = value },
        };
    }

    pub fn createNull(position: Position) JsonValue {
        return JsonValue{
            .type = .null,
            .position = position,
            .data = Data{ .null = {} },
        };
    }

    pub fn deinit(self: *JsonValue) void {
        switch (self.data) {
            .object => |*obj| obj.deinit(),
            .array => |*arr| arr.deinit(),
            .string, .number => {},
            .boolean, .null => {},
        }
    }
};

pub const JsonObject = struct {
    entries: ArrayList(Entry),

    pub const Entry = struct {
        key: []const u8,
        value: JsonValue,
    };

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .entries = ArrayList(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| {
            entry.value.deinit();
        }
        self.entries.deinit();
    }

    pub fn set(self: *Self, key: []const u8, value: JsonValue) !void {
        // Simple implementation - just append
        try self.entries.append(Entry{
            .key = key,
            .value = value,
        });
    }

    pub fn get(self: *const Self, key: []const u8) ?*const JsonValue {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return &entry.value;
            }
        }
        return null;
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.entries.items.len == 0;
    }
};

pub const JsonArray = struct {
    elements: ArrayList(JsonValue),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .elements = ArrayList(JsonValue).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.elements.items) |*element| {
            element.deinit();
        }
        self.elements.deinit();
    }

    pub fn append(self: *Self, value: JsonValue) !void {
        try self.elements.append(value);
    }

    pub fn count(self: *const Self) usize {
        return self.elements.items.len;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.elements.items.len == 0;
    }
};

// Include indentation engine inline
pub const IndentStyle = enum {
    spaces_2,
    spaces_4,
    tabs,

    pub fn getString(self: IndentStyle) []const u8 {
        return switch (self) {
            .spaces_2 => "  ",
            .spaces_4 => "    ",
            .tabs => "\t",
        };
    }

    pub fn getWidth(self: IndentStyle) u32 {
        return switch (self) {
            .spaces_2 => 2,
            .spaces_4 => 4,
            .tabs => 4,
        };
    }
};

pub const IndentationEngine = struct {
    style: IndentStyle,
    current_depth: u32,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, style: IndentStyle) Self {
        return Self{
            .style = style,
            .current_depth = 0,
            .allocator = allocator,
        };
    }

    pub fn indent(self: *Self) void {
        self.current_depth += 1;
    }

    pub fn dedent(self: *Self) void {
        if (self.current_depth > 0) {
            self.current_depth -= 1;
        }
    }

    pub fn getDepth(self: *const Self) u32 {
        return self.current_depth;
    }

    pub fn reset(self: *Self) void {
        self.current_depth = 0;
    }

    pub fn generateString(self: *const Self) ![]u8 {
        if (self.current_depth == 0) {
            return try self.allocator.dupe(u8, "");
        }

        const single_indent = self.style.getString();
        const total_len = single_indent.len * self.current_depth;

        var result = try self.allocator.alloc(u8, total_len);

        var pos: usize = 0;
        for (0..self.current_depth) |_| {
            @memcpy(result[pos .. pos + single_indent.len], single_indent);
            pos += single_indent.len;
        }

        return result;
    }

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

// Now include the JSON formatter
pub const FormatOptions = struct {
    indent_style: IndentStyle = .spaces_2,
    compact_arrays: bool = false,
    compact_objects: bool = false,
    compact_threshold: usize = 3,
    escape_unicode: bool = true,
    sort_object_keys: bool = false,

    pub fn default() FormatOptions {
        return FormatOptions{};
    }

    pub fn compact() FormatOptions {
        return FormatOptions{
            .compact_arrays = true,
            .compact_objects = true,
            .compact_threshold = 5,
        };
    }
};

pub const JsonFormatter = struct {
    allocator: Allocator,
    options: FormatOptions,
    indentation_engine: IndentationEngine,

    const Self = @This();

    pub fn init(allocator: Allocator, options: FormatOptions) Self {
        return Self{
            .allocator = allocator,
            .options = options,
            .indentation_engine = IndentationEngine.init(allocator, options.indent_style),
        };
    }

    pub fn formatValue(self: *Self, value: *const JsonValue) ![]u8 {
        var result = ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        self.indentation_engine.reset();
        try self.formatValueInternal(value, &result);

        return try result.toOwnedSlice();
    }

    fn formatValueInternal(self: *Self, value: *const JsonValue, writer: *ArrayList(u8)) error{OutOfMemory}!void {
        switch (value.type) {
            .object => try self.formatObject(&value.data.object, writer),
            .array => try self.formatArray(&value.data.array, writer),
            .string => try self.formatString(value.data.string, writer),
            .number => try self.formatNumber(value.data.number, writer),
            .boolean => try self.formatBoolean(value.data.boolean, writer),
            .null => try self.formatNull(writer),
        }
    }

    fn formatObject(self: *Self, object: *const JsonObject, writer: *ArrayList(u8)) error{OutOfMemory}!void {
        if (object.isEmpty()) {
            try writer.appendSlice("{}");
            return;
        }

        const should_compact = self.options.compact_objects and
            object.count() <= self.options.compact_threshold;

        try writer.append('{');

        if (!should_compact) {
            try writer.append('\n');
            self.indentation_engine.indent();
        }

        var entries = object.entries.items;
        var sorted_entries: []JsonObject.Entry = undefined;
        var sorted_allocator: ?Allocator = null;

        if (self.options.sort_object_keys and entries.len > 1) {
            sorted_entries = try self.allocator.dupe(JsonObject.Entry, entries);
            sorted_allocator = self.allocator;

            std.sort.heap(JsonObject.Entry, sorted_entries, {}, struct {
                fn lessThan(_: void, a: JsonObject.Entry, b: JsonObject.Entry) bool {
                    return std.mem.lessThan(u8, a.key, b.key);
                }
            }.lessThan);

            entries = sorted_entries;
        }
        defer if (sorted_allocator) |alloc| alloc.free(sorted_entries);

        for (entries, 0..) |entry, i| {
            if (!should_compact) {
                const indent_str = try self.indentation_engine.generateString();
                defer self.allocator.free(indent_str);
                try writer.appendSlice(indent_str);
            } else if (i > 0) {
                try writer.append(' ');
            }

            try writer.append('"');
            try self.escapeString(entry.key, writer);
            try writer.append('"');
            try writer.append(':');

            if (!should_compact) {
                try writer.append(' ');
            }

            try self.formatValueInternal(&entry.value, writer);

            if (i < entries.len - 1) {
                try writer.append(',');
            }

            if (!should_compact) {
                try writer.append('\n');
            }
        }

        if (!should_compact) {
            self.indentation_engine.dedent();
            const indent_str = try self.indentation_engine.generateString();
            defer self.allocator.free(indent_str);
            try writer.appendSlice(indent_str);
        }

        try writer.append('}');
    }

    fn formatArray(self: *Self, array: *const JsonArray, writer: *ArrayList(u8)) error{OutOfMemory}!void {
        if (array.isEmpty()) {
            try writer.appendSlice("[]");
            return;
        }

        const should_compact = self.options.compact_arrays and
            array.count() <= self.options.compact_threshold and
            self.isArraySimple(array);

        try writer.append('[');

        if (!should_compact) {
            try writer.append('\n');
            self.indentation_engine.indent();
        } else {
            // Add space after opening bracket in compact mode
            try writer.append(' ');
        }

        for (array.elements.items, 0..) |*element, i| {
            if (!should_compact) {
                const indent_str = try self.indentation_engine.generateString();
                defer self.allocator.free(indent_str);
                try writer.appendSlice(indent_str);
            } else if (i > 0) {
                try writer.append(' ');
            }

            try self.formatValueInternal(element, writer);

            if (i < array.elements.items.len - 1) {
                try writer.append(',');
            }

            if (!should_compact) {
                try writer.append('\n');
            }
        }

        if (!should_compact) {
            self.indentation_engine.dedent();
            const indent_str = try self.indentation_engine.generateString();
            defer self.allocator.free(indent_str);
            try writer.appendSlice(indent_str);
        } else {
            // Add space before closing bracket in compact mode
            try writer.append(' ');
        }

        try writer.append(']');
    }

    fn isArraySimple(self: *const Self, array: *const JsonArray) bool {
        _ = self;
        for (array.elements.items) |*element| {
            switch (element.type) {
                .object, .array => return false,
                .string => {
                    if (element.data.string.len > 20) return false;
                },
                .number, .boolean, .null => {},
            }
        }
        return true;
    }

    fn formatString(self: *Self, value: []const u8, writer: *ArrayList(u8)) error{OutOfMemory}!void {
        try writer.append('"');
        try self.escapeString(value, writer);
        try writer.append('"');
    }

    fn escapeString(self: *Self, value: []const u8, writer: *ArrayList(u8)) error{OutOfMemory}!void {
        for (value) |char| {
            switch (char) {
                '"' => try writer.appendSlice("\\\""),
                '\\' => try writer.appendSlice("\\\\"),
                '\n' => try writer.appendSlice("\\n"),
                '\r' => try writer.appendSlice("\\r"),
                '\t' => try writer.appendSlice("\\t"),
                '\x08' => try writer.appendSlice("\\b"),
                '\x0C' => try writer.appendSlice("\\f"),
                0x00...0x07, 0x0B, 0x0E...0x1F => {
                    // Other control characters (excluding those handled above)
                    try writer.writer().print("\\u{x:0>4}", .{@as(u32, char)});
                },
                0x80...0xFF => {
                    if (self.options.escape_unicode) {
                        try writer.writer().print("\\u{x:0>4}", .{@as(u32, char)});
                    } else {
                        try writer.append(char);
                    }
                },
                else => try writer.append(char),
            }
        }
    }

    fn formatNumber(self: *Self, value: []const u8, writer: *ArrayList(u8)) error{OutOfMemory}!void {
        _ = self;
        try writer.appendSlice(value);
    }

    fn formatBoolean(self: *Self, value: bool, writer: *ArrayList(u8)) error{OutOfMemory}!void {
        _ = self;
        if (value) {
            try writer.appendSlice("true");
        } else {
            try writer.appendSlice("false");
        }
    }

    fn formatNull(self: *Self, writer: *ArrayList(u8)) error{OutOfMemory}!void {
        _ = self;
        try writer.appendSlice("null");
    }

    pub fn hasTrailingWhitespace(formatted: []const u8) bool {
        return IndentationEngine.hasTrailingWhitespace(undefined, formatted);
    }
};

// Helper function to create test data
fn createTestPosition() Position {
    return Position.init(1, 1);
}

// ================================
// TESTS
// ================================

test "FormatOptions default values" {
    const options = FormatOptions.default();

    try testing.expectEqual(IndentStyle.spaces_2, options.indent_style);
    try testing.expectEqual(false, options.compact_arrays);
    try testing.expectEqual(false, options.compact_objects);
    try testing.expectEqual(@as(usize, 3), options.compact_threshold);
    try testing.expectEqual(true, options.escape_unicode);
    try testing.expectEqual(false, options.sort_object_keys);
}

test "FormatOptions compact values" {
    const options = FormatOptions.compact();

    try testing.expectEqual(true, options.compact_arrays);
    try testing.expectEqual(true, options.compact_objects);
    try testing.expectEqual(@as(usize, 5), options.compact_threshold);
}

test "JsonFormatter init creates formatter correctly" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    try testing.expectEqual(IndentStyle.spaces_2, formatter.options.indent_style);
    try testing.expectEqual(@as(u32, 0), formatter.indentation_engine.getDepth());
}

test "JsonFormatter formatValue null value" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    const null_value = JsonValue.createNull(createTestPosition());
    const formatted = try formatter.formatValue(&null_value);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("null", formatted);
}

test "JsonFormatter formatValue boolean values" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    // Test true
    const true_value = JsonValue.createBoolean(true, createTestPosition());
    const true_formatted = try formatter.formatValue(&true_value);
    defer testing.allocator.free(true_formatted);
    try testing.expectEqualStrings("true", true_formatted);

    // Test false
    const false_value = JsonValue.createBoolean(false, createTestPosition());
    const false_formatted = try formatter.formatValue(&false_value);
    defer testing.allocator.free(false_formatted);
    try testing.expectEqualStrings("false", false_formatted);
}

test "JsonFormatter formatValue number values" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    // Test integer
    const int_value = JsonValue.createNumber("42", createTestPosition());
    const int_formatted = try formatter.formatValue(&int_value);
    defer testing.allocator.free(int_formatted);
    try testing.expectEqualStrings("42", int_formatted);

    // Test float
    const float_value = JsonValue.createNumber("3.14159", createTestPosition());
    const float_formatted = try formatter.formatValue(&float_value);
    defer testing.allocator.free(float_formatted);
    try testing.expectEqualStrings("3.14159", float_formatted);

    // Test scientific notation
    const sci_value = JsonValue.createNumber("1.23e-4", createTestPosition());
    const sci_formatted = try formatter.formatValue(&sci_value);
    defer testing.allocator.free(sci_formatted);
    try testing.expectEqualStrings("1.23e-4", sci_formatted);
}

test "JsonFormatter formatValue simple string" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    const string_value = JsonValue.createString("hello world", createTestPosition());
    const formatted = try formatter.formatValue(&string_value);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("\"hello world\"", formatted);
}

test "JsonFormatter formatValue string with escaping" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    const string_value = JsonValue.createString("hello\n\"world\"\t\\test", createTestPosition());
    const formatted = try formatter.formatValue(&string_value);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("\"hello\\n\\\"world\\\"\\t\\\\test\"", formatted);
}

test "JsonFormatter formatValue string with control characters" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    // Test control characters
    const control_chars = "\x00\x01\x08\x0C\x1F";
    const string_value = JsonValue.createString(control_chars, createTestPosition());
    const formatted = try formatter.formatValue(&string_value);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("\"\\u0000\\u0001\\b\\f\\u001f\"", formatted);
}

test "JsonFormatter formatValue empty array" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    const array_value = try JsonValue.createArray(testing.allocator, createTestPosition());
    defer {
        var mutable_value = array_value;
        mutable_value.deinit();
    }

    const formatted = try formatter.formatValue(&array_value);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("[]", formatted);
}

test "JsonFormatter formatValue simple array pretty-printed" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    var array_value = try JsonValue.createArray(testing.allocator, createTestPosition());
    defer array_value.deinit();

    // Add elements to array
    try array_value.data.array.append(JsonValue.createNumber("1", createTestPosition()));
    try array_value.data.array.append(JsonValue.createNumber("2", createTestPosition()));
    try array_value.data.array.append(JsonValue.createNumber("3", createTestPosition()));

    const formatted = try formatter.formatValue(&array_value);
    defer testing.allocator.free(formatted);

    const expected =
        \\[
        \\  1,
        \\  2,
        \\  3
        \\]
    ;

    try testing.expectEqualStrings(expected, formatted);
}

test "JsonFormatter formatValue simple array compact" {
    const options = FormatOptions.compact();
    var formatter = JsonFormatter.init(testing.allocator, options);

    var array_value = try JsonValue.createArray(testing.allocator, createTestPosition());
    defer array_value.deinit();

    // Add elements to array (simple values, under threshold)
    try array_value.data.array.append(JsonValue.createNumber("1", createTestPosition()));
    try array_value.data.array.append(JsonValue.createNumber("2", createTestPosition()));
    try array_value.data.array.append(JsonValue.createNumber("3", createTestPosition()));

    const formatted = try formatter.formatValue(&array_value);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("[ 1, 2, 3 ]", formatted);
}

test "JsonFormatter formatValue empty object" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    const object_value = try JsonValue.createObject(testing.allocator, createTestPosition());
    defer {
        var mutable_value = object_value;
        mutable_value.deinit();
    }

    const formatted = try formatter.formatValue(&object_value);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("{}", formatted);
}

test "JsonFormatter formatValue simple object pretty-printed" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    var object_value = try JsonValue.createObject(testing.allocator, createTestPosition());
    defer object_value.deinit();

    // Add key-value pairs
    try object_value.data.object.set("name", JsonValue.createString("test", createTestPosition()));
    try object_value.data.object.set("value", JsonValue.createNumber("42", createTestPosition()));
    try object_value.data.object.set("active", JsonValue.createBoolean(true, createTestPosition()));

    const formatted = try formatter.formatValue(&object_value);
    defer testing.allocator.free(formatted);

    // Check that it's properly formatted with newlines and indentation
    try testing.expect(std.mem.startsWith(u8, formatted, "{"));
    try testing.expect(std.mem.endsWith(u8, formatted, "}"));
    try testing.expect(std.mem.indexOf(u8, formatted, "\n") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"name\": \"test\"") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"value\": 42") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"active\": true") != null);
}

test "JsonFormatter formatValue object with sorted keys" {
    const options = FormatOptions{
        .sort_object_keys = true,
    };
    var formatter = JsonFormatter.init(testing.allocator, options);

    var object_value = try JsonValue.createObject(testing.allocator, createTestPosition());
    defer object_value.deinit();

    // Add keys in non-alphabetical order
    try object_value.data.object.set("zebra", JsonValue.createString("z", createTestPosition()));
    try object_value.data.object.set("apple", JsonValue.createString("a", createTestPosition()));
    try object_value.data.object.set("banana", JsonValue.createString("b", createTestPosition()));

    const formatted = try formatter.formatValue(&object_value);
    defer testing.allocator.free(formatted);

    // Should be sorted: apple, banana, zebra
    const apple_pos = std.mem.indexOf(u8, formatted, "\"apple\"").?;
    const banana_pos = std.mem.indexOf(u8, formatted, "\"banana\"").?;
    const zebra_pos = std.mem.indexOf(u8, formatted, "\"zebra\"").?;

    try testing.expect(apple_pos < banana_pos);
    try testing.expect(banana_pos < zebra_pos);
}

test "JsonFormatter formatValue nested object" {
    const options = FormatOptions.default();
    var formatter = JsonFormatter.init(testing.allocator, options);

    // Create nested structure
    var root_obj = try JsonValue.createObject(testing.allocator, createTestPosition());
    defer root_obj.deinit();

    var nested_obj = try JsonValue.createObject(testing.allocator, createTestPosition());
    try nested_obj.data.object.set("inner", JsonValue.createString("value", createTestPosition()));

    try root_obj.data.object.set("outer", nested_obj);
    try root_obj.data.object.set("simple", JsonValue.createNumber("123", createTestPosition()));

    const formatted = try formatter.formatValue(&root_obj);
    defer testing.allocator.free(formatted);

    // Check basic structure
    try testing.expect(std.mem.indexOf(u8, formatted, "\"outer\":") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"inner\": \"value\"") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"simple\": 123") != null);

    // Should have proper nesting with increased indentation
    try testing.expect(std.mem.indexOf(u8, formatted, "    \"inner\"") != null);
}

test "JsonFormatter hasTrailingWhitespace detection" {
    // No trailing whitespace
    try testing.expect(!JsonFormatter.hasTrailingWhitespace("{\"test\": \"value\"}"));
    try testing.expect(!JsonFormatter.hasTrailingWhitespace("[]"));

    // Has trailing whitespace
    try testing.expect(JsonFormatter.hasTrailingWhitespace("{\"test\": \"value\"} "));
    try testing.expect(JsonFormatter.hasTrailingWhitespace("{\n  \"test\": \"value\" \n}"));
}
