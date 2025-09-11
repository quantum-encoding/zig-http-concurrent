// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const HttpClient = @import("http-sentinel").HttpClient;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Zig HTTP Sentinel Example ===\n\n", .{});

    // Example 1: Simple GET request
    try exampleGet(allocator);
    
    // Example 2: POST with JSON
    try examplePostJson(allocator);
    
    // Example 3: Thread-safe concurrent requests
    try exampleConcurrent(allocator);

    std.debug.print("\nAll examples completed successfully!\n", .{});
}

fn exampleGet(allocator: std.mem.Allocator) !void {
    std.debug.print("1. Production GET Request\n", .{});
    
    var client = HttpClient.init(allocator);
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
    };

    var response = try client.get(
        "https://httpbin.org/get",
        &headers,
    );
    defer response.deinit();

    std.debug.print("   Status: {}\n", .{response.status});
    std.debug.print("   Body length: {d} bytes\n\n", .{response.body.len});
}

fn examplePostJson(allocator: std.mem.Allocator) !void {
    std.debug.print("2. Production POST with JSON\n", .{});
    
    var client = HttpClient.init(allocator);
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    };

    const json_payload =
        \\{
        \\  "library": "zig-http-sentinel",
        \\  "version": "1.0.0",
        \\  "features": ["thread-safe", "memory-safe", "high-performance"]
        \\}
    ;

    var response = try client.post(
        "https://httpbin.org/post",
        &headers,
        json_payload,
    );
    defer response.deinit();

    std.debug.print("   Status: {}\n", .{response.status});
    std.debug.print("   Payload echoed: {}\n\n", .{
        std.mem.indexOf(u8, response.body, "zig-http-sentinel") != null,
    });
}

fn exampleConcurrent(allocator: std.mem.Allocator) !void {
    std.debug.print("3. Production Concurrent Operations\n", .{});

    const Worker = struct {
        allocator: std.mem.Allocator,
        id: u32,
        success: std.atomic.Value(bool),

        fn run(self: *@This()) void {
            // CRITICAL: Each thread must have its own client instance
            var client = HttpClient.init(self.allocator);
            defer client.deinit();

            const url = std.fmt.allocPrint(
                self.allocator,
                "https://httpbin.org/delay/0?worker={d}",
                .{self.id},
            ) catch |err| {
                std.debug.print("   Worker {d}: Failed to allocate URL: {}\n", .{ self.id, err });
                self.success.store(false, .release);
                return;
            };
            defer self.allocator.free(url);

            var response = client.get(url, &.{}) catch |err| {
                std.debug.print("   Worker {d}: Request failed: {}\n", .{ self.id, err });
                self.success.store(false, .release);
                return;
            };
            defer response.deinit();

            const success = response.status == .ok;
            self.success.store(success, .release);
            std.debug.print("   Worker {d}: Status {} - {s}\n", .{ 
                self.id, 
                response.status,
                if (success) "SUCCESS" else "FAILED",
            });
        }
    };

    const num_workers = 4;
    var workers: [num_workers]Worker = undefined;
    var threads: [num_workers]std.Thread = undefined;

    // Initialize workers
    for (&workers, 0..) |*worker, i| {
        worker.* = Worker{
            .allocator = allocator,
            .id = @intCast(i),
            .success = std.atomic.Value(bool).init(false),
        };
    }

    // Launch threads
    for (&workers, &threads) |*worker, *thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Check results
    var all_success = true;
    for (workers) |*worker| {
        if (!worker.success.load(.acquire)) {
            all_success = false;
        }
    }

    std.debug.print("   Overall result: {s}\n", .{
        if (all_success) "ALL SUCCEEDED" else "SOME FAILED",
    });
}