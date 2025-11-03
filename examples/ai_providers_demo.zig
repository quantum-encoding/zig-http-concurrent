// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Comprehensive demonstration of all AI provider clients
//!
//! This example shows how to use:
//! - Claude (Anthropic)
//! - DeepSeek (Anthropic-compatible, ultra-affordable)
//! - Gemini (Google)
//! - Grok (X.AI)
//! - Vertex AI (Google Cloud)
//!
//! Setup:
//! export ANTHROPIC_API_KEY=your_claude_key
//! export DEEPSEEK_API_KEY=your_deepseek_key
//! export GENAI_API_KEY=your_gemini_key  # or GEMINI_API_KEY
//! export XAI_API_KEY=your_grok_key
//! export GCP_PROJECT=your_gcp_project  # for Vertex AI

const std = @import("std");
const http_sentinel = @import("http-sentinel");

const ClaudeClient = http_sentinel.ClaudeClient;
const DeepSeekClient = http_sentinel.DeepSeekClient;
const GeminiClient = http_sentinel.GeminiClient;
const GrokClient = http_sentinel.GrokClient;
const VertexClient = http_sentinel.VertexClient;
const ResponseManager = http_sentinel.ResponseManager;
const AIResponse = http_sentinel.ai.AIResponse;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 80 ++ "\n", .{});
    std.debug.print("  HIGH-PERFORMANCE AI PROVIDERS - ZIG HTTP SENTINEL\n", .{});
    std.debug.print("=" ** 80 ++ "\n\n", .{});

    // Initialize response manager to track all interactions
    var response_manager = ResponseManager.init(allocator);
    defer response_manager.deinit();

    const test_prompt = "Explain why Zig is excellent for systems programming in exactly 3 sentences.";

    // Demo 1: Claude (Anthropic)
    try demoClaudeClient(allocator, &response_manager, test_prompt);

    // Demo 2: DeepSeek (Ultra-affordable)
    try demoDeepSeekClient(allocator, &response_manager, test_prompt);

    // Demo 3: Gemini (Google)
    try demoGeminiClient(allocator, &response_manager, test_prompt);

    // Demo 4: Grok (X.AI)
    try demoGrokClient(allocator, &response_manager, test_prompt);

    // Demo 5: Vertex AI (Enterprise)
    try demoVertexClient(allocator, &response_manager, test_prompt);

    // Summary
    try printSummary(&response_manager);

    std.debug.print("\n" ++ "=" ** 80 ++ "\n", .{});
    std.debug.print("  All demonstrations completed successfully!\n", .{});
    std.debug.print("=" ** 80 ++ "\n\n", .{});
}

fn demoClaudeClient(
    allocator: std.mem.Allocator,
    manager: *ResponseManager,
    prompt: []const u8,
) !void {
    std.debug.print("\n{s} Demo 1: Claude (Anthropic) {s}\n", .{ "🧠", "-" ** 57 });

    const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch |err| {
        std.debug.print("⚠️  Skipped: ANTHROPIC_API_KEY not set ({any})\n", .{err});
        return;
    };
    defer allocator.free(api_key);

    var client = ClaudeClient.init(allocator, api_key);
    defer client.deinit();

    const config = ClaudeClient.fastConfig(); // Use Haiku for speed

    std.debug.print("Model: {s}\n", .{config.model});
    std.debug.print("Prompt: {s}\n\n", .{prompt});

    const start = std.time.milliTimestamp();
    var response = client.sendMessage(prompt, config) catch |err| {
        std.debug.print("❌ Error: {any}\n", .{err});
        return;
    };
    const elapsed = std.time.milliTimestamp() - start;

    std.debug.print("Response:\n{s}\n\n", .{response.message.content});
    std.debug.print("Tokens: {} in, {} out ({} total)\n", .{
        response.usage.input_tokens,
        response.usage.output_tokens,
        response.usage.total(),
    });
    std.debug.print("Time: {}ms\n", .{elapsed});
    std.debug.print("Cost: ${d:.6}\n", .{
        response.usage.estimateCost(
            http_sentinel.ai.Pricing.CLAUDE_HAIKU_INPUT,
            http_sentinel.ai.Pricing.CLAUDE_HAIKU_OUTPUT,
        ),
    });

    // Store in response manager
    const conv_id = "claude-demo";
    const request = http_sentinel.ai.ResponseManager.Request{
        .prompt = prompt,
        .model = config.model,
        .config = config,
        .allocator = allocator,
    };

    try manager.storeResponse(conv_id, request, response);
    std.debug.print("✅ Stored in response manager\n", .{});
}

fn demoDeepSeekClient(
    allocator: std.mem.Allocator,
    manager: *ResponseManager,
    prompt: []const u8,
) !void {
    std.debug.print("\n{s} Demo 2: DeepSeek (Ultra-Affordable) {s}\n", .{ "💎", "-" ** 47 });

    const api_key = std.process.getEnvVarOwned(allocator, "DEEPSEEK_API_KEY") catch |err| {
        std.debug.print("⚠️  Skipped: DEEPSEEK_API_KEY not set ({any})\n", .{err});
        return;
    };
    defer allocator.free(api_key);

    var client = DeepSeekClient.init(allocator, api_key);
    defer client.deinit();

    const config = DeepSeekClient.defaultConfig();

    std.debug.print("Model: {s}\n", .{config.model});
    std.debug.print("Prompt: {s}\n\n", .{prompt});

    const start = std.time.milliTimestamp();
    var response = client.sendMessage(prompt, config) catch |err| {
        std.debug.print("❌ Error: {any}\n", .{err});
        return;
    };
    const elapsed = std.time.milliTimestamp() - start;

    std.debug.print("Response:\n{s}\n\n", .{response.message.content});
    std.debug.print("Tokens: {} in, {} out ({} total)\n", .{
        response.usage.input_tokens,
        response.usage.output_tokens,
        response.usage.total(),
    });
    std.debug.print("Time: {}ms\n", .{elapsed});
    std.debug.print("Cost: ${d:.6} (95%% cheaper than Claude!)\n", .{
        DeepSeekClient.Pricing.calculateCost(response.usage),
    });

    const conv_id = "deepseek-demo";
    const request = http_sentinel.ai.ResponseManager.Request{
        .prompt = prompt,
        .model = config.model,
        .config = config,
        .allocator = allocator,
    };

    try manager.storeResponse(conv_id, request, response);
    std.debug.print("✅ Stored in response manager\n", .{});
}

fn demoGeminiClient(
    allocator: std.mem.Allocator,
    manager: *ResponseManager,
    prompt: []const u8,
) !void {
    std.debug.print("\n{s} Demo 3: Google Gemini {s}\n", .{ "🔮", "-" ** 59 });

    const api_key = std.process.getEnvVarOwned(allocator, "GENAI_API_KEY") catch blk: {
        break :blk std.process.getEnvVarOwned(allocator, "GEMINI_API_KEY") catch |err| {
            std.debug.print("⚠️  Skipped: GENAI_API_KEY or GEMINI_API_KEY not set ({any})\n", .{err});
            return;
        };
    };
    defer allocator.free(api_key);

    var client = GeminiClient.init(allocator, api_key);
    defer client.deinit();

    const config = GeminiClient.fastConfig(); // Use Flash for speed

    std.debug.print("Model: {s}\n", .{config.model});
    std.debug.print("Prompt: {s}\n\n", .{prompt});

    const start = std.time.milliTimestamp();
    var response = client.sendMessage(prompt, config) catch |err| {
        std.debug.print("❌ Error: {any}\n", .{err});
        return;
    };
    const elapsed = std.time.milliTimestamp() - start;

    std.debug.print("Response:\n{s}\n\n", .{response.message.content});
    std.debug.print("Tokens: {} total\n", .{response.usage.output_tokens});
    std.debug.print("Time: {}ms\n", .{elapsed});

    const conv_id = "gemini-demo";
    const request = http_sentinel.ai.ResponseManager.Request{
        .prompt = prompt,
        .model = config.model,
        .config = config,
        .allocator = allocator,
    };

    try manager.storeResponse(conv_id, request, response);
    std.debug.print("✅ Stored in response manager\n", .{});
}

fn demoGrokClient(
    allocator: std.mem.Allocator,
    manager: *ResponseManager,
    prompt: []const u8,
) !void {
    std.debug.print("\n{s} Demo 4: Grok (X.AI) {s}\n", .{ "⚡", "-" ** 61 });

    const api_key = std.process.getEnvVarOwned(allocator, "XAI_API_KEY") catch |err| {
        std.debug.print("⚠️  Skipped: XAI_API_KEY not set ({any})\n", .{err});
        return;
    };
    defer allocator.free(api_key);

    var client = GrokClient.init(allocator, api_key);
    defer client.deinit();

    const config = GrokClient.defaultConfig();

    std.debug.print("Model: {s}\n", .{config.model});
    std.debug.print("Prompt: {s}\n\n", .{prompt});

    const start = std.time.milliTimestamp();
    var response = client.sendMessage(prompt, config) catch |err| {
        std.debug.print("❌ Error: {any}\n", .{err});
        return;
    };
    const elapsed = std.time.milliTimestamp() - start;

    std.debug.print("Response:\n{s}\n\n", .{response.message.content});
    std.debug.print("Tokens: {} in, {} out ({} total)\n", .{
        response.usage.input_tokens,
        response.usage.output_tokens,
        response.usage.total(),
    });
    std.debug.print("Time: {}ms\n", .{elapsed});

    const conv_id = "grok-demo";
    const request = http_sentinel.ai.ResponseManager.Request{
        .prompt = prompt,
        .model = config.model,
        .config = config,
        .allocator = allocator,
    };

    try manager.storeResponse(conv_id, request, response);
    std.debug.print("✅ Stored in response manager\n", .{});
}

fn demoVertexClient(
    allocator: std.mem.Allocator,
    manager: *ResponseManager,
    prompt: []const u8,
) !void {
    std.debug.print("\n{s} Demo 5: Vertex AI (Google Cloud) {s}\n", .{ "☁️", "-" ** 48 });

    const project_id = std.process.getEnvVarOwned(allocator, "GCP_PROJECT") catch |err| {
        std.debug.print("⚠️  Skipped: GCP_PROJECT not set ({any})\n", .{err});
        std.debug.print("   Also requires: gcloud auth login\n", .{});
        return;
    };
    defer allocator.free(project_id);

    var client = VertexClient.init(allocator, .{
        .project_id = project_id,
        .location = "us-central1",
    });
    defer client.deinit();

    const config = VertexClient.fastConfig();

    std.debug.print("Model: {s}\n", .{config.model});
    std.debug.print("Project: {s}\n", .{project_id});
    std.debug.print("Prompt: {s}\n\n", .{prompt});

    const start = std.time.milliTimestamp();
    var response = client.sendMessage(prompt, config) catch |err| {
        std.debug.print("❌ Error: {any}\n", .{err});
        std.debug.print("   Make sure you've run: gcloud auth login\n", .{});
        return;
    };
    const elapsed = std.time.milliTimestamp() - start;

    std.debug.print("Response:\n{s}\n\n", .{response.message.content});
    std.debug.print("Tokens: {} total\n", .{response.usage.output_tokens});
    std.debug.print("Time: {}ms\n", .{elapsed});

    const conv_id = "vertex-demo";
    const request = http_sentinel.ai.ResponseManager.Request{
        .prompt = prompt,
        .model = config.model,
        .config = config,
        .allocator = allocator,
    };

    try manager.storeResponse(conv_id, request, response);
    std.debug.print("✅ Stored in response manager\n", .{});
}

fn printSummary(manager: *ResponseManager) !void {
    std.debug.print("\n" ++ "=" ** 80 ++ "\n", .{});
    std.debug.print("  RESPONSE MANAGER SUMMARY\n", .{});
    std.debug.print("=" ** 80 ++ "\n\n", .{});

    const conv_ids = try manager.getAllConversationIds();
    defer {
        for (conv_ids) |id| {
            manager.allocator.free(id);
        }
        manager.allocator.free(conv_ids);
    }

    for (conv_ids) |conv_id| {
        if (manager.getConversationStats(conv_id)) |stats| {
            std.debug.print("Conversation: {s}\n", .{conv_id});
            std.debug.print("  Requests: {}\n", .{stats.total_requests});
            std.debug.print("  Total tokens: {}\n", .{stats.totalTokens()});
            std.debug.print("  Avg latency: {}ms\n\n", .{stats.averageLatencyMs()});
        }
    }
}
