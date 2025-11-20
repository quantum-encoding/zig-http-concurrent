// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Google Gemini AI client
//! Direct access to Gemini API using API key authentication
//!
//! API Documentation: https://ai.google.dev/docs

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

pub const GeminiClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta";
    const MAX_TURNS = 100;

    /// Available Gemini models
    pub const Models = struct {
        pub const PRO_2_5 = "gemini-2.5-pro";
        pub const FLASH_2_5 = "gemini-2.5-flash";
        pub const FLASH_LITE_2_5 = "gemini-2.5-flash-lite";
    };

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !GeminiClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GeminiClient) void {
        self.http_client.deinit();
    }

    /// Send a single message
    pub fn sendMessage(
        self: *GeminiClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *GeminiClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        var timer = std.time.Timer.start() catch unreachable;

        // Build contents array (Gemini format)
        var contents = std.ArrayList(u8){};
        defer contents.deinit(self.allocator);

        try contents.appendSlice(self.allocator, "[");

        // Add context messages
        for (context, 0..) |msg, i| {
            if (i > 0) try contents.appendSlice(self.allocator, ",");
            try self.appendMessage(&contents, msg);
        }

        // Add current prompt
        if (context.len > 0) try contents.appendSlice(self.allocator, ",");
        const escaped_prompt = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped_prompt);
        const prompt_json = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"user","parts":[{{"text":"{s}"}}]}}
        , .{escaped_prompt});
        defer self.allocator.free(prompt_json);
        try contents.appendSlice(self.allocator, prompt_json);

        try contents.appendSlice(self.allocator, "]");

        var turn_count: u32 = 0;
        var total_tokens: u32 = 0;

        // Agentic loop
        while (turn_count < config.max_turns) : (turn_count += 1) {
            const payload = try self.buildRequestPayload(contents.items, config);
            defer self.allocator.free(payload);

            const response = try self.makeRequest(config.model, payload);
            defer self.allocator.free(response);

            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                response,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            // Extract usage
            if (parsed.value.object.get("usageMetadata")) |usage| {
                if (usage.object.get("totalTokenCount")) |total| {
                    total_tokens = @intCast(total.integer);
                }
            }

            // Extract candidates
            const candidates = parsed.value.object.get("candidates") orelse
                return common.AIError.InvalidResponse;

            if (candidates.array.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            const candidate = candidates.array.items[0];
            const content = candidate.object.get("content") orelse
                return common.AIError.InvalidResponse;

            const parts = content.object.get("parts") orelse
                return common.AIError.InvalidResponse;

            // Check for function calls
            var has_function_call = false;
            for (parts.array.items) |part| {
                if (part.object.get("functionCall")) |_| {
                    has_function_call = true;
                    break;
                }
            }

            if (has_function_call) {
                // TODO: Implement function calling support
                return common.AIError.ToolExecutionFailed;
            }

            // Extract text response
            var text_content = std.ArrayList(u8){};
            defer text_content.deinit(self.allocator);

            for (parts.array.items) |part| {
                if (part.object.get("text")) |text| {
                    if (text_content.items.len > 0) {
                        try text_content.appendSlice(self.allocator, "\n");
                    }
                    try text_content.appendSlice(self.allocator, text.string);
                }
            }

            if (text_content.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            const elapsed_ns = timer.read();

            return common.AIResponse{
                .message = .{
                    .id = try common.generateId(self.allocator),
                    .role = .assistant,
                    .content = try text_content.toOwnedSlice(self.allocator),
                    .timestamp = (std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec,
                    .allocator = self.allocator,
                },
                .usage = .{
                    .input_tokens = 0, // Gemini doesn't provide breakdown
                    .output_tokens = total_tokens,
                },
                .metadata = .{
                    .model = try self.allocator.dupe(u8, config.model),
                    .provider = try self.allocator.dupe(u8, "gemini"),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                    .allocator = self.allocator,
                },
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    fn buildRequestPayload(
        self: *GeminiClient,
        contents: []const u8,
        config: common.RequestConfig,
    ) ![]u8 {
        var payload = std.ArrayList(u8){};
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{");

        const contents_part = try std.fmt.allocPrint(self.allocator, "\"contents\":{s},", .{contents});
        defer self.allocator.free(contents_part);
        try payload.appendSlice(self.allocator, contents_part);

        // System instruction
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\"systemInstruction":{{"parts":[{{"text":"{s}"}}]}},
            , .{escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        // Generation config
        const gen_config = try std.fmt.allocPrint(self.allocator,
            \\"generationConfig":{{"temperature":{d},"maxOutputTokens":{},"topP":{d}}}
        , .{ config.temperature, config.max_tokens, config.top_p });
        defer self.allocator.free(gen_config);
        try payload.appendSlice(self.allocator, gen_config);

        try payload.appendSlice(self.allocator, "}");

        return payload.toOwnedSlice(self.allocator);
    }

    fn makeRequest(self: *GeminiClient, model: []const u8, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/models/{s}:generateContent?key={s}",
            .{ GEMINI_API_BASE, model, self.api_key },
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    fn handleErrorResponse(
        self: *GeminiClient,
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

    fn appendMessage(self: *GeminiClient, writer: *std.ArrayList(u8), msg: common.AIMessage) !void {
        const role = switch (msg.role) {
            .user => "user",
            .assistant => "model",
            else => "user",
        };

        const escaped = try common.escapeJsonString(self.allocator, msg.content);
        defer self.allocator.free(escaped);

        const msg_json = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"{s}","parts":[{{"text":"{s}"}}]}}
        , .{ role, escaped });
        defer self.allocator.free(msg_json);
        try writer.appendSlice(self.allocator, msg_json);
    }

    /// Helper: Create default config for Gemini Pro
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.PRO_2_5,
            .max_tokens = 8192,
            .temperature = 1.0,
        };
    }

    /// Helper: Create config for fast responses (Flash)
    pub fn fastConfig() common.RequestConfig {
        return .{
            .model = Models.FLASH_2_5,
            .max_tokens = 8192,
            .temperature = 1.0,
        };
    }

    /// Helper: Create config for ultra-fast responses (Flash Lite)
    pub fn ultraFastConfig() common.RequestConfig {
        return .{
            .model = Models.FLASH_LITE_2_5,
            .max_tokens = 4096,
            .temperature = 1.0,
        };
    }
};

test "GeminiClient initialization" {
    const allocator = std.testing.allocator;

    var client = GeminiClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
}

test "GeminiClient config helpers" {
    const default_cfg = GeminiClient.defaultConfig();
    try std.testing.expectEqualStrings(GeminiClient.Models.PRO_2_5, default_cfg.model);

    const fast_cfg = GeminiClient.fastConfig();
    try std.testing.expectEqualStrings(GeminiClient.Models.FLASH_2_5, fast_cfg.model);

    const ultra_fast_cfg = GeminiClient.ultraFastConfig();
    try std.testing.expectEqualStrings(GeminiClient.Models.FLASH_LITE_2_5, ultra_fast_cfg.model);
}
