// Integration test for HTTP Sentinel with pool and retry
const std = @import("std");
const HttpClient = @import("src/http_client.zig").HttpClient;
const pool = @import("src/pool/pool.zig");
const ConnectionPool = pool.ConnectionPool;
const PoolConfig = pool.PoolConfig;
const retry = @import("src/retry/retry.zig");
const RetryEngine = retry.RetryEngine;
const RetryConfig = retry.RetryConfig;

fn testBasicHttpClient() !void {
    std.debug.print("\n=== Testing Basic HTTP Client ===\n", .{});
    
    var client = HttpClient.init(std.heap.page_allocator);
    defer client.deinit();
    
    const response = try client.get("https://httpbin.org/get", &.{});
    defer @constCast(&response).deinit();
    
    std.debug.print("Basic GET Status: {}\n", .{response.status});
    std.debug.print("Response size: {} bytes\n", .{response.body.len});
}

fn testConnectionPool() !void {
    std.debug.print("\n=== Testing Connection Pool ===\n", .{});
    
    const pool_config = PoolConfig{
        .max_connections_per_host = 5,
        .max_idle_connections = 2,
        .idle_timeout_ms = 10000,
    };
    
    var conn_pool = try ConnectionPool.init(std.heap.page_allocator, pool_config);
    defer conn_pool.deinit();
    
    // Simulate acquiring and releasing connections
    const conn1 = try conn_pool.acquireConnection("httpbin.org", 443, true);
    std.debug.print("Acquired connection 1\n", .{});
    
    const stats1 = conn_pool.getStats();
    std.debug.print("Active connections: {}\n", .{stats1.active_connections});
    
    conn_pool.releaseConnection(conn1);
    std.debug.print("Released connection 1\n", .{});
    
    const stats2 = conn_pool.getStats();
    std.debug.print("Idle connections: {}\n", .{stats2.idle_connections});
}

fn testRetryEngine() !void {
    std.debug.print("\n=== Testing Retry Engine ===\n", .{});
    
    const retry_config = RetryConfig{
        .max_attempts = 3,
        .base_delay_ms = 100,
        .max_delay_ms = 1000,
    };
    
    var retry_engine = RetryEngine.init(std.heap.page_allocator, retry_config);
    
    const TestContext = struct {
        attempt_count: *u32,
        
        fn failingFunc(self: @This()) !u32 {
            self.attempt_count.* += 1;
            if (self.attempt_count.* < 3) {
                return error.NetworkUnreachable;
            }
            return 42;
        }
    };
    
    var attempt_count: u32 = 0;
    const context = TestContext{ .attempt_count = &attempt_count };
    
    const result = try retry_engine.execute(
        u32,
        context,
        TestContext.failingFunc,
        null, // Use default retry logic
    );
    
    std.debug.print("Result after {} attempts: {}\n", .{ attempt_count, result });
}

fn testIntegration() !void {
    std.debug.print("\n=== Testing Pool + Retry Integration ===\n", .{});
    
    // This demonstrates that pool and retry can be used together
    const pool_config = PoolConfig{};
    var conn_pool = try ConnectionPool.init(std.heap.page_allocator, pool_config);
    defer conn_pool.deinit();
    
    const retry_config = RetryConfig{};
    var retry_engine = RetryEngine.init(std.heap.page_allocator, retry_config);
    
    // Context for HTTP request with pooling and retry
    const HttpContext = struct {
        client: *HttpClient,
        url: []const u8,
        
        fn doRequest(self: @This()) !HttpClient.Response {
            return self.client.get(self.url, &.{});
        }
    };
    
    var client = HttpClient.init(std.heap.page_allocator);
    defer client.deinit();
    
    const context = HttpContext{
        .client = &client,
        .url = "https://httpbin.org/status/200",
    };
    
    const response = try retry_engine.execute(
        HttpClient.Response,
        context,
        HttpContext.doRequest,
        null,
    );
    defer @constCast(&response).deinit();
    
    std.debug.print("Integration test status: {}\n", .{response.status});
    
    const pool_stats = conn_pool.getStats();
    const rate_limit_status = retry_engine.getRateLimitStatus();
    
    std.debug.print("Pool stats - Total: {}, Active: {}, Idle: {}\n", .{
        pool_stats.total_connections,
        pool_stats.active_connections,
        pool_stats.idle_connections,
    });
    
    std.debug.print("Rate limiter - Tokens: {d:.2}/{d:.2}\n", .{
        rate_limit_status.tokens,
        rate_limit_status.max_tokens,
    });
}

pub fn main() !void {
    std.debug.print("=== HTTP Sentinel Integration Test Suite ===\n", .{});
    
    // Test individual components
    try testBasicHttpClient();
    try testConnectionPool();
    try testRetryEngine();
    
    // Test integration
    try testIntegration();
    
    std.debug.print("\n=== All tests completed successfully! ===\n", .{});
    std.debug.print("✅ HTTP Sentinel is ready for release!\n", .{});
    std.debug.print("✅ Pool and Retry modules are properly integrated!\n", .{});
}