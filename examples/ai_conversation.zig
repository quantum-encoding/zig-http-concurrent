// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Conversation example with AI providers
//! Demonstrates multi-turn conversations with context tracking
//!
//! Setup (choose one):
//! export ANTHROPIC_API_KEY=your_key  # For Claude
//! export DEEPSEEK_API_KEY=your_key   # For DeepSeek (recommended for cost)

const std = @import("std");
const http_sentinel = @import("http-sentinel");

const DeepSeekClient = http_sentinel.DeepSeekClient;
const ClaudeClient = http_sentinel.ClaudeClient;
const ConversationContext = http_sentinel.ai.ConversationContext;
const AIMessage = http_sentinel.ai.AIMessage;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n{s} AI CONVERSATION DEMO {s}\n\n", .{ "=" ** 30, "=" ** 30 });

    // Try DeepSeek first (cheaper), fall back to Claude
    const use_deepseek = std.process.hasEnvVar(allocator, "DEEPSEEK_API_KEY") catch false;
    const use_claude = std.process.hasEnvVar(allocator, "ANTHROPIC_API_KEY") catch false;

    if (!use_deepseek and !use_claude) {
        std.debug.print("❌ No API keys found!\n", .{});
        std.debug.print("Please set either DEEPSEEK_API_KEY or ANTHROPIC_API_KEY\n", .{});
        return;
    }

    if (use_deepseek) {
        try runConversationWithDeepSeek(allocator);
    } else {
        try runConversationWithClaude(allocator);
    }

    std.debug.print("\n{s} CONVERSATION COMPLETE {s}\n\n", .{ "=" ** 29, "=" ** 29 });
}

fn runConversationWithDeepSeek(allocator: std.mem.Allocator) !void {
    std.debug.print("🤖 Using DeepSeek (ultra-affordable)\n\n", .{});

    const api_key = try std.process.getEnvVarOwned(allocator, "DEEPSEEK_API_KEY");
    defer allocator.free(api_key);

    var client = DeepSeekClient.init(allocator, api_key);
    defer client.deinit();

    var conversation = try ConversationContext.init(allocator);
    defer conversation.deinit();

    const config = DeepSeekClient.defaultConfig();

    // Turn 1
    std.debug.print("👤 User: What is Zig?\n\n", .{});
    var response1 = try client.sendMessage(
        "What is Zig? Answer in 2 sentences.",
        config,
    );

    std.debug.print("🤖 DeepSeek: {s}\n\n", .{response1.message.content});
    printStats(response1);

    try conversation.addMessage(response1.message);

    // Turn 2 (with context)
    std.debug.print("👤 User: What makes it different from Rust?\n\n", .{});

    // Create user message for context
    const user_msg = AIMessage{
        .id = try http_sentinel.ai.common.generateId(allocator),
        .role = .user,
        .content = try allocator.dupe(u8, "What makes it different from Rust?"),
        .timestamp = std.time.milliTimestamp(),
        .allocator = allocator,
    };

    var response2 = try client.sendMessageWithContext(
        "What makes it different from Rust? Answer in 2 sentences.",
        conversation.messages.items,
        config,
    );

    std.debug.print("🤖 DeepSeek: {s}\n\n", .{response2.message.content});
    printStats(response2);

    try conversation.addMessage(user_msg);
    try conversation.addMessage(response2.message);

    // Turn 3 (with full context)
    std.debug.print("👤 User: Give me a code example\n\n", .{});

    const user_msg2 = AIMessage{
        .id = try http_sentinel.ai.common.generateId(allocator),
        .role = .user,
        .content = try allocator.dupe(u8, "Give me a simple Zig code example"),
        .timestamp = std.time.milliTimestamp(),
        .allocator = allocator,
    };

    var response3 = try client.sendMessageWithContext(
        "Give me a simple Zig code example showing its key features",
        conversation.messages.items,
        config,
    );

    std.debug.print("🤖 DeepSeek:\n{s}\n\n", .{response3.message.content});
    printStats(response3);

    try conversation.addMessage(user_msg2);
    try conversation.addMessage(response3.message);

    // Conversation summary
    std.debug.print("\n📊 Conversation Summary:\n", .{});
    std.debug.print("   Total messages: {}\n", .{conversation.messages.items.len});
    std.debug.print("   Estimated tokens: {}\n", .{conversation.totalTokens()});

    const total_cost = DeepSeekClient.Pricing.calculateCost(.{
        .input_tokens = response1.usage.input_tokens + response2.usage.input_tokens + response3.usage.input_tokens,
        .output_tokens = response1.usage.output_tokens + response2.usage.output_tokens + response3.usage.output_tokens,
    });
    std.debug.print("   Total cost: ${d:.6}\n", .{total_cost});
}

fn runConversationWithClaude(allocator: std.mem.Allocator) !void {
    std.debug.print("🧠 Using Claude\n\n", .{});

    const api_key = try std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY");
    defer allocator.free(api_key);

    var client = ClaudeClient.init(allocator, api_key);
    defer client.deinit();

    var conversation = try ConversationContext.init(allocator);
    defer conversation.deinit();

    const config = ClaudeClient.fastConfig(); // Use Haiku

    // Turn 1
    std.debug.print("👤 User: What is Zig?\n\n", .{});
    var response1 = try client.sendMessage(
        "What is Zig? Answer in 2 sentences.",
        config,
    );

    std.debug.print("🧠 Claude: {s}\n\n", .{response1.message.content});
    printStats(response1);

    try conversation.addMessage(response1.message);

    // Turn 2 (with context)
    std.debug.print("👤 User: What makes it different from Rust?\n\n", .{});

    const user_msg = AIMessage{
        .id = try http_sentinel.ai.common.generateId(allocator),
        .role = .user,
        .content = try allocator.dupe(u8, "What makes it different from Rust?"),
        .timestamp = std.time.milliTimestamp(),
        .allocator = allocator,
    };

    var response2 = try client.sendMessageWithContext(
        "What makes it different from Rust? Answer in 2 sentences.",
        conversation.messages.items,
        config,
    );

    std.debug.print("🧠 Claude: {s}\n\n", .{response2.message.content});
    printStats(response2);

    try conversation.addMessage(user_msg);
    try conversation.addMessage(response2.message);

    // Conversation summary
    std.debug.print("\n📊 Conversation Summary:\n", .{});
    std.debug.print("   Total messages: {}\n", .{conversation.messages.items.len});
    std.debug.print("   Estimated tokens: {}\n", .{conversation.totalTokens()});

    const total_cost = (response1.usage.estimateCost(
        http_sentinel.ai.Pricing.CLAUDE_HAIKU_INPUT,
        http_sentinel.ai.Pricing.CLAUDE_HAIKU_OUTPUT,
    ) + response2.usage.estimateCost(
        http_sentinel.ai.Pricing.CLAUDE_HAIKU_INPUT,
        http_sentinel.ai.Pricing.CLAUDE_HAIKU_OUTPUT,
    ));
    std.debug.print("   Total cost: ${d:.6}\n", .{total_cost});
}

fn printStats(response: anytype) void {
    std.debug.print("   ├─ Tokens: {} in, {} out\n", .{
        response.usage.input_tokens,
        response.usage.output_tokens,
    });
    std.debug.print("   ├─ Time: {}ms\n", .{response.metadata.execution_time_ms});
    std.debug.print("   └─ Turns: {}\n\n", .{response.metadata.turns_used});
}
