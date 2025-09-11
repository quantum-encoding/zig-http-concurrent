// Copyright (c) 2025 QUANTUM ENCODING LTD
// Demonstrates the correct pattern for concurrent HTTP requests in Zig 0.16.0

const std = @import("std");

// For standalone compilation, we'll embed the necessary types
const HttpClient = @import("http_client.zig").HttpClient;
const ClientPool = @import("client_pool.zig").ClientPool;
const RetryEngine = @import("retry.zig").RetryEngine;

/// Worker that performs HTTP requests with its own dedicated client
const Worker = struct {
    id: usize,
    allocator: std.mem.Allocator,
    url: []const u8,
    success_count: *std.atomic.Value(u32),
    error_count: *std.atomic.Value(u32),
    
    fn run(self: @This()) void {
        // CRITICAL: Each worker creates its own HTTP client
        // This is the key to avoiding segfaults in Zig 0.16.0
        var client = HttpClient.init(self.allocator);
        defer client.deinit();
        
        // Optional: Add retry logic
        var retry_engine = RetryEngine.init(self.allocator, .{
            .max_attempts = 3,
            .base_delay_ms = 100,
        });
        
        std.debug.print("Worker {d} starting with dedicated HTTP client\n", .{self.id});
        
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            // Use retry engine with the worker's client
            const result = self.makeRequestWithRetry(&client, &retry_engine);
            
            if (result) {
                _ = self.success_count.fetchAdd(1, .monotonic);
            } else {
                _ = self.error_count.fetchAdd(1, .monotonic);
            }
            
            // Small delay between requests
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        
        std.debug.print("Worker {d} completed\n", .{self.id});
    }
    
    fn makeRequestWithRetry(self: @This(), client: *HttpClient, retry_engine: *RetryEngine) bool {
        const Context = struct {
            client: *HttpClient,
            url: []const u8,
            
            fn doRequest(ctx: @This()) !HttpClient.Response {
                return ctx.client.get(ctx.url, &.{});
            }
        };
        
        const context = Context{
            .client = client,
            .url = self.url,
        };
        
        const response = retry_engine.execute(
            HttpClient.Response,
            context,
            Context.doRequest,
            null, // Use default retry logic
        ) catch |err| {
            std.debug.print("Worker {d} request failed: {}\n", .{ self.id, err });
            return false;
        };
        defer @constCast(&response).deinit();
        
        std.debug.print("Worker {d} got response: {}\n", .{ self.id, response.status });
        return response.status == .ok;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("=== HTTP Sentinel Concurrent Requests Demo ===\n", .{});
    std.debug.print("Demonstrating the client-per-worker pattern\n\n", .{});
    
    var success_count = std.atomic.Value(u32).init(0);
    var error_count = std.atomic.Value(u32).init(0);
    
    const num_workers = 4;
    const test_url = "https://httpbin.org/get";
    
    // Create workers
    var workers: [num_workers]Worker = undefined;
    for (&workers, 0..) |*worker, i| {
        worker.* = Worker{
            .id = i,
            .allocator = allocator,
            .url = test_url,
            .success_count = &success_count,
            .error_count = &error_count,
        };
    }
    
    // Launch threads
    var threads: [num_workers]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker.*});
    }
    
    // Wait for all threads to complete
    for (&threads) |*thread| {
        thread.join();
    }
    
    // Print results
    const total_success = success_count.load(.monotonic);
    const total_errors = error_count.load(.monotonic);
    const total_requests = total_success + total_errors;
    
    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("Total requests: {d}\n", .{total_requests});
    std.debug.print("Successful: {d}\n", .{total_success});
    std.debug.print("Failed: {d}\n", .{total_errors});
    std.debug.print("Success rate: {d:.1}%\n", .{
        if (total_requests > 0) @as(f64, @floatFromInt(total_success)) * 100.0 / @as(f64, @floatFromInt(total_requests)) else 0.0,
    });
    
    std.debug.print("\n✅ Concurrent requests completed without segfaults!\n", .{});
    std.debug.print("✅ Each worker used its own HTTP client instance\n", .{});
    std.debug.print("✅ No mutexes needed - true parallelism achieved\n", .{});
}