//! Memory allocator utilities for CC Streamer
//! Provides arena allocators optimized for streaming JSON processing
//!
//! This module implements memory pools and tracking for efficient
//! JSON object processing with minimal allocations.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Statistics tracking for allocation patterns
pub const AllocationStats = struct {
    total_allocations: u64 = 0,
    total_deallocations: u64 = 0,
    current_usage: u64 = 0,
    peak_usage: u64 = 0,
    
    pub fn recordAllocation(self: *AllocationStats, size: usize) void {
        self.total_allocations += 1;
        self.current_usage += size;
        if (self.current_usage > self.peak_usage) {
            self.peak_usage = self.current_usage;
        }
    }
    
    pub fn recordDeallocation(self: *AllocationStats, size: usize) void {
        self.total_deallocations += 1;
        if (self.current_usage >= size) {
            self.current_usage -= size;
        }
    }
    
    pub fn reset(self: *AllocationStats) void {
        self.* = AllocationStats{};
    }
};

/// Arena allocator wrapper with statistics tracking
pub const StreamingArena = struct {
    arena: std.heap.ArenaAllocator,
    stats: AllocationStats,
    
    const Self = @This();
    
    pub fn init(backing_allocator: Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .stats = AllocationStats{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }
    
    pub fn allocator(self: *Self) Allocator {
        return self.arena.allocator();
    }
    
    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
        self.stats.reset();
    }
    
    pub fn getStats(self: *const Self) AllocationStats {
        return self.stats;
    }
};

/// Fixed-size memory pool for JSON objects
pub const JsonObjectPool = struct {
    const PoolEntry = struct {
        data: [max_object_size]u8,
        is_used: bool = false,
    };
    
    const max_object_size = 4096; // 4KB per JSON object
    const pool_size = 256; // Number of objects in pool
    
    entries: [pool_size]PoolEntry,
    stats: AllocationStats,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .entries = [_]PoolEntry{PoolEntry{ .data = undefined, .is_used = false }} ** pool_size,
            .stats = AllocationStats{},
        };
    }
    
    pub fn acquire(self: *Self) ?[]u8 {
        for (&self.entries) |*entry| {
            if (!entry.is_used) {
                entry.is_used = true;
                self.stats.recordAllocation(max_object_size);
                return &entry.data;
            }
        }
        return null; // Pool exhausted
    }
    
    pub fn release(self: *Self, buffer: []u8) void {
        for (&self.entries) |*entry| {
            if (buffer.ptr == &entry.data) {
                if (entry.is_used) {
                    entry.is_used = false;
                    self.stats.recordDeallocation(max_object_size);
                }
                return;
            }
        }
    }
    
    pub fn reset(self: *Self) void {
        for (&self.entries) |*entry| {
            entry.is_used = false;
        }
        self.stats.reset();
    }
    
    pub fn getStats(self: *const Self) AllocationStats {
        return self.stats;
    }
    
    pub fn availableCount(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.entries) |entry| {
            if (!entry.is_used) count += 1;
        }
        return count;
    }
};

// Unit Tests
test "AllocationStats basic functionality" {
    var stats = AllocationStats{};
    
    // Test initial state
    try testing.expectEqual(@as(u64, 0), stats.total_allocations);
    try testing.expectEqual(@as(u64, 0), stats.current_usage);
    try testing.expectEqual(@as(u64, 0), stats.peak_usage);
    
    // Test allocation recording
    stats.recordAllocation(100);
    try testing.expectEqual(@as(u64, 1), stats.total_allocations);
    try testing.expectEqual(@as(u64, 100), stats.current_usage);
    try testing.expectEqual(@as(u64, 100), stats.peak_usage);
    
    // Test peak tracking
    stats.recordAllocation(200);
    try testing.expectEqual(@as(u64, 2), stats.total_allocations);
    try testing.expectEqual(@as(u64, 300), stats.current_usage);
    try testing.expectEqual(@as(u64, 300), stats.peak_usage);
    
    // Test deallocation
    stats.recordDeallocation(100);
    try testing.expectEqual(@as(u64, 1), stats.total_deallocations);
    try testing.expectEqual(@as(u64, 200), stats.current_usage);
    try testing.expectEqual(@as(u64, 300), stats.peak_usage); // Peak should remain
    
    // Test reset
    stats.reset();
    try testing.expectEqual(@as(u64, 0), stats.total_allocations);
    try testing.expectEqual(@as(u64, 0), stats.current_usage);
    try testing.expectEqual(@as(u64, 0), stats.peak_usage);
}

test "StreamingArena basic operations" {
    var arena = StreamingArena.init(testing.allocator);
    defer arena.deinit();
    
    const alloc = arena.allocator();
    
    // Test basic allocation
    const buffer = try alloc.alloc(u8, 1024);
    try testing.expectEqual(@as(usize, 1024), buffer.len);
    
    // Test reset
    arena.reset();
    // After reset, should be able to allocate again
    const buffer2 = try alloc.alloc(u8, 2048);
    try testing.expectEqual(@as(usize, 2048), buffer2.len);
}

test "JsonObjectPool allocation and release" {
    var pool = JsonObjectPool.init();
    
    // Test initial state
    try testing.expectEqual(@as(u32, JsonObjectPool.pool_size), pool.availableCount());
    
    // Test acquiring buffers
    const buffer1 = pool.acquire();
    try testing.expect(buffer1 != null);
    try testing.expectEqual(@as(usize, JsonObjectPool.max_object_size), buffer1.?.len);
    try testing.expectEqual(@as(u32, JsonObjectPool.pool_size - 1), pool.availableCount());
    
    const buffer2 = pool.acquire();
    try testing.expect(buffer2 != null);
    try testing.expectEqual(@as(u32, JsonObjectPool.pool_size - 2), pool.availableCount());
    
    // Test releasing buffers
    pool.release(buffer1.?);
    try testing.expectEqual(@as(u32, JsonObjectPool.pool_size - 1), pool.availableCount());
    
    pool.release(buffer2.?);
    try testing.expectEqual(@as(u32, JsonObjectPool.pool_size), pool.availableCount());
    
    // Test statistics
    const stats = pool.getStats();
    try testing.expectEqual(@as(u64, 2), stats.total_allocations);
    try testing.expectEqual(@as(u64, 2), stats.total_deallocations);
    try testing.expectEqual(@as(u64, 0), stats.current_usage);
}

test "JsonObjectPool exhaustion handling" {
    var pool = JsonObjectPool.init();
    var buffers: [JsonObjectPool.pool_size + 1]?[]u8 = undefined;
    
    // Acquire all buffers from pool
    for (0..JsonObjectPool.pool_size) |i| {
        buffers[i] = pool.acquire();
        try testing.expect(buffers[i] != null);
    }
    
    // Pool should be exhausted
    try testing.expectEqual(@as(u32, 0), pool.availableCount());
    
    // Next acquisition should fail
    buffers[JsonObjectPool.pool_size] = pool.acquire();
    try testing.expect(buffers[JsonObjectPool.pool_size] == null);
    
    // Release one buffer and try again
    pool.release(buffers[0].?);
    const new_buffer = pool.acquire();
    try testing.expect(new_buffer != null);
}

test "JsonObjectPool stress test" {
    var pool = JsonObjectPool.init();
    
    // Perform many acquire/release cycles
    for (0..10000) |_| {
        const buffer = pool.acquire();
        if (buffer) |buf| {
            // Write some data to ensure buffer is valid
            buf[0] = 42;
            try testing.expectEqual(@as(u8, 42), buf[0]);
            pool.release(buf);
        }
    }
    
    // Pool should be fully available after stress test
    try testing.expectEqual(@as(u32, JsonObjectPool.pool_size), pool.availableCount());
}

test "memory leak detection" {
    var arena = StreamingArena.init(testing.allocator);
    defer arena.deinit();
    
    const alloc = arena.allocator();
    
    // Allocate various sizes
    _ = try alloc.alloc(u8, 100);
    _ = try alloc.alloc(u32, 50);
    _ = try alloc.alloc(u64, 25);
    
    // Arena should handle cleanup automatically
    arena.reset();
    
    // Should be able to allocate again after reset
    _ = try alloc.alloc(u8, 1000);
}