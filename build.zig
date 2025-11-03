// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core HTTP Sentinel library module (includes all submodules)
    const http_sentinel_module = b.addModule("zig-http-sentinel", .{
        .root_source_file = b.path("src/lib.zig"),
    });
    
    // Legacy compatibility - direct HTTP client module
    const http_client_module = b.addModule("http-sentinel", .{
        .root_source_file = b.path("src/http_client.zig"),
    });

    // Optional retry resilience module
    const retry_module = b.addModule("http-sentinel/retry", .{
        .root_source_file = b.path("src/retry/retry.zig"),
    });

    // Optional connection pool module  
    const pool_module = b.addModule("http-sentinel/pool", .{
        .root_source_file = b.path("src/pool/pool.zig"),
    });
    pool_module.addImport("http-sentinel", http_client_module);

    // Examples executable
    const example = b.addExecutable(.{
        .name = "examples",
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("http-sentinel", http_client_module);

    // AI Client example
    const ai_example = b.addExecutable(.{
        .name = "ai_client",
        .root_source_file = b.path("examples/anthropic_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai_example.root_module.addImport("http-sentinel", http_client_module);

    // NATS JetStream example
    const nats_example = b.addExecutable(.{
        .name = "nats_client",
        .root_source_file = b.path("examples/nats_jetstream_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    nats_example.root_module.addImport("http-sentinel", http_client_module);

    const run_example = b.addRunArtifact(example);
    const run_ai_example = b.addRunArtifact(ai_example);
    const run_nats_example = b.addRunArtifact(nats_example);
    
    const run_examples_step = b.step("examples", "Run basic HTTP examples");
    run_examples_step.dependOn(&run_example.step);
    
    const run_ai_step = b.step("ai-demo", "Run AI client demonstration");
    run_ai_step.dependOn(&run_ai_example.step);
    
    const run_nats_step = b.step("nats-demo", "Run NATS JetStream demonstration");
    run_nats_step.dependOn(&run_nats_example.step);

    // Unit Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/http_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Integration Tests
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("tests/http_client_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("http-sentinel", http_client_module);
    
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    
    const unit_test_step = b.step("test-unit", "Run unit tests only");
    unit_test_step.dependOn(&run_unit_tests.step);
    
    const integration_test_step = b.step("test-integration", "Run integration tests only");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Retry patterns example
    const retry_example = b.addExecutable(.{
        .name = "retry_patterns",
        .root_source_file = b.path("examples/retry_patterns.zig"),
        .target = target,
        .optimize = optimize,
    });
    retry_example.root_module.addImport("http-sentinel/retry", retry_module);
    
    const run_retry_example = b.addRunArtifact(retry_example);
    const retry_demo_step = b.step("retry-demo", "Run retry patterns demonstration");
    retry_demo_step.dependOn(&run_retry_example.step);

    // Connection pooling example  
    const pool_example = b.addExecutable(.{
        .name = "connection_pooling",
        .root_source_file = b.path("examples/connection_pooling.zig"),
        .target = target,
        .optimize = optimize,
    });
    pool_example.root_module.addImport("http-sentinel", http_client_module);
    pool_example.root_module.addImport("http-sentinel/pool", pool_module);
    
    const run_pool_example = b.addRunArtifact(pool_example);
    const pool_demo_step = b.step("pool-demo", "Run connection pooling demonstration");
    pool_demo_step.dependOn(&run_pool_example.step);
    
    // Pool & Retry Integration test
    const integration_example = b.addExecutable(.{
        .name = "pool_retry_integration",
        .root_source_file = b.path("examples/pool_retry_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_example.root_module.addImport("zig-http-sentinel", http_sentinel_module);
    
    const run_integration_example = b.addRunArtifact(integration_example);
    const integration_demo_step = b.step("integration-demo", "Run pool & retry integration demonstration");
    integration_demo_step.dependOn(&run_integration_example.step);
}