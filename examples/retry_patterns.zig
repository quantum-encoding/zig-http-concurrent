// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const RetryEngine = @import("http-sentinel/retry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example 1: Simple exponential backoff
    std.debug.print("\n=== Exponential Backoff Pattern ===\n", .{});
    {
        const config = RetryEngine.RetryConfig{
            .max_attempts = 5,
            .initial_delay_ms = 100,
            .max_delay_ms = 10000,
            .backoff_multiplier = 2.0,
            .jitter_factor = 0.1,
        };

        var engine = RetryEngine.init(allocator, config);
        defer engine.deinit();

        // Simulate a failing operation
        var attempt: u32 = 0;
        while (attempt < config.max_attempts) : (attempt += 1) {
            const delay = engine.calculateDelay(attempt);
            std.debug.print("Attempt {}: Waiting {}ms before retry\n", .{ attempt + 1, delay });
            
            // In real usage, you'd perform your operation here
            const succeeded = attempt == 3; // Simulate success on 4th attempt
            
            if (succeeded) {
                std.debug.print("Operation succeeded on attempt {}\n", .{attempt + 1});
                break;
            }
            
            if (attempt < config.max_attempts - 1) {
                std.time.sleep(delay * std.time.ns_per_ms);
            }
        }
    }

    // Example 2: Circuit breaker pattern
    std.debug.print("\n=== Circuit Breaker Pattern ===\n", .{});
    {
        const config = RetryEngine.RetryConfig{
            .max_attempts = 3,
            .initial_delay_ms = 500,
            .max_delay_ms = 5000,
            .backoff_multiplier = 1.5,
            .jitter_factor = 0.2,
        };

        var engine = RetryEngine.init(allocator, config);
        defer engine.deinit();

        // Track consecutive failures for circuit breaking
        var consecutive_failures: u32 = 0;
        const failure_threshold: u32 = 3;
        var circuit_open = false;

        var i: u32 = 0;
        while (i < 10) : (i += 1) {
            if (circuit_open) {
                std.debug.print("Circuit OPEN - Skipping request {}\n", .{i + 1});
                std.time.sleep(1000 * std.time.ns_per_ms);
                
                // Try to close circuit after cooldown
                if (i % 3 == 0) {
                    std.debug.print("Attempting to close circuit...\n", .{});
                    circuit_open = false;
                    consecutive_failures = 0;
                }
                continue;
            }

            // Simulate operation with 60% failure rate
            const succeeded = (i % 5) < 2;
            
            if (succeeded) {
                std.debug.print("Request {} succeeded - Circuit CLOSED\n", .{i + 1});
                consecutive_failures = 0;
            } else {
                consecutive_failures += 1;
                std.debug.print("Request {} failed (consecutive: {})\n", .{ i + 1, consecutive_failures });
                
                if (consecutive_failures >= failure_threshold) {
                    circuit_open = true;
                    std.debug.print("Circuit OPEN after {} consecutive failures\n", .{failure_threshold});
                }
            }
            
            std.time.sleep(200 * std.time.ns_per_ms);
        }
    }

    // Example 3: Adaptive retry with health tracking
    std.debug.print("\n=== Adaptive Retry Pattern ===\n", .{});
    {
        var config = RetryEngine.RetryConfig{
            .max_attempts = 5,
            .initial_delay_ms = 100,
            .max_delay_ms = 5000,
            .backoff_multiplier = 2.0,
            .jitter_factor = 0.15,
        };

        var engine = RetryEngine.init(allocator, config);
        defer engine.deinit();

        var health_score: f32 = 1.0;
        const health_decay: f32 = 0.2;
        const health_recovery: f32 = 0.1;

        var request: u32 = 0;
        while (request < 8) : (request += 1) {
            // Adjust retry strategy based on health
            if (health_score < 0.5) {
                config.max_attempts = 2; // Reduce attempts when unhealthy
                config.backoff_multiplier = 3.0; // Back off more aggressively
            } else {
                config.max_attempts = 5;
                config.backoff_multiplier = 2.0;
            }

            // Simulate operation with variable success rate
            const succeeded = (request % 3) != 0;
            
            if (succeeded) {
                std.debug.print("Request {} succeeded (health: {d:.2})\n", .{ request + 1, health_score });
                health_score = @min(1.0, health_score + health_recovery);
            } else {
                std.debug.print("Request {} failed (health: {d:.2})\n", .{ request + 1, health_score });
                health_score = @max(0.0, health_score - health_decay);
                
                // Apply retry with current config
                const delay = engine.calculateDelay(0);
                std.debug.print("  Backing off for {}ms\n", .{delay});
                std.time.sleep(delay * std.time.ns_per_ms);
            }
        }
    }

    std.debug.print("\n=== All retry pattern examples completed ===\n", .{});
}