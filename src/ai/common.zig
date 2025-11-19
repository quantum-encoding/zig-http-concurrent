// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Common types and utilities for AI provider clients
//! Provides unified interfaces across Claude, DeepSeek, Gemini, Grok, and Vertex

const std = @import("std");

/// Unified error set for all AI providers
pub const AIError = error{
    // Authentication errors
    AuthenticationFailed,
    InvalidApiKey,

    // API errors
    ApiRequestFailed,
    InvalidResponse,
    JsonParseError,

    // Rate limiting
    RateLimitExceeded,
    QuotaExceeded,

    // Request errors
    InvalidRequest,
    InvalidModel,
    MaxTokensExceeded,

    // Timeout errors
    RequestTimeout,
    ConnectionTimeout,

    // Provider-specific
    ProviderUnavailable,
    ServiceUnavailable,

    // Tool calling
    ToolExecutionFailed,
    MaxTurnsReached,

    // Memory
    OutOfMemory,
};

/// Message role in a conversation
pub const MessageRole = enum {
    user,
    assistant,
    system,
    tool,

    pub fn toString(self: MessageRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .system => "system",
            .tool => "tool",
        };
    }
};

/// Content type in a message
pub const ContentType = enum {
    text,
    image,
    tool_use,
    tool_result,
};

/// A single message in a conversation
pub const AIMessage = struct {
    id: []const u8,
    role: MessageRole,
    content: []const u8,
    timestamp: i64,

    // Optional tool calling data
    tool_calls: ?[]ToolCall = null,
    tool_results: ?[]ToolResult = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *AIMessage) void {
        self.allocator.free(self.id);
        self.allocator.free(self.content);

        if (self.tool_calls) |calls| {
            for (calls) |*call| {
                call.deinit();
            }
            self.allocator.free(calls);
        }

        if (self.tool_results) |results| {
            for (results) |*result| {
                result.deinit();
            }
            self.allocator.free(results);
        }
    }
};

/// Tool call request from the AI
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON string
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolCall) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.arguments);
    }
};

/// Tool execution result
pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
    is_error: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolResult) void {
        self.allocator.free(self.tool_call_id);
        self.allocator.free(self.content);
    }
};

/// Token usage statistics
pub const UsageStats = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_creation_tokens: u32 = 0,

    pub fn total(self: UsageStats) u32 {
        return self.input_tokens + self.output_tokens;
    }

    /// Estimate cost in USD (varies by provider and model)
    pub fn estimateCost(self: UsageStats, input_price_per_mtok: f64, output_price_per_mtok: f64) f64 {
        const input_cost = (@as(f64, @floatFromInt(self.input_tokens)) / 1_000_000.0) * input_price_per_mtok;
        const output_cost = (@as(f64, @floatFromInt(self.output_tokens)) / 1_000_000.0) * output_price_per_mtok;
        return input_cost + output_cost;
    }
};

/// Metadata about the API response
pub const ResponseMetadata = struct {
    model: []const u8,
    provider: []const u8,
    turns_used: u32 = 1,
    execution_time_ms: u64,
    max_turns_reached: bool = false,
    stop_reason: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResponseMetadata) void {
        self.allocator.free(self.model);
        self.allocator.free(self.provider);
        if (self.stop_reason) |reason| {
            self.allocator.free(reason);
        }
    }
};

/// Complete AI response with message and metadata
pub const AIResponse = struct {
    message: AIMessage,
    usage: UsageStats,
    metadata: ResponseMetadata,

    pub fn deinit(self: *AIResponse) void {
        self.message.deinit();
        self.metadata.deinit();
    }
};

/// Configuration for AI requests
pub const RequestConfig = struct {
    /// Model to use (provider-specific)
    model: []const u8,

    /// Maximum tokens to generate
    max_tokens: u32 = 4096,

    /// Sampling temperature (0.0 - 2.0)
    temperature: f32 = 1.0,

    /// Top-p sampling
    top_p: f32 = 1.0,

    /// Stop sequences
    stop_sequences: ?[]const []const u8 = null,

    /// Maximum number of turns for agentic loops
    max_turns: u32 = 100,

    /// Request timeout in milliseconds
    timeout_ms: u64 = 300_000, // 5 minutes default

    /// System prompt (if supported)
    system_prompt: ?[]const u8 = null,
};

/// Conversation context for multi-turn interactions
pub const ConversationContext = struct {
    id: []const u8,
    messages: std.ArrayList(AIMessage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ConversationContext {
        const id = try generateId(allocator);
        return ConversationContext{
            .id = id,
            .messages = std.ArrayList(AIMessage){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConversationContext) void {
        self.allocator.free(self.id);
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit(self.allocator);
    }

    pub fn addMessage(self: *ConversationContext, message: AIMessage) !void {
        try self.messages.append(self.allocator, message);
    }

    pub fn getLastMessage(self: *ConversationContext) ?*AIMessage {
        if (self.messages.items.len == 0) return null;
        return &self.messages.items[self.messages.items.len - 1];
    }

    pub fn totalTokens(self: *ConversationContext) u32 {
        var total: u32 = 0;
        for (self.messages.items) |msg| {
            // Rough estimate: 1 token ≈ 4 characters
            total += @intCast(msg.content.len / 4);
        }
        return total;
    }
};

/// Utility: Generate a unique ID for messages/conversations
pub fn generateId(allocator: std.mem.Allocator) ![]u8 {
    var uuid_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid_bytes);

    // Format as hex string
    const id = try std.fmt.allocPrint(allocator, "{x:0>32}", .{std.mem.readInt(u128, &uuid_bytes, .big)});
    return id;
}

/// Utility: Escape JSON string
pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\x08' => try result.appendSlice(allocator, "\\b"),
            '\x0C' => try result.appendSlice(allocator, "\\f"),
            else => {
                if (char < 0x20) {
                    // Control character - escape as \uXXXX
                    const hex_str = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{char});
                    defer allocator.free(hex_str);
                    try result.appendSlice(allocator, hex_str);
                } else {
                    try result.append(allocator, char);
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Utility: Build Authorization header value
pub fn buildAuthHeader(allocator: std.mem.Allocator, api_key: []const u8, scheme: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ scheme, api_key });
}

/// Utility: Parse error from API response
pub fn parseApiError(response_body: []const u8) AIError {
    // Try to parse JSON error response
    if (std.mem.indexOf(u8, response_body, "rate_limit")) |_| {
        return AIError.RateLimitExceeded;
    }
    if (std.mem.indexOf(u8, response_body, "quota")) |_| {
        return AIError.QuotaExceeded;
    }
    if (std.mem.indexOf(u8, response_body, "authentication") != null or
        std.mem.indexOf(u8, response_body, "unauthorized") != null) {
        return AIError.AuthenticationFailed;
    }
    if (std.mem.indexOf(u8, response_body, "invalid_request")) |_| {
        return AIError.InvalidRequest;
    }

    return AIError.ApiRequestFailed;
}

test "escapeJsonString" {
    const allocator = std.testing.allocator;

    const input = "Hello \"World\"\nNew line\tTab";
    const escaped = try escapeJsonString(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("Hello \\\"World\\\"\\nNew line\\tTab", escaped);
}

test "UsageStats.total" {
    const stats = UsageStats{
        .input_tokens = 100,
        .output_tokens = 50,
    };

    try std.testing.expectEqual(@as(u32, 150), stats.total());
}

test "UsageStats.estimateCost" {
    const stats = UsageStats{
        .input_tokens = 1_000_000,
        .output_tokens = 500_000,
    };

    // Claude Sonnet pricing example: $3/MTok input, $15/MTok output
    const cost = stats.estimateCost(3.0, 15.0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), cost, 0.01);
}
