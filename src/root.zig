//! CC Streamer Library Root
//! Main library interface for the CC Streamer JSON formatting tool
const std = @import("std");
const testing = std.testing;

// Parser modules
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const tokenizer = @import("parser/tokenizer.zig");

// Stream processing modules
pub const stream_reader = @import("stream/reader.zig");
pub const boundary_detector = @import("stream/boundary_detector.zig");

// Formatter modules
pub const indentation = @import("formatter/indentation.zig");
pub const json_formatter = @import("formatter/json_formatter.zig");
pub const colors = @import("formatter/colors.zig");

// Utility modules
pub const allocator_utils = @import("utils/allocator.zig");
pub const test_utils = @import("test_utils.zig");

test "basic library import" {
    const JsonValue = ast.JsonValue;
    const formatter = json_formatter.JsonFormatter;
    _ = JsonValue;
    _ = formatter;
}
