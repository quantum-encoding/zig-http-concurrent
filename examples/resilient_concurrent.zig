// Copyright (c) 2025 QUANTUM ENCODING LTD
// The canonical pattern for resilient, concurrent HTTP operations

const std = @import("std");
const HttpClient = @import("../src/http_client.zig").HttpClient;
const retry_mod = @import("../src/retry/retry.zig");
const RetryEngine = retry_mod.RetryEngine;
const RetryConfig = retry_mod.RetryConfig;

/// Enterprise-grade worker with dedicated client and retry logic
const ResilientWorker = struct {
    id: usize,
    allocator: std.mem.Allocator,
    http_client: HttpClient,
    retry_engine: RetryEngine,
    success_count: *std.atomic.Value(u32),
    failure_count: *std.atomic.Value(u32),
    
    pub fn init(
        id: usize,
        allocator: std.mem.Allocator,
        success_count: *std.atomic.Value(u32),
        failure_count: *std.atomic.Value(u32),
    ) ResilientWorker {
        return .{
            .id = id,
            .allocator = allocator,
            .http_client = HttpClient.init(allocator),
            .retry_engine = RetryEngine.init(allocator, RetryConfig{
                .max_attempts = 3,
                .base_delay_ms = 100,
                .max_delay_ms = 2000,
                .backoff_multiplier = 2.0,
                .jitter_factor = 0.1,
                .enable_circuit_breaker = true,
                .circuit_failure_threshold = 5,
                .circuit_recovery_timeout_ms = 10000,
            }),
            .success_count = success_count,
            .failure_count = failure_count,
        };
    }
    
    pub fn deinit(self: *ResilientWorker) void {
        self.http_client.deinit();
    }
    
    pub fn run(self: *ResilientWorker) void {
        std.debug.print("Worker {d} starting with dedicated client and retry engine\n", .{self.id});
        
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            const RequestContext = struct {
                client: *HttpClient,
                worker_id: usize,
                request_num: u32,
                
                fn doRequest(ctx: @This()) !HttpClient.Response {
                    // This endpoint randomly returns 200, 429, or 503
                    const url = "https://httpbin.org/status/200,429,503";
                    return ctx.client.get(url, &.{});
                }
            };
            
            const context = RequestContext{
                .client = &self.http_client,
                .worker_id = self.id,
                .request_num = i,
            };
            
            // Custom retry predicate for HTTP errors
            const isRetryable = struct {
                fn check(err: anyerror) bool {
                    return switch (err) {
                        error.TooManyRequests,
                        error.ServiceUnavailable,
                        error.GatewayTimeout,
                        error.ConnectionRefused,
                        error.ConnectionTimeout,
                        error.NetworkUnreachable => true,
                        else => false,
                    };
                }
            }.check;
            
            const result = self.retry_engine.execute(
                HttpClient.Response,
                context,
                RequestContext.doRequest,
                isRetryable,
            );
            
            if (result) |response| {
                defer @constCast(&response).deinit();
                
                if (response.status == .ok) {
                    _ = self.success_count.fetchAdd(1, .monotonic);
                    std.debug.print("Worker {d}: Request {d} succeeded after retries\n", .{ self.id, i });
                } else {
                    _ = self.failure_count.fetchAdd(1, .monotonic);
                    std.debug.print("Worker {d}: Request {d} got status {}\n", .{ self.id, i, response.status });
                }
            } else |err| {
                _ = self.failure_count.fetchAdd(1, .monotonic);
                std.debug.print("Worker {d}: Request {d} failed permanently: {}\n", .{ self.id, i, err });
                
                // Check circuit breaker status
                if (self.retry_engine.getCircuitBreakerStatus()) |status| {
                    if (status.state == .open) {
                        std.debug.print("Worker {d}: Circuit breaker is OPEN\n", .{self.id});
                    }
                }
            }
            
            // Small delay between requests
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        
        // Report final stats for this worker
        const rate_limit = self.retry_engine.getRateLimitStatus();
        std.debug.print("Worker {d} completed. Rate limit tokens: {d:.1}/{d:.1}\n", .{
            self.id,
            rate_limit.tokens,
            rate_limit.max_tokens,
        });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== HTTP Sentinel: Resilient Concurrent Pattern ===\n", .{});
    std.debug.print("Demonstrating the production-grade architecture\n\n", .{});
    
    var success_count = std.atomic.Value(u32).init(0);
    var failure_count = std.atomic.Value(u32).init(0);
    
    const num_workers = 4;
    std.debug.print("🚀 Launching {d} resilient workers...\n\n", .{num_workers});
    
    // Create workers
    var workers: [num_workers]ResilientWorker = undefined;
    for (&workers, 0..) |*worker, i| {
        worker.* = ResilientWorker.init(
            i,
            allocator,
            &success_count,
            &failure_count,
        );
    }
    defer for (&workers) |*worker| worker.deinit();
    
    // Launch threads
    var threads: [num_workers]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| {
        thread.* = try std.Thread.spawn(.{}, ResilientWorker.run, .{worker});
    }
    
    // Wait for completion
    for (&threads) |*thread| {
        thread.join();
    }
    
    // Final results
    const total_success = success_count.load(.monotonic);
    const total_failures = failure_count.load(.monotonic);
    const total_requests = total_success + total_failures;
    
    std.debug.print("\n=== Final Results ===\n", .{});
    std.debug.print("Workers: {d}\n", .{num_workers});
    std.debug.print("Total requests: {d}\n", .{total_requests});
    std.debug.print("Successful: {d}\n", .{total_success});
    std.debug.print("Failed: {d}\n", .{total_failures});
    
    if (total_requests > 0) {
        const success_rate = @as(f64, @floatFromInt(total_success)) * 100.0 / @as(f64, @floatFromInt(total_requests));
        std.debug.print("Success rate: {d:.1}%\n", .{success_rate});
    }
    
    std.debug.print("\n✅ Resilient concurrent pattern demonstrated!\n", .{});
    std.debug.print("✅ Each worker has dedicated HTTP client + retry engine\n", .{});
    std.debug.print("✅ Circuit breakers protect against cascading failures\n", .{});
    std.debug.print("✅ Rate limiting prevents API throttling\n", .{});
    std.debug.print("✅ This is production-grade architecture\n", .{});
}