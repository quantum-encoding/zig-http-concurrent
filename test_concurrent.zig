// Test concurrent HTTP requests using the client-per-worker pattern
const std = @import("std");
const HttpClient = @import("src/http_client.zig").HttpClient;

/// Worker that performs HTTP requests with its own dedicated client
const Worker = struct {
    id: usize,
    allocator: std.mem.Allocator,
    url: []const u8,
    success_count: *std.atomic.Value(u32),
    error_count: *std.atomic.Value(u32),
    
    fn run(self: @This()) void {
        // CRITICAL: Each worker creates its own HTTP client
        // This avoids all concurrency issues with Zig 0.16.0
        var client = HttpClient.init(self.allocator);
        defer client.deinit();
        
        std.debug.print("Worker {d} starting\n", .{self.id});
        
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const response = client.get(self.url, &.{}) catch |err| {
                std.debug.print("Worker {d} request {d} failed: {}\n", .{ self.id, i, err });
                _ = self.error_count.fetchAdd(1, .monotonic);
                continue;
            };
            defer @constCast(&response).deinit();
            
            if (response.status == .ok) {
                _ = self.success_count.fetchAdd(1, .monotonic);
                std.debug.print("Worker {d} request {d} succeeded\n", .{ self.id, i });
            } else {
                _ = self.error_count.fetchAdd(1, .monotonic);
                std.debug.print("Worker {d} request {d} got status: {}\n", .{ self.id, i, response.status });
            }
            
            // Small delay between requests
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        
        std.debug.print("Worker {d} completed\n", .{self.id});
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("\n=== HTTP Sentinel Concurrent Test ===\n", .{});
    std.debug.print("Testing client-per-worker pattern (the winning approach from Alpaca)\n\n", .{});
    
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
    std.debug.print("Workers: {d}\n", .{num_workers});
    std.debug.print("Total requests: {d}\n", .{total_requests});
    std.debug.print("Successful: {d}\n", .{total_success});
    std.debug.print("Failed: {d}\n", .{total_errors});
    
    if (total_requests > 0) {
        const success_rate = @as(f64, @floatFromInt(total_success)) * 100.0 / @as(f64, @floatFromInt(total_requests));
        std.debug.print("Success rate: {d:.1}%\n", .{success_rate});
    }
    
    std.debug.print("\n✅ Concurrent requests completed without segfaults!\n", .{});
    std.debug.print("✅ Each worker used its own HTTP client instance\n", .{});
    std.debug.print("✅ This is the pattern that works in production\n", .{});
}