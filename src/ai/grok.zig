// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! X.AI Grok client
//! OpenAI-compatible API for Grok models
//!
//! API Documentation: https://docs.x.ai/api

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

pub const GrokClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    const GROK_API_BASE = "https://api.x.ai/v1";
    const MAX_TURNS = 100;

    /// Available Grok models
    pub const Models = struct {
        pub const CODE_FAST_1 = "grok-code-fast-1";
        pub const CODE_DEEP_1 = "grok-code-deep-1";
    };

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !GrokClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GrokClient) void {
        self.http_client.deinit();
    }

    /// Send a single message
    pub fn sendMessage(
        self: *GrokClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *GrokClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        var timer = std.time.Timer.start() catch unreachable;

        // Build messages array (OpenAI format)
        var messages = std.ArrayList(u8){};
        defer messages.deinit(self.allocator);

        try messages.appendSlice(self.allocator, "[");

        // System message
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            const sys_msg = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"system","content":"{s}"}}
            , .{escaped});
            defer self.allocator.free(sys_msg);
            try messages.appendSlice(self.allocator, sys_msg);
        }

        // Context messages
        for (context) |msg| {
            if (messages.items.len > 1) try messages.appendSlice(self.allocator, ",");
            try self.appendMessage(&messages, msg);
        }

        // Current prompt
        if (messages.items.len > 1) try messages.appendSlice(self.allocator, ",");
        const escaped_prompt = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped_prompt);
        const prompt_msg = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"user","content":"{s}"}}
        , .{escaped_prompt});
        defer self.allocator.free(prompt_msg);
        try messages.appendSlice(self.allocator, prompt_msg);

        try messages.appendSlice(self.allocator, "]");

        var turn_count: u32 = 0;
        var total_input_tokens: u32 = 0;
        var total_output_tokens: u32 = 0;

        // Agentic loop
        while (turn_count < config.max_turns) : (turn_count += 1) {
            const payload = try self.buildRequestPayload(messages.items, config);
            defer self.allocator.free(payload);

            const response = try self.makeRequest(payload);
            defer self.allocator.free(response);

            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                response,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            // Extract usage
            if (parsed.value.object.get("usage")) |usage| {
                if (usage.object.get("prompt_tokens")) |prompt_tokens| {
                    total_input_tokens = @intCast(prompt_tokens.integer);
                }
                if (usage.object.get("completion_tokens")) |completion_tokens| {
                    total_output_tokens = @intCast(completion_tokens.integer);
                }
            }

            // Extract choices
            const choices = parsed.value.object.get("choices") orelse
                return common.AIError.InvalidResponse;

            if (choices.array.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            const choice = choices.array.items[0];
            const message = choice.object.get("message") orelse
                return common.AIError.InvalidResponse;

            // Check for tool calls
            if (message.object.get("tool_calls")) |tool_calls| {
                if (tool_calls.array.items.len > 0) {
                    // TODO: Implement tool calling support
                    return common.AIError.ToolExecutionFailed;
                }
            }

            // Extract content
            const content = message.object.get("content") orelse
                return common.AIError.InvalidResponse;

            const elapsed_ns = timer.read();

            return common.AIResponse{
                .message = .{
                    .id = if (parsed.value.object.get("id")) |id|
                        try self.allocator.dupe(u8, id.string)
                    else
                        try common.generateId(self.allocator),
                    .role = .assistant,
                    .content = try self.allocator.dupe(u8, content.string),
                    .timestamp = (std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec,
                    .allocator = self.allocator,
                },
                .usage = .{
                    .input_tokens = total_input_tokens,
                    .output_tokens = total_output_tokens,
                },
                .metadata = .{
                    .model = try self.allocator.dupe(u8, config.model),
                    .provider = try self.allocator.dupe(u8, "grok"),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                    .stop_reason = if (choice.object.get("finish_reason")) |reason|
                        try self.allocator.dupe(u8, reason.string)
                    else
                        null,
                    .allocator = self.allocator,
                },
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    fn buildRequestPayload(
        self: *GrokClient,
        messages: []const u8,
        config: common.RequestConfig,
    ) ![]u8 {
        return std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","messages":{s},"temperature":{d},"max_tokens":{},"stream":false}}
        , .{ config.model, messages, config.temperature, config.max_tokens });
    }

    fn makeRequest(self: *GrokClient, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/chat/completions",
            .{GROK_API_BASE},
        );
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.api_key},
        );
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    fn handleErrorResponse(
        self: *GrokClient,
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

    fn appendMessage(self: *GrokClient, writer: *std.ArrayList(u8), msg: common.AIMessage) !void {
        const role = msg.role.toString();
        const escaped = try common.escapeJsonString(self.allocator, msg.content);
        defer self.allocator.free(escaped);

        const msg_json = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"{s}","content":"{s}"}}
        , .{ role, escaped });
        defer self.allocator.free(msg_json);
        try writer.appendSlice(self.allocator, msg_json);
    }

    /// Helper: Create default config for Grok Code Fast
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.CODE_FAST_1,
            .max_tokens = 8000,
            .temperature = 0.7,
        };
    }

    /// Helper: Create config for deep code analysis
    pub fn deepConfig() common.RequestConfig {
        return .{
            .model = Models.CODE_DEEP_1,
            .max_tokens = 8000,
            .temperature = 0.7,
        };
    }
};

test "GrokClient initialization" {
    const allocator = std.testing.allocator;

    var client = GrokClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
}

test "GrokClient config helpers" {
    const default_cfg = GrokClient.defaultConfig();
    try std.testing.expectEqualStrings(GrokClient.Models.CODE_FAST_1, default_cfg.model);

    const deep_cfg = GrokClient.deepConfig();
    try std.testing.expectEqualStrings(GrokClient.Models.CODE_DEEP_1, deep_cfg.model);
}
