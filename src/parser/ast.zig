//! JSON Abstract Syntax Tree (AST) for CC Streamer
//! 
//! This module defines the AST node structures for representing parsed JSON data.
//! It supports:
//! - All JSON value types (objects, arrays, strings, numbers, booleans, null)
//! - Memory-efficient representation with streaming in mind  
//! - Position tracking for error reporting
//! - Node creation and manipulation functions

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;

/// Position information for AST nodes (for error reporting)
pub const Position = struct {
    line: u32,
    column: u32,
    
    pub fn init(line: u32, column: u32) Position {
        return Position{ .line = line, .column = column };
    }
};

/// JSON value types
pub const ValueType = enum {
    object,
    array,
    string,
    number,
    boolean,
    null,
};

/// Forward declaration for recursive JSON values
pub const JsonValue = struct {
    type: ValueType,
    position: Position,
    data: Data,
    
    /// Union containing the actual value data
    pub const Data = union(ValueType) {
        object: JsonObject,
        array: JsonArray, 
        string: []const u8,
        number: []const u8, // Raw number string for precise representation
        boolean: bool,
        null: void,
    };
    
    /// Create a new JSON value
    pub fn init(value_type: ValueType, position: Position, data: Data) JsonValue {
        return JsonValue{
            .type = value_type,
            .position = position,
            .data = data,
        };
    }
    
    /// Create a JSON object value
    pub fn createObject(allocator: Allocator, position: Position) !JsonValue {
        const object = JsonObject.init(allocator);
        return JsonValue{
            .type = .object,
            .position = position,
            .data = Data{ .object = object },
        };
    }
    
    /// Create a JSON array value
    pub fn createArray(allocator: Allocator, position: Position) !JsonValue {
        const array = JsonArray.init(allocator);
        return JsonValue{
            .type = .array,
            .position = position,
            .data = Data{ .array = array },
        };
    }
    
    /// Create a JSON string value
    pub fn createString(value: []const u8, position: Position) JsonValue {
        return JsonValue{
            .type = .string,
            .position = position,
            .data = Data{ .string = value },
        };
    }
    
    /// Create a JSON number value
    pub fn createNumber(value: []const u8, position: Position) JsonValue {
        return JsonValue{
            .type = .number,
            .position = position,
            .data = Data{ .number = value },
        };
    }
    
    /// Create a JSON boolean value
    pub fn createBoolean(value: bool, position: Position) JsonValue {
        return JsonValue{
            .type = .boolean,
            .position = position,
            .data = Data{ .boolean = value },
        };
    }
    
    /// Create a JSON null value
    pub fn createNull(position: Position) JsonValue {
        return JsonValue{
            .type = .null,
            .position = position,
            .data = Data{ .null = {} },
        };
    }
    
    /// Free all memory associated with this value
    pub fn deinit(self: *JsonValue, allocator: Allocator) void {
        _ = allocator; // For potential future use
        switch (self.data) {
            .object => |*obj| obj.deinit(),
            .array => |*arr| arr.deinit(),
            .string, .number => {}, // String slices don't own memory
            .boolean, .null => {},
        }
    }
    
    /// Get string representation of the value type
    pub fn getTypeName(self: *const JsonValue) []const u8 {
        return switch (self.type) {
            .object => "object",
            .array => "array",
            .string => "string",
            .number => "number",
            .boolean => "boolean",
            .null => "null",
        };
    }
};

/// JSON object representation (key-value pairs)
pub const JsonObject = struct {
    entries: ArrayList(Entry),
    
    /// Object entry (key-value pair)
    pub const Entry = struct {
        key: []const u8,
        value: JsonValue,
        
        pub fn init(key: []const u8, value: JsonValue) Entry {
            return Entry{ .key = key, .value = value };
        }
    };
    
    const Self = @This();
    
    /// Initialize a new empty JSON object
    pub fn init(allocator: Allocator) Self {
        return Self{
            .entries = ArrayList(Entry).init(allocator),
        };
    }
    
    /// Free all memory associated with this object
    pub fn deinit(self: *Self) void {
        // Free all values in the object
        for (self.entries.items) |*entry| {
            // Note: We don't own the key strings, they reference the input
            entry.value.deinit(self.entries.allocator);
        }
        self.entries.deinit();
    }
    
    /// Add a key-value pair to the object
    pub fn put(self: *Self, key: []const u8, value: JsonValue) !void {
        const entry = Entry.init(key, value);
        try self.entries.append(entry);
    }
    
    /// Get a value by key (returns null if not found)
    pub fn get(self: *const Self, key: []const u8) ?*const JsonValue {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return &entry.value;
            }
        }
        return null;
    }
    
    /// Get number of key-value pairs
    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }
    
    /// Check if object is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.entries.items.len == 0;
    }
};

/// JSON array representation
pub const JsonArray = struct {
    elements: ArrayList(JsonValue),
    
    const Self = @This();
    
    /// Initialize a new empty JSON array
    pub fn init(allocator: Allocator) Self {
        return Self{
            .elements = ArrayList(JsonValue).init(allocator),
        };
    }
    
    /// Free all memory associated with this array
    pub fn deinit(self: *Self) void {
        // Free all values in the array
        for (self.elements.items) |*element| {
            element.deinit(self.elements.allocator);
        }
        self.elements.deinit();
    }
    
    /// Add an element to the array
    pub fn append(self: *Self, value: JsonValue) !void {
        try self.elements.append(value);
    }
    
    /// Get an element by index (returns null if out of bounds)
    pub fn get(self: *const Self, index: usize) ?*const JsonValue {
        if (index >= self.elements.items.len) {
            return null;
        }
        return &self.elements.items[index];
    }
    
    /// Get number of elements
    pub fn count(self: *const Self) usize {
        return self.elements.items.len;
    }
    
    /// Check if array is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.elements.items.len == 0;
    }
};

// ============================================================================
// TESTS - Following TDD, these are written first
// ============================================================================

test "Position creation" {
    const pos = Position.init(10, 5);
    try testing.expectEqual(@as(u32, 10), pos.line);
    try testing.expectEqual(@as(u32, 5), pos.column);
}

test "Create JSON string value" {
    const pos = Position.init(1, 1);
    const value = JsonValue.createString("hello", pos);
    
    try testing.expectEqual(ValueType.string, value.type);
    try testing.expectEqualStrings("hello", value.data.string);
    try testing.expectEqual(@as(u32, 1), value.position.line);
    try testing.expectEqual(@as(u32, 1), value.position.column);
}

test "Create JSON number value" {
    const pos = Position.init(1, 1);
    const value = JsonValue.createNumber("123.45", pos);
    
    try testing.expectEqual(ValueType.number, value.type);
    try testing.expectEqualStrings("123.45", value.data.number);
}

test "Create JSON boolean values" {
    const pos = Position.init(1, 1);
    
    const true_value = JsonValue.createBoolean(true, pos);
    try testing.expectEqual(ValueType.boolean, true_value.type);
    try testing.expect(true_value.data.boolean);
    
    const false_value = JsonValue.createBoolean(false, pos);
    try testing.expectEqual(ValueType.boolean, false_value.type);
    try testing.expect(!false_value.data.boolean);
}

test "Create JSON null value" {
    const pos = Position.init(1, 1);
    const value = JsonValue.createNull(pos);
    
    try testing.expectEqual(ValueType.null, value.type);
}

test "JsonValue getTypeName" {
    const pos = Position.init(1, 1);
    
    const string_val = JsonValue.createString("test", pos);
    try testing.expectEqualStrings("string", string_val.getTypeName());
    
    const number_val = JsonValue.createNumber("123", pos);
    try testing.expectEqualStrings("number", number_val.getTypeName());
    
    const bool_val = JsonValue.createBoolean(true, pos);
    try testing.expectEqualStrings("boolean", bool_val.getTypeName());
    
    const null_val = JsonValue.createNull(pos);
    try testing.expectEqualStrings("null", null_val.getTypeName());
}

test "JsonObject initialization and basic operations" {
    var object = JsonObject.init(testing.allocator);
    defer object.deinit();
    
    try testing.expect(object.isEmpty());
    try testing.expectEqual(@as(usize, 0), object.count());
}

test "JsonObject put and get operations" {
    var object = JsonObject.init(testing.allocator);
    defer object.deinit();
    
    const pos = Position.init(1, 1);
    const string_val = JsonValue.createString("test_value", pos);
    
    try object.put("test_key", string_val);
    
    try testing.expectEqual(@as(usize, 1), object.count());
    try testing.expect(!object.isEmpty());
    
    const retrieved = object.get("test_key");
    try testing.expect(retrieved != null);
    try testing.expectEqual(ValueType.string, retrieved.?.type);
    try testing.expectEqualStrings("test_value", retrieved.?.data.string);
    
    // Test non-existent key
    const not_found = object.get("non_existent");
    try testing.expect(not_found == null);
}

test "JsonArray initialization and basic operations" {
    var array = JsonArray.init(testing.allocator);
    defer array.deinit();
    
    try testing.expect(array.isEmpty());
    try testing.expectEqual(@as(usize, 0), array.count());
}

test "JsonArray append and get operations" {
    var array = JsonArray.init(testing.allocator);
    defer array.deinit();
    
    const pos = Position.init(1, 1);
    const number_val = JsonValue.createNumber("42", pos);
    const string_val = JsonValue.createString("hello", pos);
    
    try array.append(number_val);
    try array.append(string_val);
    
    try testing.expectEqual(@as(usize, 2), array.count());
    try testing.expect(!array.isEmpty());
    
    const first = array.get(0);
    try testing.expect(first != null);
    try testing.expectEqual(ValueType.number, first.?.type);
    try testing.expectEqualStrings("42", first.?.data.number);
    
    const second = array.get(1);
    try testing.expect(second != null);
    try testing.expectEqual(ValueType.string, second.?.type);
    try testing.expectEqualStrings("hello", second.?.data.string);
    
    // Test out of bounds
    const out_of_bounds = array.get(2);
    try testing.expect(out_of_bounds == null);
}

test "Create JSON object value" {
    const pos = Position.init(1, 1);
    var obj_value = try JsonValue.createObject(testing.allocator, pos);
    defer obj_value.deinit(testing.allocator);
    
    try testing.expectEqual(ValueType.object, obj_value.type);
    try testing.expect(obj_value.data.object.isEmpty());
}

test "Create JSON array value" {
    const pos = Position.init(1, 1);
    var array_value = try JsonValue.createArray(testing.allocator, pos);
    defer array_value.deinit(testing.allocator);
    
    try testing.expectEqual(ValueType.array, array_value.type);
    try testing.expect(array_value.data.array.isEmpty());
}

test "Complex nested structure" {
    const pos = Position.init(1, 1);
    
    // Create a nested structure: {"numbers": [1, 2, 3], "active": true}
    var root_object = try JsonValue.createObject(testing.allocator, pos);
    defer root_object.deinit(testing.allocator);
    
    // Create array with numbers
    var numbers_array = try JsonValue.createArray(testing.allocator, pos);
    try numbers_array.data.array.append(JsonValue.createNumber("1", pos));
    try numbers_array.data.array.append(JsonValue.createNumber("2", pos));
    try numbers_array.data.array.append(JsonValue.createNumber("3", pos));
    
    // Add entries to root object
    try root_object.data.object.put("numbers", numbers_array);
    try root_object.data.object.put("active", JsonValue.createBoolean(true, pos));
    
    // Test the structure
    try testing.expectEqual(@as(usize, 2), root_object.data.object.count());
    
    const numbers = root_object.data.object.get("numbers");
    try testing.expect(numbers != null);
    try testing.expectEqual(ValueType.array, numbers.?.type);
    try testing.expectEqual(@as(usize, 3), numbers.?.data.array.count());
    
    const first_num = numbers.?.data.array.get(0);
    try testing.expect(first_num != null);
    try testing.expectEqualStrings("1", first_num.?.data.number);
}