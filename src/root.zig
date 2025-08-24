//! CC Streamer Library Root
//! Main library interface for the CC Streamer v2 JSON message formatting tool
const std = @import("std");
const testing = std.testing;

// Parser modules
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const tokenizer = @import("parser/tokenizer.zig");

// Stream processing modules
pub const stream_reader = @import("stream/reader.zig");
pub const boundary_detector = @import("stream/boundary_detector.zig");

// Legacy formatter modules (v1 compatibility)
pub const indentation = @import("formatter/indentation.zig");
pub const json_formatter = @import("formatter/json_formatter.zig");
pub const colors = @import("formatter/colors.zig");

// v2 Message processing modules  
pub const color_manager = @import("colorizer/color_manager.zig");
pub const content_extractor = @import("message/content_extractor.zig");
pub const escape_renderer = @import("message/escape_renderer.zig");
pub const type_formatters = @import("message/type_formatters.zig");

// Utility modules
pub const allocator_utils = @import("utils/allocator.zig");
pub const test_utils = @import("test_utils.zig");

test "basic library import" {
    const JsonValue = ast.JsonValue;
    const formatter = json_formatter.JsonFormatter;
    _ = JsonValue;
    _ = formatter;
}
