// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const HttpClient = @import("http-sentinel");
const ConnectionPool = @import("http-sentinel/pool");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example 1: Basic connection pooling
    std.debug.print("\n=== Basic Connection Pool ===\n", .{});
    {
        const config = ConnectionPool.PoolConfig{
            .max_connections = 10,
            .max_idle_connections = 5,
            .connection_timeout_ms = 5000,
            .idle_timeout_ms = 30000,
            .max_connection_lifetime_ms = 300000,
        };

        var pool = try ConnectionPool.init(allocator, config);
        defer pool.deinit();

        // Simulate concurrent requests
        std.debug.print("Pool initialized with max {} connections\n", .{config.max_connections});
        
        // Acquire connections
        var connections = std.ArrayList(*ConnectionPool.Connection).init(allocator);
        defer connections.deinit();

        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const conn = try pool.acquire("api.example.com", 443);
            try connections.append(conn);
            std.debug.print("Acquired connection {} (active: {}, idle: {})\n", .{
                i + 1,
                pool.getActiveCount(),
                pool.getIdleCount(),
            });
        }

        // Release some connections back to pool
        for (connections.items[0..3]) |conn| {
            pool.release(conn);
            std.debug.print("Released connection (active: {}, idle: {})\n", .{
                pool.getActiveCount(),
                pool.getIdleCount(),
            });
        }

        // Reuse pooled connections
        std.debug.print("\nReusing pooled connections:\n", .{});
        i = 0;
        while (i < 3) : (i += 1) {
            const conn = try pool.acquire("api.example.com", 443);
            std.debug.print("Reused connection {} (from pool)\n", .{i + 1});
            pool.release(conn);
        }
    }

    // Example 2: Multi-host connection management
    std.debug.print("\n=== Multi-Host Connection Pool ===\n", .{});
    {
        const config = ConnectionPool.PoolConfig{
            .max_connections = 20,
            .max_idle_connections = 10,
            .connection_timeout_ms = 3000,
            .idle_timeout_ms = 60000,
            .max_connection_lifetime_ms = 600000,
        };

        var pool = try ConnectionPool.init(allocator, config);
        defer pool.deinit();

        const hosts = [_][]const u8{
            "api.service1.com",
            "api.service2.com",
            "api.service3.com",
        };

        // Create connections to different hosts
        for (hosts) |host| {
            std.debug.print("\nConnecting to {s}:\n", .{host});
            
            var j: usize = 0;
            while (j < 3) : (j += 1) {
                const conn = try pool.acquire(host, 443);
                std.debug.print("  Connection {} established\n", .{j + 1});
                
                // Simulate some work
                std.time.sleep(50 * std.time.ns_per_ms);
                
                pool.release(conn);
            }
            
            std.debug.print("  Pool stats - Active: {}, Idle: {}, Total: {}\n", .{
                pool.getActiveCount(),
                pool.getIdleCount(),
                pool.getTotalCount(),
            });
        }

        // Show per-host statistics
        std.debug.print("\nPer-host connection stats:\n", .{});
        for (hosts) |host| {
            const stats = pool.getHostStats(host);
            std.debug.print("  {s}: {} connections (reuse rate: {d:.1}%)\n", .{
                host,
                stats.connection_count,
                stats.reuse_rate * 100,
            });
        }
    }

    // Example 3: Connection health monitoring
    std.debug.print("\n=== Connection Health Monitoring ===\n", .{});
    {
        const config = ConnectionPool.PoolConfig{
            .max_connections = 15,
            .max_idle_connections = 8,
            .connection_timeout_ms = 2000,
            .idle_timeout_ms = 20000,
            .max_connection_lifetime_ms = 120000,
            .health_check_interval_ms = 5000,
        };

        var pool = try ConnectionPool.init(allocator, config);
        defer pool.deinit();

        // Enable health checking
        try pool.enableHealthChecks();

        std.debug.print("Health monitoring enabled (interval: {}ms)\n", .{config.health_check_interval_ms});

        // Simulate connection lifecycle with health checks
        var tick: u32 = 0;
        while (tick < 10) : (tick += 1) {
            // Acquire and use connections
            var conn = try pool.acquire("api.healthcheck.com", 443);
            
            // Simulate connection health status
            const is_healthy = (tick % 3) != 2;
            if (!is_healthy) {
                std.debug.print("Tick {}: Connection unhealthy, marking for removal\n", .{tick});
                pool.markUnhealthy(conn);
            } else {
                std.debug.print("Tick {}: Connection healthy\n", .{tick});
                pool.release(conn);
            }

            // Run health check cycle
            const removed = try pool.performHealthCheck();
            if (removed > 0) {
                std.debug.print("  Health check removed {} unhealthy connections\n", .{removed});
            }

            // Show pool health metrics
            const health = pool.getHealthMetrics();
            std.debug.print("  Pool health: {d:.1}% (healthy: {}, unhealthy: {})\n", .{
                health.health_percentage * 100,
                health.healthy_connections,
                health.unhealthy_connections,
            });

            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }

    // Example 4: Load balancing across pool
    std.debug.print("\n=== Load Balanced Connection Pool ===\n", .{});
    {
        const config = ConnectionPool.PoolConfig{
            .max_connections = 12,
            .max_idle_connections = 6,
            .connection_timeout_ms = 3000,
            .idle_timeout_ms = 45000,
            .max_connection_lifetime_ms = 180000,
            .enable_load_balancing = true,
        };

        var pool = try ConnectionPool.init(allocator, config);
        defer pool.deinit();

        // Define backend servers
        const backends = [_]ConnectionPool.Backend{
            .{ .host = "backend1.service.com", .port = 443, .weight = 3 },
            .{ .host = "backend2.service.com", .port = 443, .weight = 2 },
            .{ .host = "backend3.service.com", .port = 443, .weight = 1 },
        };

        try pool.configureBackends(&backends);

        std.debug.print("Configured {} backends with weighted load balancing\n", .{backends.len});

        // Make requests and observe distribution
        var backend_counts = std.AutoHashMap([]const u8, u32).init(allocator);
        defer backend_counts.deinit();

        var req: u32 = 0;
        while (req < 30) : (req += 1) {
            const conn = try pool.acquireBalanced();
            const backend = conn.getHost();
            
            const count = backend_counts.get(backend) orelse 0;
            try backend_counts.put(backend, count + 1);
            
            // Simulate request processing
            std.time.sleep(10 * std.time.ns_per_ms);
            pool.release(conn);
        }

        // Show load distribution
        std.debug.print("\nLoad distribution across backends:\n", .{});
        var iter = backend_counts.iterator();
        while (iter.next()) |entry| {
            const percentage = @as(f32, @floatFromInt(entry.value_ptr.*)) / 30.0 * 100.0;
            std.debug.print("  {s}: {} requests ({d:.1}%)\n", .{
                entry.key_ptr.*,
                entry.value_ptr.*,
                percentage,
            });
        }
    }

    std.debug.print("\n=== All connection pooling examples completed ===\n", .{});
}