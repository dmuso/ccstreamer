//! Stream reader for CC Streamer
//! Handles buffered reading from stdin with line boundary detection
//!
//! This module provides efficient streaming input processing with proper
//! buffer management and JSON line boundary detection.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Errors that can occur during stream reading
pub const StreamError = error{
    EndOfStream,
    InvalidData,
    BufferTooSmall,
    ReadError,
} || std.io.AnyReader.Error;

/// Configuration for the stream reader
pub const StreamConfig = struct {
    buffer_size: usize = 8192, // 8KB default buffer
    max_line_size: usize = 1024 * 1024, // 1MB max line size
    timeout_ms: ?u32 = null, // No timeout by default
};

/// Stream reader for processing input line by line
pub const StreamReader = struct {
    reader: std.io.AnyReader,
    buffer: []u8,
    buffer_pos: usize = 0,
    buffer_filled: usize = 0,
    config: StreamConfig,
    allocator: Allocator,
    line_buffer: std.ArrayList(u8),
    eof_reached: bool = false,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, reader: std.io.AnyReader, config: StreamConfig) !Self {
        const buffer = try allocator.alloc(u8, config.buffer_size);
        errdefer allocator.free(buffer);
        
        return Self{
            .reader = reader,
            .buffer = buffer,
            .config = config,
            .allocator = allocator,
            .line_buffer = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
        self.line_buffer.deinit();
    }
    
    /// Read data into the internal buffer
    fn fillBuffer(self: *Self) !void {
        if (self.eof_reached) return;
        
        // Move remaining data to beginning of buffer if needed
        if (self.buffer_pos > 0) {
            const remaining = self.buffer_filled - self.buffer_pos;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buffer[0..remaining], self.buffer[self.buffer_pos..self.buffer_filled]);
            }
            self.buffer_filled = remaining;
            self.buffer_pos = 0;
        }
        
        // Read more data if there's space
        if (self.buffer_filled < self.buffer.len) {
            const bytes_read = self.reader.read(self.buffer[self.buffer_filled..]) catch |err| switch (err) {
                error.EndOfStream => {
                    self.eof_reached = true;
                    return;
                },
                else => return err,
            };
            
            if (bytes_read == 0) {
                self.eof_reached = true;
                return;
            }
            
            self.buffer_filled += bytes_read;
        }
    }
    
    /// Find the next newline character in the buffer
    fn findNewline(self: *Self) ?usize {
        if (self.buffer_pos >= self.buffer_filled) return null;
        
        const search_slice = self.buffer[self.buffer_pos..self.buffer_filled];
        if (std.mem.indexOfScalar(u8, search_slice, '\n')) |pos| {
            return self.buffer_pos + pos;
        }
        
        return null;
    }
    
    /// Read the next complete line from the stream
    pub fn readLine(self: *Self) !?[]const u8 {
        self.line_buffer.clearRetainingCapacity();
        
        while (true) {
            // Try to find a newline in current buffer
            if (self.findNewline()) |newline_pos| {
                // Copy data up to newline to line buffer
                const line_start = self.buffer_pos;
                const line_end = newline_pos;
                
                try self.line_buffer.appendSlice(self.buffer[line_start..line_end]);
                
                // Skip past the newline
                self.buffer_pos = newline_pos + 1;
                
                // Handle \r\n line endings
                if (self.line_buffer.items.len > 0 and self.line_buffer.items[self.line_buffer.items.len - 1] == '\r') {
                    self.line_buffer.shrinkRetainingCapacity(self.line_buffer.items.len - 1);
                }
                
                return self.line_buffer.items;
            }
            
            // No newline found, copy remaining buffer to line buffer and fill more
            if (self.buffer_pos < self.buffer_filled) {
                const remaining_data = self.buffer[self.buffer_pos..self.buffer_filled];
                
                // Check if adding this data would exceed max line size
                if (self.line_buffer.items.len + remaining_data.len > self.config.max_line_size) {
                    return StreamError.BufferTooSmall;
                }
                
                try self.line_buffer.appendSlice(remaining_data);
                self.buffer_pos = self.buffer_filled;
            }
            
            // Try to read more data
            try self.fillBuffer();
            
            // If EOF reached and we have data, return it
            if (self.eof_reached) {
                if (self.line_buffer.items.len > 0) {
                    return self.line_buffer.items;
                } else {
                    return null; // No more data
                }
            }
        }
    }
    
    /// Check if there's more data available to read
    pub fn hasMore(self: *const Self) bool {
        return !self.eof_reached or self.buffer_pos < self.buffer_filled;
    }
    
    /// Get statistics about buffer usage
    pub fn getBufferStats(self: *const Self) BufferStats {
        return BufferStats{
            .buffer_size = self.buffer.len,
            .buffer_filled = self.buffer_filled,
            .buffer_pos = self.buffer_pos,
            .line_buffer_size = self.line_buffer.items.len,
            .line_buffer_capacity = self.line_buffer.capacity,
        };
    }
};

/// Buffer usage statistics
pub const BufferStats = struct {
    buffer_size: usize,
    buffer_filled: usize,
    buffer_pos: usize,
    line_buffer_size: usize,
    line_buffer_capacity: usize,
    
    pub fn bufferUtilization(self: BufferStats) f64 {
        if (self.buffer_size == 0) return 0.0;
        return @as(f64, @floatFromInt(self.buffer_filled)) / @as(f64, @floatFromInt(self.buffer_size));
    }
};

/// Create a stream reader for stdin
pub fn createStdinReader(allocator: Allocator, config: StreamConfig) !StreamReader {
    const stdin = std.io.getStdIn().reader();
    return StreamReader.init(allocator, stdin.any(), config);
}

// Unit Tests
test "StreamReader basic line reading" {
    const test_data = "line1\nline2\nline3\n";
    var stream = std.io.fixedBufferStream(test_data);
    const reader = stream.reader().any();
    
    var stream_reader = try StreamReader.init(testing.allocator, reader, StreamConfig{});
    defer stream_reader.deinit();
    
    // Read first line
    const line1 = try stream_reader.readLine();
    try testing.expect(line1 != null);
    try testing.expectEqualStrings("line1", line1.?);
    
    // Read second line
    const line2 = try stream_reader.readLine();
    try testing.expect(line2 != null);
    try testing.expectEqualStrings("line2", line2.?);
    
    // Read third line
    const line3 = try stream_reader.readLine();
    try testing.expect(line3 != null);
    try testing.expectEqualStrings("line3", line3.?);
    
    // Should be end of stream
    const line4 = try stream_reader.readLine();
    try testing.expect(line4 == null);
}

test "StreamReader handles different line endings" {
    const test_cases = [_][]const u8{
        "unix\nline\n",
        "windows\r\nline\r\n",
        "mixed\nline\r\nstyle\n",
        "no_final_newline",
    };
    
    for (test_cases) |test_data| {
        var stream = std.io.fixedBufferStream(test_data);
        const reader = stream.reader().any();
        
        var stream_reader = try StreamReader.init(testing.allocator, reader, StreamConfig{});
        defer stream_reader.deinit();
        
        var line_count: u32 = 0;
        while (try stream_reader.readLine()) |line| {
            line_count += 1;
            // Lines should not contain \r or \n characters
            try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
            try testing.expect(std.mem.indexOfScalar(u8, line, '\r') == null);
        }
        
        // Should read at least one line from each test case
        try testing.expect(line_count > 0);
    }
}

test "StreamReader buffer management" {
    // Create data larger than buffer size
    var large_data = std.ArrayList(u8).init(testing.allocator);
    defer large_data.deinit();
    
    // Create lines with incremental content
    for (0..100) |i| {
        try large_data.writer().print("This is line number {} with some additional content\n", .{i});
    }
    
    var stream = std.io.fixedBufferStream(large_data.items);
    const reader = stream.reader().any();
    
    var stream_reader = try StreamReader.init(testing.allocator, reader, StreamConfig{
        .buffer_size = 256, // Small buffer to force multiple reads
    });
    defer stream_reader.deinit();
    
    var line_count: u32 = 0;
    while (try stream_reader.readLine()) |line| {
        line_count += 1;
        
        // Verify line format
        try testing.expect(std.mem.startsWith(u8, line, "This is line number"));
        try testing.expect(std.mem.indexOf(u8, line, "with some additional content") != null);
    }
    
    try testing.expectEqual(@as(u32, 100), line_count);
}

test "StreamReader handles empty lines" {
    const test_data = "line1\n\nline3\n\n\nline6\n";
    var stream = std.io.fixedBufferStream(test_data);
    const reader = stream.reader().any();
    
    var stream_reader = try StreamReader.init(testing.allocator, reader, StreamConfig{});
    defer stream_reader.deinit();
    
    const expected_lines = [_][]const u8{ "line1", "", "line3", "", "", "line6" };
    
    for (expected_lines) |expected| {
        const line = try stream_reader.readLine();
        try testing.expect(line != null);
        try testing.expectEqualStrings(expected, line.?);
    }
    
    // Should be end of stream
    try testing.expect((try stream_reader.readLine()) == null);
}

test "StreamReader buffer statistics" {
    const test_data = "test line\n";
    var stream = std.io.fixedBufferStream(test_data);
    const reader = stream.reader().any();
    
    var stream_reader = try StreamReader.init(testing.allocator, reader, StreamConfig{
        .buffer_size = 64,
    });
    defer stream_reader.deinit();
    
    // Initial stats
    var stats = stream_reader.getBufferStats();
    try testing.expectEqual(@as(usize, 64), stats.buffer_size);
    try testing.expectEqual(@as(usize, 0), stats.buffer_filled);
    
    // Read a line
    _ = try stream_reader.readLine();
    
    // Check updated stats
    stats = stream_reader.getBufferStats();
    try testing.expect(stats.buffer_filled > 0);
    try testing.expect(stats.bufferUtilization() >= 0.0);
    try testing.expect(stats.bufferUtilization() <= 1.0);
}

test "StreamReader large line handling" {
    // Create a line larger than max_line_size without newline to force buffer overflow
    var large_line = std.ArrayList(u8).init(testing.allocator);
    defer large_line.deinit();
    
    // Create data larger than max_line_size but smaller than buffer_size initially
    for (0..1500) |_| {
        try large_line.append('x');
    }
    // Don't add newline - this will force the reader to keep accumulating data
    
    var stream = std.io.fixedBufferStream(large_line.items);
    const reader = stream.reader().any();
    
    var stream_reader = try StreamReader.init(testing.allocator, reader, StreamConfig{
        .max_line_size = 1000, // Smaller than the test line
        .buffer_size = 512,    // Force multiple read cycles
    });
    defer stream_reader.deinit();
    
    // Should return error for oversized line
    try testing.expectError(StreamError.BufferTooSmall, stream_reader.readLine());
}

test "StreamReader hasMore functionality" {
    const test_data = "line1\nline2\n";
    var stream = std.io.fixedBufferStream(test_data);
    const reader = stream.reader().any();
    
    var stream_reader = try StreamReader.init(testing.allocator, reader, StreamConfig{});
    defer stream_reader.deinit();
    
    // Should have more initially
    try testing.expect(stream_reader.hasMore());
    
    // Read all lines
    _ = try stream_reader.readLine();
    try testing.expect(stream_reader.hasMore());
    
    _ = try stream_reader.readLine();
    // After reading everything, should detect no more data
    try testing.expect(!stream_reader.hasMore() or (try stream_reader.readLine()) == null);
}