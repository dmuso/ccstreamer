//! End-to-End tests for CC Streamer CLI application
//! These tests run the actual executable and verify complete user workflows

const std = @import("std");
const testing = std.testing;
const process = std.process;
const fs = std.fs;

test "E2E: ccstreamer executable exists and can be built" {
    // This is the most basic E2E test - can we build and run the binary?
    // This will fail until main.zig is properly implemented

    const allocator = testing.allocator;

    // Build the binary first
    const build_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build" },
    }) catch |err| {
        std.debug.print("Build failed: {}\n", .{err});
        return error.BuildFailed;
    };
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (build_result.term != .Exited or build_result.term.Exited != 0) {
        std.debug.print("Build failed with stderr: {s}\n", .{build_result.stderr});
        return error.BuildFailed;
    }

    // Try to run the ccstreamer binary (expecting it to fail because main.zig is not implemented)
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"./zig-out/bin/ccstreamer"},
    }) catch |err| {
        std.debug.print("Failed to run ccstreamer: {}\n", .{err});
        return error.ExecutableNotFound;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // The binary should exist and run, but main functionality isn't implemented yet
    // This test drives the need for proper main.zig implementation
    std.debug.print("ccstreamer ran with exit code: {}\n", .{result.term});
    try testing.expect(result.term == .Exited);
}

test "E2E: ccstreamer formats piped JSON input" {
    // This test represents the core user workflow - piping JSON through ccstreamer
    // It will fail until the main application logic is implemented

    const allocator = testing.allocator;

    // Build first
    const build_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build" },
    }) catch |err| {
        std.debug.print("Build failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (build_result.term != .Exited or build_result.term.Exited != 0) {
        std.debug.print("Build stderr: {s}\n", .{build_result.stderr});
        return error.BuildFailed;
    }

    // Test data - simple JSON that should be formatted
    const input_json = "{\"type\":\"test\",\"value\":42}";

    // Create a child process with piped stdin
    var child = std.process.Child.init(&.{"./zig-out/bin/ccstreamer"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Send the JSON input
    _ = try child.stdin.?.writeAll(input_json);
    child.stdin.?.close();
    child.stdin = null;

    // Read stdout and stderr before waiting (to avoid blocking)
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    // Wait for completion
    const term = try child.wait();

    // Check that the program exited successfully
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("ccstreamer failed with exit code: {any}\nstderr: {s}\n", .{ term, stderr });
        return error.UnexpectedExitCode;
    }

    // Check that we got the value extracted (fallback to value field)
    if (std.mem.indexOf(u8, stdout, "42") == null) {
        std.debug.print("Expected '42' in output, got: {s}\n", .{stdout});
        return error.NoFormattedOutput;
    }
}

test "E2E: ccstreamer handles multiple JSON objects (streaming)" {
    // This test verifies streaming behavior with multiple JSON objects
    // It will fail until streaming implementation is complete

    const allocator = testing.allocator;

    // Build first
    const build_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build" },
    }) catch return error.BuildFailed;
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (build_result.term != .Exited or build_result.term.Exited != 0) {
        return error.BuildFailed;
    }

    // Multiple JSON objects on separate lines (common Claude Code output format)
    const streaming_input =
        \\{"id": 1, "status": "start"}
        \\{"id": 2, "status": "processing", "progress": 50}
        \\{"id": 3, "status": "complete", "result": "success"}
        \\
    ;

    // Now actually test with streaming input
    var child = std.process.Child.init(&.{"./zig-out/bin/ccstreamer"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Send the streaming input
    _ = child.stdin.?.writeAll(streaming_input) catch |err| {
        std.debug.print("Failed to write to stdin: {}\n", .{err});
        return err;
    };
    child.stdin.?.close();
    child.stdin = null;

    // Read stdout and stderr before waiting (to avoid blocking)
    const stdout_bytes = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr_bytes);

    // Wait for completion
    const result = try child.wait();

    // Check that process completed successfully
    if (result != .Exited or result.Exited != 0) {
        std.debug.print("ccstreamer failed with stderr: {s}\n", .{stderr_bytes});
        return error.ProcessFailed;
    }

    // Check that we got output for each JSON object
    // First two objects fallback to metadata, third has "result" field extracted
    const expected_outputs = [_][]const u8{
        "[2 fields]", // First object has id and status
        "[3 fields]", // Second object has id, status, and progress
        "success", // Third object's result field is extracted
    };

    for (expected_outputs) |expected| {
        if (std.mem.indexOf(u8, stdout_bytes, expected) == null) {
            std.debug.print("Expected to find '{s}' in output: {s}\n", .{ expected, stdout_bytes });
            return error.MissingExpectedOutput;
        }
    }
}

test "E2E: ccstreamer respects NO_COLOR environment variable" {
    // This test verifies that colors can be disabled
    // It will fail until colorization and NO_COLOR support is implemented

    const allocator = testing.allocator;

    // Build first
    const build_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build" },
    }) catch return error.BuildFailed;
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (build_result.term != .Exited or build_result.term.Exited != 0) {
        return error.BuildFailed;
    }

    const input_json = "{\"test\": \"value\"}\n";

    // Test with NO_COLOR environment variable set
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("NO_COLOR", "1");

    var child = std.process.Child.init(&.{"./zig-out/bin/ccstreamer"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = &env_map;

    try child.spawn();

    // Send the JSON input
    _ = child.stdin.?.writeAll(input_json) catch |err| {
        std.debug.print("Failed to write to stdin: {}\n", .{err});
        return err;
    };
    child.stdin.?.close();
    child.stdin = null;

    // Read stdout and stderr before waiting
    const stdout_bytes = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr_bytes);

    // Wait for completion
    const result = try child.wait();

    // Should exit successfully
    if (result != .Exited or result.Exited != 0) {
        std.debug.print("ccstreamer failed with stderr: {s}\n", .{stderr_bytes});
        return error.ProcessFailed;
    }

    // Check that output contains no ANSI escape sequences (color codes start with \x1b[ or \x1B[)
    const has_ansi_escapes = std.mem.indexOf(u8, stdout_bytes, "\x1b[") != null or
        std.mem.indexOf(u8, stdout_bytes, "\x1B[") != null;

    if (has_ansi_escapes) {
        std.debug.print("Expected no color codes with NO_COLOR=1, but got: {s}\n", .{stdout_bytes});
        return error.ColorCodesFound;
    }

    // Should output metadata fallback since there's no message.content
    if (std.mem.indexOf(u8, stdout_bytes, "[1 fields]") == null) {
        std.debug.print("Expected formatted output, got: {s}\n", .{stdout_bytes});
        return error.NoFormattedOutput;
    }
}

test "E2E: ccstreamer handles malformed JSON with helpful error" {
    // This test verifies error handling behavior
    // It will fail until proper error handling is implemented

    const allocator = testing.allocator;

    // Build first
    const build_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build" },
    }) catch return error.BuildFailed;
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (build_result.term != .Exited or build_result.term.Exited != 0) {
        return error.BuildFailed;
    }

    // Malformed JSON input
    const malformed_input = "{\"incomplete\": \n";

    // Now actually test with malformed input
    var child = std.process.Child.init(&.{"./zig-out/bin/ccstreamer"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Send the malformed input
    _ = child.stdin.?.writeAll(malformed_input) catch |err| {
        std.debug.print("Failed to write to stdin: {}\n", .{err});
        return err;
    };
    child.stdin.?.close();
    child.stdin = null;

    // Read stdout and stderr before waiting
    const stdout_bytes = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr_bytes);

    // Wait for completion
    const result = try child.wait();

    // Should exit with non-zero code and provide helpful error
    if (result == .Exited and result.Exited == 0) {
        std.debug.print("Expected non-zero exit, got stdout: {s}\nstderr: {s}\n", .{ stdout_bytes, stderr_bytes });
        return error.ShouldHaveFailedWithMalformedJSON;
    }

    // Error message should be in stderr and be helpful
    if (stderr_bytes.len == 0) {
        std.debug.print("Expected error message in stderr, got stdout: {s}\n", .{stdout_bytes});
        return error.NoErrorMessage;
    }

    // Check for helpful error information (should mention JSON or parse error)
    const has_json_error = std.mem.indexOf(u8, stderr_bytes, "JSON") != null or
        std.mem.indexOf(u8, stderr_bytes, "parse") != null or
        std.mem.indexOf(u8, stderr_bytes, "error") != null or
        std.mem.indexOf(u8, stderr_bytes, "Error") != null;

    if (!has_json_error) {
        std.debug.print("Expected helpful error message, got stderr: {s}\n", .{stderr_bytes});
        return error.UnhelpfulErrorMessage;
    }
}
