// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Anthropic API client implementation
//! Used by both Claude and DeepSeek (DeepSeek supports Anthropic API format)
//!
//! API Documentation:
//! - Claude: https://docs.anthropic.com/
//! - DeepSeek: https://api-docs.deepseek.com/guides/anthropic_api

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

/// Anthropic API client (protocol implementation)
pub const AnthropicClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    base_url: []const u8,
    provider_name: []const u8,
    allocator: std.mem.Allocator,

    const DEFAULT_ANTHROPIC_VERSION = "2023-06-01";
    const MAX_TURNS = 100;

    pub const Config = struct {
        api_key: []const u8,
        base_url: []const u8 = "https://api.anthropic.com",
        provider_name: []const u8 = "anthropic",
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) AnthropicClient {
        return .{
            .http_client = HttpClient.init(allocator),
            .api_key = config.api_key,
            .base_url = config.base_url,
            .provider_name = config.provider_name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnthropicClient) void {
        self.http_client.deinit();
    }

    /// Send a single message
    pub fn sendMessage(
        self: *AnthropicClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *AnthropicClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        const start_time = std.time.milliTimestamp();

        // Build messages array
        var messages = std.ArrayList(std.json.Value){};
        defer messages.deinit(self.allocator);

        // Add context messages
        for (context) |msg| {
            const msg_value = try self.buildMessageJson(msg);
            try messages.append(self.allocator, msg_value);
        }

        // Add current prompt
        try messages.append(self.allocator, try std.json.parseFromSliceLeaky(
            std.json.Value,
            self.allocator,
            try std.fmt.allocPrint(self.allocator,
                \\{{"role":"user","content":"{s}"}}
            , .{try common.escapeJsonString(self.allocator, prompt)}),
            .{},
        ));

        var turn_count: u32 = 0;
        var total_input_tokens: u32 = 0;
        var total_output_tokens: u32 = 0;

        // Agentic loop
        while (turn_count < config.max_turns) : (turn_count += 1) {
            // Build request payload
            const payload = try self.buildRequestPayload(messages.items, config);
            defer self.allocator.free(payload);

            // Make API request
            const response = try self.makeRequest(payload);
            defer self.allocator.free(response);

            // Parse response
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                response,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            // Extract usage
            if (parsed.value.object.get("usage")) |usage_obj| {
                if (usage_obj.object.get("input_tokens")) |input| {
                    total_input_tokens = @intCast(input.integer);
                }
                if (usage_obj.object.get("output_tokens")) |output| {
                    total_output_tokens = @intCast(output.integer);
                }
            }

            // Extract content
            const content_array = parsed.value.object.get("content") orelse
                return common.AIError.InvalidResponse;

            // Check for tool use
            var has_tool_use = false;
            for (content_array.array.items) |block| {
                if (block.object.get("type")) |type_val| {
                    if (std.mem.eql(u8, type_val.string, "tool_use")) {
                        has_tool_use = true;
                        break;
                    }
                }
            }

            if (has_tool_use) {
                // TODO: Implement tool calling support
                // For now, return error
                return common.AIError.ToolExecutionFailed;
            }

            // Extract text response
            var text_content = std.ArrayList(u8).init(self.allocator);
            defer text_content.deinit();

            for (content_array.array.items) |block| {
                if (block.object.get("type")) |type_val| {
                    if (std.mem.eql(u8, type_val.string, "text")) {
                        if (block.object.get("text")) |text_val| {
                            if (text_content.items.len > 0) {
                                try text_content.appendSlice("\n");
                            }
                            try text_content.appendSlice(text_val.string);
                        }
                    }
                }
            }

            const end_time = std.time.milliTimestamp();

            // Build response
            return common.AIResponse{
                .message = .{
                    .id = try self.allocator.dupe(u8,
                        parsed.value.object.get("id").?.string),
                    .role = .assistant,
                    .content = try text_content.toOwnedSlice(),
                    .timestamp = end_time,
                    .allocator = self.allocator,
                },
                .usage = .{
                    .input_tokens = total_input_tokens,
                    .output_tokens = total_output_tokens,
                },
                .metadata = .{
                    .model = try self.allocator.dupe(u8, config.model),
                    .provider = try self.allocator.dupe(u8, self.provider_name),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(end_time - start_time),
                    .max_turns_reached = false,
                    .stop_reason = if (parsed.value.object.get("stop_reason")) |sr|
                        try self.allocator.dupe(u8, sr.string)
                    else
                        null,
                    .allocator = self.allocator,
                },
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    fn buildRequestPayload(
        self: *AnthropicClient,
        messages: []const std.json.Value,
        config: common.RequestConfig,
    ) ![]u8 {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        var writer = payload.writer();

        try writer.writeAll("{");
        try writer.print("\"model\":\"{s}\",", .{config.model});
        try writer.print("\"max_tokens\":{},", .{config.max_tokens});

        // System prompt
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            try writer.print("\"system\":\"{s}\",", .{escaped});
        }

        // Temperature
        try writer.print("\"temperature\":{d},", .{config.temperature});

        // Messages
        try writer.writeAll("\"messages\":[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");

            // Serialize message
            var msg_buf = std.ArrayList(u8).init(self.allocator);
            defer msg_buf.deinit();
            try std.json.stringify(msg, .{}, msg_buf.writer());
            try writer.writeAll(msg_buf.items);
        }
        try writer.writeAll("]");

        try writer.writeAll("}");

        return payload.toOwnedSlice();
    }

    fn makeRequest(self: *AnthropicClient, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/v1/messages",
            .{self.base_url},
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = DEFAULT_ANTHROPIC_VERSION },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        // Check status
        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    fn handleErrorResponse(
        self: *AnthropicClient,
        status: std.http.Status,
        body: []const u8,
    ) common.AIError {
        _ = self;

        return switch (status) {
            .unauthorized, .forbidden => common.AIError.AuthenticationFailed,
            .too_many_requests => common.AIError.RateLimitExceeded,
            .bad_request => common.parseApiError(body),
            else => common.AIError.ApiRequestFailed,
        };
    }

    fn buildMessageJson(self: *AnthropicClient, msg: common.AIMessage) !std.json.Value {
        const role_str = msg.role.toString();
        const escaped_content = try common.escapeJsonString(self.allocator, msg.content);
        defer self.allocator.free(escaped_content);

        const json_str = try std.fmt.allocPrint(
            self.allocator,
            \\{{"role":"{s}","content":"{s}"}}
        ,
            .{ role_str, escaped_content },
        );
        defer self.allocator.free(json_str);

        return try std.json.parseFromSliceLeaky(
            std.json.Value,
            self.allocator,
            json_str,
            .{},
        );
    }
};

test "AnthropicClient initialization" {
    const allocator = std.testing.allocator;

    var client = AnthropicClient.init(allocator, .{
        .api_key = "test-key",
        .base_url = "https://test.example.com",
        .provider_name = "test",
    });
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("https://test.example.com", client.base_url);
}
