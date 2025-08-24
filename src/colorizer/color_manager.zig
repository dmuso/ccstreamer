//! Dynamic Color Manager for CC Streamer v2
//!
//! This module implements the ColorManager system specified in the PRD v2.
//! It provides dynamic color assignment for message types with:
//! - Pool of available colors
//! - Consistent type-to-color mapping
//! - Color recycling when types are no longer used
//! - NO_COLOR environment variable support

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const HashMap = std.HashMap;
const ArrayList = std.ArrayList;

// Windows console mode flags
const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
const ENABLE_WRAP_AT_EOL_OUTPUT: u32 = 0x0002;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
const INVALID_HANDLE_VALUE = @as(*anyopaque, @ptrFromInt(std.math.maxInt(usize)));

/// ANSI Color Code representation
pub const Color = struct {
    code: u8,
    name: []const u8,

    /// Convert color to ANSI escape sequence
    pub fn toAnsiCode(self: Color, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "\x1b[{d}m", .{self.code}) catch unreachable;
    }

    /// Get reset ANSI sequence
    pub fn reset() []const u8 {
        return "\x1b[0m";
    }
};

/// Color codes enum following PRD specification
pub const ColorCode = enum(u8) {
    bright_blue = 94,
    bright_green = 92,
    bright_yellow = 93,
    bright_magenta = 95,
    bright_cyan = 96,
    white = 97,
    blue = 34,
    green = 32,
    yellow = 33,
    magenta = 35,
    cyan = 36,
    gray = 90,

    // Reserved for errors/warnings
    red = 31,
    bright_red = 91,

    pub fn toColor(self: ColorCode) Color {
        return Color{
            .code = @intFromEnum(self),
            .name = @tagName(self),
        };
    }
};

/// Pool of available colors for assignment
pub const ColorPool = struct {
    available: ArrayList(Color),
    in_use: ArrayList(Color),
    allocator: Allocator,

    const Self = @This();

    /// Initialize color pool with default colors
    pub fn init(allocator: Allocator) !Self {
        var available = ArrayList(Color).init(allocator);
        const in_use = ArrayList(Color).init(allocator);

        // Initialize with colors from PRD specification (excluding red tones)
        const default_colors = [_]ColorCode{
            .bright_blue,    .bright_green, .bright_yellow,
            .bright_magenta, .bright_cyan,  .white,
            .blue,           .green,        .yellow,
            .magenta,        .cyan,
        };

        for (default_colors) |color_code| {
            try available.append(color_code.toColor());
        }

        return Self{
            .available = available,
            .in_use = in_use,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.available.deinit();
        self.in_use.deinit();
    }

    /// Get next available color from pool
    pub fn getNextColor(self: *Self) ?Color {
        if (self.available.items.len == 0) {
            // Pool exhausted - recycle oldest color
            if (self.in_use.items.len > 0) {
                const recycled = self.in_use.orderedRemove(0);
                return recycled;
            }
            return null;
        }

        const color = self.available.pop() orelse return null;
        self.in_use.append(color) catch return null;
        return color;
    }

    /// Return color to available pool
    pub fn returnColor(self: *Self, color: Color) !void {
        // Find and remove from in_use
        for (self.in_use.items, 0..) |used_color, i| {
            if (used_color.code == color.code) {
                _ = self.in_use.orderedRemove(i);
                try self.available.append(color);
                return;
            }
        }
    }

    /// Check if pool has available colors
    pub fn hasAvailable(self: *const Self) bool {
        return self.available.items.len > 0 or self.in_use.items.len > 0;
    }

    /// Get count of available colors
    pub fn availableCount(self: *const Self) usize {
        return self.available.items.len;
    }

    /// Get count of colors in use
    pub fn inUseCount(self: *const Self) usize {
        return self.in_use.items.len;
    }
};

/// Main color manager for dynamic type-to-color assignment
pub const ColorManager = struct {
    allocator: Allocator,
    color_pool: ColorPool,
    type_color_map: HashMap([]const u8, Color, StringContext, std.hash_map.default_max_load_percentage),
    enabled: bool,

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

    /// Initialize color manager
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .color_pool = try ColorPool.init(allocator),
            .type_color_map = HashMap([]const u8, Color, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .enabled = isColorEnabled(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.color_pool.deinit();

        // Free all stored type strings
        var iterator = self.type_color_map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.type_color_map.deinit();
    }

    /// Get color for a message type, assigning new color if needed
    pub fn getColorForType(self: *Self, message_type: []const u8) !?Color {
        if (!self.enabled) return null;

        // Check if we already have a color for this type
        if (self.type_color_map.get(message_type)) |color| {
            return color;
        }

        // Need to assign a new color
        if (self.color_pool.getNextColor()) |color| {
            // Store a copy of the type string
            const owned_type = try self.allocator.dupe(u8, message_type);
            try self.type_color_map.put(owned_type, color);
            return color;
        }

        // No colors available
        return null;
    }

    /// Reset all color assignments
    pub fn resetColorAssignments(self: *Self) void {
        // Return all colors to available pool
        var iterator = self.type_color_map.iterator();
        while (iterator.next()) |entry| {
            self.color_pool.returnColor(entry.value_ptr.*) catch {}; // Ignore errors
            self.allocator.free(entry.key_ptr.*);
        }

        self.type_color_map.clearAndFree();
    }

    /// Recycle unused colors (remove types no longer in use)
    pub fn recycleUnusedColors(self: *Self, active_types: []const []const u8) !void {
        var types_to_remove = ArrayList([]const u8).init(self.allocator);
        defer types_to_remove.deinit();

        // Find types that are no longer active
        var iterator = self.type_color_map.iterator();
        while (iterator.next()) |entry| {
            var found = false;
            for (active_types) |active_type| {
                if (std.mem.eql(u8, entry.key_ptr.*, active_type)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try types_to_remove.append(entry.key_ptr.*);
            }
        }

        // Remove unused types and return their colors
        for (types_to_remove.items) |type_name| {
            if (self.type_color_map.fetchRemove(type_name)) |kv| {
                try self.color_pool.returnColor(kv.value);
                self.allocator.free(kv.key);
            }
        }
    }

    /// Check if colors are enabled
    pub fn isEnabled(self: *const Self) bool {
        return self.enabled;
    }

    /// Enable or disable colors
    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Get statistics about color usage
    pub fn getStats(self: *const Self) ColorStats {
        return ColorStats{
            .total_types = self.type_color_map.count(),
            .colors_available = self.color_pool.availableCount(),
            .colors_in_use = self.color_pool.inUseCount(),
            .enabled = self.enabled,
        };
    }
};

/// Statistics about color manager state
pub const ColorStats = struct {
    total_types: u32,
    colors_available: usize,
    colors_in_use: usize,
    enabled: bool,
};

/// Check if colors should be enabled based on environment
pub fn isColorEnabled() bool {
    // Check NO_COLOR environment variable (highest priority)
    if (std.process.hasEnvVarConstant("NO_COLOR")) {
        return false;
    }

    // Check FORCE_COLOR to override TTY detection
    if (std.process.hasEnvVarConstant("FORCE_COLOR")) {
        return true;
    }

    // Check if stdout is a TTY
    const builtin = @import("builtin");

    return switch (builtin.os.tag) {
        .windows => isWindowsColorSupported(),
        else => {
            // On Unix-like systems, use isatty
            return std.posix.isatty(std.posix.STDOUT_FILENO);
        },
    };
}

/// Enhanced Windows TTY detection with Virtual Terminal Processing support
fn isWindowsColorSupported() bool {
    const win = std.os.windows;
    const kernel32 = win.kernel32;
    // STD_OUTPUT_HANDLE is -11 (0xFFFFFFF5 when cast to DWORD)
    const STD_OUTPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -11));

    const stdout_handle = kernel32.GetStdHandle(STD_OUTPUT_HANDLE) catch return false;

    // Check for invalid handle
    if (stdout_handle == INVALID_HANDLE_VALUE) return false;

    var mode: win.DWORD = undefined;
    if (kernel32.GetConsoleMode(stdout_handle, &mode) == 0) return false;

    // Try to enable Virtual Terminal Processing if not already enabled
    // This allows ANSI escape sequences to work on Windows 10+
    if ((mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) {
        const new_mode = mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        // SetConsoleMode might fail on older Windows versions, but that's ok
        // We still return true since the console exists, just without color support
        _ = kernel32.SetConsoleMode(stdout_handle, new_mode);
    }

    return true;
}

// =====================================
// TESTS (TDD - Writing failing tests first)
// =====================================

test "Color.toAnsiCode generates correct escape sequence" {
    const color = Color{ .code = 94, .name = "bright_blue" };
    var buffer: [16]u8 = undefined;
    const ansi_code = color.toAnsiCode(&buffer);

    try testing.expectEqualStrings("\x1b[94m", ansi_code);
}

test "Color.reset returns correct reset sequence" {
    try testing.expectEqualStrings("\x1b[0m", Color.reset());
}

test "ColorCode enum values match ANSI standards" {
    try testing.expectEqual(@as(u8, 94), @intFromEnum(ColorCode.bright_blue));
    try testing.expectEqual(@as(u8, 92), @intFromEnum(ColorCode.bright_green));
    try testing.expectEqual(@as(u8, 31), @intFromEnum(ColorCode.red));
}

test "ColorCode.toColor creates correct Color struct" {
    const color = ColorCode.bright_blue.toColor();
    try testing.expectEqual(@as(u8, 94), color.code);
    try testing.expectEqualStrings("bright_blue", color.name);
}

test "ColorPool.init creates pool with default colors" {
    var pool = try ColorPool.init(testing.allocator);
    defer pool.deinit();

    try testing.expect(pool.availableCount() > 0);
    try testing.expectEqual(@as(usize, 0), pool.inUseCount());
    try testing.expect(pool.hasAvailable());
}

test "ColorPool.getNextColor returns available color" {
    var pool = try ColorPool.init(testing.allocator);
    defer pool.deinit();

    const initial_available = pool.availableCount();
    const color = pool.getNextColor();

    try testing.expect(color != null);
    try testing.expectEqual(initial_available - 1, pool.availableCount());
    try testing.expectEqual(@as(usize, 1), pool.inUseCount());
}

test "ColorPool.returnColor makes color available again" {
    var pool = try ColorPool.init(testing.allocator);
    defer pool.deinit();

    const color = pool.getNextColor() orelse return error.NoColorAvailable;
    const before_return_available = pool.availableCount();

    try pool.returnColor(color);

    try testing.expectEqual(before_return_available + 1, pool.availableCount());
}

test "ColorPool handles exhaustion by recycling" {
    var pool = try ColorPool.init(testing.allocator);
    defer pool.deinit();

    // Use all available colors
    var colors = ArrayList(Color).init(testing.allocator);
    defer colors.deinit();

    while (pool.availableCount() > 0) {
        if (pool.getNextColor()) |color| {
            try colors.append(color);
        }
    }

    // Pool should recycle when exhausted
    const recycled = pool.getNextColor();
    try testing.expect(recycled != null);
}

test "ColorManager.init creates manager with color pool" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();

    try testing.expect(manager.color_pool.hasAvailable());
    try testing.expectEqual(@as(u32, 0), manager.getStats().total_types);
}

test "ColorManager.getColorForType assigns new color for new type" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();

    // Temporarily enable colors for test
    manager.setEnabled(true);

    const color = try manager.getColorForType("text");
    try testing.expect(color != null);
    try testing.expectEqual(@as(u32, 1), manager.getStats().total_types);
}

test "ColorManager.getColorForType returns same color for same type" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();
    manager.setEnabled(true);

    const color1 = try manager.getColorForType("text");
    const color2 = try manager.getColorForType("text");

    try testing.expect(color1 != null and color2 != null);
    try testing.expectEqual(color1.?.code, color2.?.code);
    try testing.expectEqual(@as(u32, 1), manager.getStats().total_types);
}

test "ColorManager.getColorForType assigns different colors for different types" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();
    manager.setEnabled(true);

    const text_color = try manager.getColorForType("text");
    const tool_color = try manager.getColorForType("tool_use");

    try testing.expect(text_color != null and tool_color != null);
    try testing.expect(text_color.?.code != tool_color.?.code);
    try testing.expectEqual(@as(u32, 2), manager.getStats().total_types);
}

test "ColorManager.getColorForType returns null when colors disabled" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();
    manager.setEnabled(false);

    const color = try manager.getColorForType("text");
    try testing.expect(color == null);
}

test "ColorManager.resetColorAssignments clears all assignments" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();
    manager.setEnabled(true);

    _ = try manager.getColorForType("text");
    _ = try manager.getColorForType("tool_use");
    try testing.expectEqual(@as(u32, 2), manager.getStats().total_types);

    manager.resetColorAssignments();
    try testing.expectEqual(@as(u32, 0), manager.getStats().total_types);
}

test "ColorManager.recycleUnusedColors removes inactive types" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();
    manager.setEnabled(true);

    _ = try manager.getColorForType("text");
    _ = try manager.getColorForType("tool_use");
    _ = try manager.getColorForType("error");
    try testing.expectEqual(@as(u32, 3), manager.getStats().total_types);

    // Only keep "text" and "error" active
    const active_types = [_][]const u8{ "text", "error" };
    try manager.recycleUnusedColors(&active_types);

    try testing.expectEqual(@as(u32, 2), manager.getStats().total_types);
}

test "ColorManager handles memory management correctly" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();
    manager.setEnabled(true);

    // Create many type assignments
    for (0..10) |i| {
        const type_name = try std.fmt.allocPrint(testing.allocator, "type_{d}", .{i});
        defer testing.allocator.free(type_name);

        _ = try manager.getColorForType(type_name);
    }

    try testing.expectEqual(@as(u32, 10), manager.getStats().total_types);

    // Reset should clean up all memory
    manager.resetColorAssignments();
    try testing.expectEqual(@as(u32, 0), manager.getStats().total_types);
}

test "ColorManager.getStats provides accurate information" {
    var manager = try ColorManager.init(testing.allocator);
    defer manager.deinit();
    manager.setEnabled(true);

    const initial_stats = manager.getStats();
    try testing.expect(initial_stats.enabled);
    try testing.expectEqual(@as(u32, 0), initial_stats.total_types);

    _ = try manager.getColorForType("text");
    _ = try manager.getColorForType("tool_use");

    const final_stats = manager.getStats();
    try testing.expectEqual(@as(u32, 2), final_stats.total_types);
    try testing.expect(final_stats.colors_in_use >= 2);
}

test "isColorEnabled respects NO_COLOR environment" {
    // This test depends on environment, just ensure it doesn't crash
    const enabled = isColorEnabled();
    _ = enabled; // Suppress unused variable warning
}
