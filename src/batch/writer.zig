// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Result writer - Write batch results to CSV

const std = @import("std");
const types = @import("types.zig");

/// Write batch results to CSV file
pub fn writeResults(
    allocator: std.mem.Allocator,
    results: []types.BatchResult,
    output_path: []const u8,
    full_responses: bool,
) !void {
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);

    // Write CSV header
    try writer.interface.writeAll("id,provider,prompt,response,input_tokens,output_tokens,cost,execution_time_ms,error\n");
    try writer.interface.flush();

    // Write each result
    for (results) |*result| {
        const csv_line = try result.toCsv(allocator);
        defer allocator.free(csv_line);
        try writer.interface.writeAll(csv_line);
        try writer.interface.flush();
    }

    std.debug.print("Results written to: {s}\n", .{output_path});

    // Write full responses if requested
    if (full_responses) {
        try writeFullResponses(allocator, results, output_path);
    }
}

/// Write full responses to separate files
fn writeFullResponses(
    allocator: std.mem.Allocator,
    results: []types.BatchResult,
    output_path: []const u8,
) !void {
    // Create directory for full responses
    const dir_name = try std.fmt.allocPrint(
        allocator,
        "{s}_responses",
        .{output_path},
    );
    defer allocator.free(dir_name);

    std.fs.cwd().makeDir(dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory exists, that's fine
        else => return err,
    };

    // Write each response to a separate file
    for (results) |*result| {
        if (result.response) |response| {
            const provider_name = @tagName(result.provider);
            const filename = try std.fmt.allocPrint(
                allocator,
                "{s}/{d}_{s}.txt",
                .{ dir_name, result.id, provider_name },
            );
            defer allocator.free(filename);

            const file = try std.fs.cwd().createFile(filename, .{});
            defer file.close();

            try file.writeAll(response);
        }
    }

    std.debug.print("Full responses written to: {s}/\n", .{dir_name});
}

/// Generate default output filename with timestamp
pub fn generateOutputFilename(allocator: std.mem.Allocator) ![]u8 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.REALTIME);
    const timestamp = ts.sec;
    return try std.fmt.allocPrint(
        allocator,
        "batch_results_{d}.csv",
        .{timestamp},
    );
}
