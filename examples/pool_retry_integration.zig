// Copyright (c) 2025 QUANTUM ENCODING LTD
// Integration test demonstrating connection pooling with retry logic

const std = @import("std");
const HttpClient = @import("zig-http-sentinel").HttpClient;
const ConnectionPool = @import("zig-http-sentinel").pool.ConnectionPool;
const RetryEngine = @import("zig-http-sentinel").retry.RetryEngine;
const errors = @import("zig-http-sentinel").errors;

const PooledHttpClient = struct {
    allocator: std.mem.Allocator,
    pool: *ConnectionPool,
    retry_engine: RetryEngine,
    
    pub fn init(allocator: std.mem.Allocator) !PooledHttpClient {
        const pool_config = ConnectionPool.PoolConfig{
            .max_connections_per_host = 10,
            .max_idle_connections = 5,
            .idle_timeout_ms = 30000,
            .connection_timeout_ms = 5000,
            .keep_alive_timeout_ms = 60000,
            .max_requests_per_connection = 100,
            .enable_tcp_no_delay = true,
            .enable_keep_alive = true,
        };
        
        const retry_config = RetryEngine.RetryConfig{
            .max_attempts = 3,
            .base_delay_ms = 100,
            .max_delay_ms = 5000,
            .backoff_multiplier = 2.0,
            .jitter_factor = 0.1,
            .enable_circuit_breaker = true,
            .circuit_failure_threshold = 5,
            .circuit_recovery_timeout_ms = 30000,
        };
        
        return PooledHttpClient{
            .allocator = allocator,
            .pool = try ConnectionPool.init(allocator, pool_config),
            .retry_engine = RetryEngine.init(allocator, retry_config),
        };
    }
    
    pub fn deinit(self: *PooledHttpClient) void {
        self.pool.deinit();
    }
    
    const HttpRequestContext = struct {
        client: *PooledHttpClient,
        url: []const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
        method: std.http.Method,
    };
    
    pub fn get(self: *PooledHttpClient, url: []const u8, headers: []const std.http.Header) !HttpClient.Response {
        const context = HttpRequestContext{
            .client = self,
            .url = url,
            .headers = headers,
            .body = null,
            .method = .GET,
        };
        
        return self.retry_engine.execute(
            HttpClient.Response,
            context,
            executeRequest,
            isHttpErrorRetryable,
        );
    }
    
    pub fn post(self: *PooledHttpClient, url: []const u8, headers: []const std.http.Header, body: []const u8) !HttpClient.Response {
        const context = HttpRequestContext{
            .client = self,
            .url = url,
            .headers = headers,
            .body = body,
            .method = .POST,
        };
        
        return self.retry_engine.execute(
            HttpClient.Response,
            context,
            executeRequest,
            isHttpErrorRetryable,
        );
    }
    
    fn executeRequest(context: HttpRequestContext) !HttpClient.Response {
        var client = HttpClient.init(context.client.allocator);
        defer client.deinit();
        
        switch (context.method) {
            .GET => return client.get(context.url, context.headers),
            .POST => return client.post(context.url, context.headers, context.body.?),
            else => return error.UnsupportedMethod,
        }
    }
    
    fn isHttpErrorRetryable(err: anyerror) bool {
        // Convert to our HTTP errors if possible
        if (errors.fromStatusCode(std.http.Status.fromInt(@intFromError(err)) catch return false)) |http_err| {
            return errors.isRetryable(http_err);
        }
        
        // Check for common network errors
        return switch (err) {
            error.ConnectionRefused,
            error.ConnectionTimedOut,
            error.ConnectionResetByPeer,
            error.NetworkUnreachable,
            error.HostUnreachable,
            error.SystemResources,
            error.Unexpected => true,
            else => false,
        };
    }
    
    pub fn getStats(self: *PooledHttpClient) void {
        const pool_stats = self.pool.getStats();
        const rate_limit_status = self.retry_engine.getRateLimitStatus();
        const circuit_status = self.retry_engine.getCircuitBreakerStatus();
        
        std.debug.print("\n=== Connection Pool Stats ===\n", .{});
        std.debug.print("Total Connections: {d}\n", .{pool_stats.total_connections});
        std.debug.print("Active Connections: {d}\n", .{pool_stats.active_connections});
        std.debug.print("Idle Connections: {d}\n", .{pool_stats.idle_connections});
        std.debug.print("Requests Served: {d}\n", .{pool_stats.requests_served});
        std.debug.print("Connections Created: {d}\n", .{pool_stats.connections_created});
        std.debug.print("Connections Reused: {d}\n", .{pool_stats.connections_reused});
        std.debug.print("Timeouts: {d}\n", .{pool_stats.timeouts});
        std.debug.print("Errors: {d}\n", .{pool_stats.errors});
        
        std.debug.print("\n=== Rate Limiter Status ===\n", .{});
        std.debug.print("Available Tokens: {d:.2}/{d:.2}\n", .{ rate_limit_status.tokens, rate_limit_status.max_tokens });
        std.debug.print("Refill Rate: {d:.2} tokens/sec\n", .{rate_limit_status.refill_rate});
        
        if (circuit_status) |status| {
            std.debug.print("\n=== Circuit Breaker Status ===\n", .{});
            std.debug.print("State: {s}\n", .{@tagName(status.state)});
            std.debug.print("Failure Count: {d}\n", .{status.failure_count});
            std.debug.print("Success Count: {d}\n", .{status.success_count});
            std.debug.print("Can Execute: {}\n", .{status.can_execute});
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("=== HTTP Sentinel Pool & Retry Integration Test ===\n\n", .{});
    
    var client = try PooledHttpClient.init(allocator);
    defer client.deinit();
    
    // Test 1: Simple GET request with pooling and retry
    std.debug.print("Test 1: GET request to httpbin.org/get\n", .{});
    {
        const response = try client.get("https://httpbin.org/get", &.{
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
        });
        defer @constCast(&response).deinit();
        
        std.debug.print("Status: {}\n", .{response.status});
        std.debug.print("Response length: {d} bytes\n", .{response.body.len});
    }
    
    // Test 2: Multiple requests to test connection reuse
    std.debug.print("\nTest 2: Multiple requests to test connection pooling\n", .{});
    {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const response = try client.get("https://httpbin.org/uuid", &.{});
            defer @constCast(&response).deinit();
            
            std.debug.print("Request {d}: Status {}\n", .{ i + 1, response.status });
        }
    }
    
    // Test 3: POST request with JSON body
    std.debug.print("\nTest 3: POST request with JSON body\n", .{});
    {
        const json_body =
            \\{
            \\  "message": "Testing pool and retry integration",
            \\  "timestamp": 1234567890,
            \\  "source": "zig-http-sentinel"
            \\}
        ;
        
        const response = try client.post("https://httpbin.org/post", &.{
            .{ .name = "Content-Type", .value = "application/json" },
        }, json_body);
        defer @constCast(&response).deinit();
        
        std.debug.print("Status: {}\n", .{response.status});
        std.debug.print("Response length: {d} bytes\n", .{response.body.len});
    }
    
    // Test 4: Parallel requests to test pool limits
    std.debug.print("\nTest 4: Parallel requests to test pool limits\n", .{});
    {
        const ThreadContext = struct {
            client: *PooledHttpClient,
            thread_id: usize,
        };
        
        const worker = struct {
            fn run(ctx: ThreadContext) void {
                const response = ctx.client.get("https://httpbin.org/delay/1", &.{}) catch |err| {
                    std.debug.print("Thread {d} error: {}\n", .{ ctx.thread_id, err });
                    return;
                };
                defer @constCast(&response).deinit();
                
                std.debug.print("Thread {d} completed: Status {}\n", .{ ctx.thread_id, response.status });
            }
        }.run;
        
        var threads: [3]std.Thread = undefined;
        for (&threads, 0..) |*thread, idx| {
            thread.* = try std.Thread.spawn(.{}, worker, .{ThreadContext{
                .client = &client,
                .thread_id = idx,
            }});
        }
        
        for (&threads) |*thread| {
            thread.join();
        }
    }
    
    // Print final statistics
    std.debug.print("\n", .{});
    client.getStats();
    
    std.debug.print("\n=== All tests completed successfully! ===\n", .{});
}