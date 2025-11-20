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

    pub fn init(allocator: std.mem.Allocator, config: Config) !AnthropicClient {
        return .{
            .http_client = try HttpClient.init(allocator),
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
        var timer = std.time.Timer.start() catch unreachable;

        // Build messages array
        var messages = std.ArrayList(std.json.Value){};
        defer messages.deinit(self.allocator);

        // Track parsed JSON objects for cleanup
        var parsed_objects = std.ArrayList(std.json.Parsed(std.json.Value)){};
        defer {
            for (parsed_objects.items) |*parsed| {
                parsed.deinit();
            }
            parsed_objects.deinit(self.allocator);
        }

        // Add context messages
        for (context) |msg| {
            var parsed = try self.buildMessageJson(msg);
            try parsed_objects.append(self.allocator, parsed);
            try messages.append(self.allocator, parsed.value);
        }

        // Add current prompt
        const escaped_prompt = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped_prompt);
        const prompt_json = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"user","content":"{s}"}}
        , .{escaped_prompt});
        defer self.allocator.free(prompt_json);
        var prompt_parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            prompt_json,
            .{},
        );
        try parsed_objects.append(self.allocator, prompt_parsed);
        try messages.append(self.allocator, prompt_parsed.value);

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
            var text_content = std.ArrayList(u8){};
            defer text_content.deinit(self.allocator);

            for (content_array.array.items) |block| {
                if (block.object.get("type")) |type_val| {
                    if (std.mem.eql(u8, type_val.string, "text")) {
                        if (block.object.get("text")) |text_val| {
                            if (text_content.items.len > 0) {
                                try text_content.appendSlice(self.allocator, "\n");
                            }
                            try text_content.appendSlice(self.allocator, text_val.string);
                        }
                    }
                }
            }

            const elapsed_ns = timer.read();

            // Build response
            return common.AIResponse{
                .message = .{
                    .id = try self.allocator.dupe(u8,
                        parsed.value.object.get("id").?.string),
                    .role = .assistant,
                    .content = try text_content.toOwnedSlice(self.allocator),
                    .timestamp = (std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec,
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
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
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
        var payload = std.ArrayList(u8){};
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{");

        const model_part = try std.fmt.allocPrint(self.allocator, "\"model\":\"{s}\",", .{config.model});
        defer self.allocator.free(model_part);
        try payload.appendSlice(self.allocator, model_part);

        const tokens_part = try std.fmt.allocPrint(self.allocator, "\"max_tokens\":{},", .{config.max_tokens});
        defer self.allocator.free(tokens_part);
        try payload.appendSlice(self.allocator, tokens_part);

        // System prompt
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator, "\"system\":\"{s}\",", .{escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        // Temperature
        const temp_part = try std.fmt.allocPrint(self.allocator, "\"temperature\":{d},", .{config.temperature});
        defer self.allocator.free(temp_part);
        try payload.appendSlice(self.allocator, temp_part);

        // Messages
        try payload.appendSlice(self.allocator, "\"messages\":[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try payload.appendSlice(self.allocator, ",");

            // Serialize message using a temporary buffer
            var msg_buf = std.ArrayList(u8){};
            defer msg_buf.deinit(self.allocator);

            var msg_writer = std.Io.Writer.Allocating.init(self.allocator);
            defer msg_writer.deinit();

            var stringify: std.json.Stringify = .{
                .writer = &msg_writer.writer,
                .options = .{},
            };
            try stringify.write(msg);

            try payload.appendSlice(self.allocator, msg_writer.written());
        }
        try payload.appendSlice(self.allocator, "]");

        try payload.appendSlice(self.allocator, "}");

        return payload.toOwnedSlice(self.allocator);
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

    fn buildMessageJson(self: *AnthropicClient, msg: common.AIMessage) !std.json.Parsed(std.json.Value) {
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

        return try std.json.parseFromSlice(
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
