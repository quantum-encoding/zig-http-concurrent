// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Google Vertex AI client
//! Uses gcloud OAuth2 authentication for enterprise-grade AI
//!
//! Prerequisites: gcloud CLI installed and authenticated
//! - gcloud auth login
//! - gcloud auth application-default login

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

pub const VertexClient = struct {
    http_client: HttpClient,
    project_id: []const u8,
    location: []const u8,
    allocator: std.mem.Allocator,
    access_token: ?[]u8 = null,

    const VERTEX_API_BASE = "https://us-central1-aiplatform.googleapis.com/v1";
    const DEFAULT_LOCATION = "us-central1";
    const MAX_TURNS = 100;

    /// Available Vertex AI models (Gemini on Vertex)
    pub const Models = struct {
        pub const GEMINI_PRO_2_5 = "gemini-2.5-pro";
        pub const GEMINI_FLASH_2_5 = "gemini-2.5-flash";
        pub const GEMINI_FLASH_LITE_2_5 = "gemini-2.5-flash-lite";
    };

    pub const Config = struct {
        project_id: []const u8,
        location: []const u8 = DEFAULT_LOCATION,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !VertexClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .project_id = config.project_id,
            .location = config.location,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VertexClient) void {
        if (self.access_token) |token| {
            self.allocator.free(token);
        }
        self.http_client.deinit();
    }

    /// Get OAuth2 access token from gcloud CLI
    fn getAccessToken(self: *VertexClient) ![]const u8 {
        // Check if we have a cached token
        if (self.access_token) |token| {
            return token;
        }

        // Execute: gcloud auth print-access-token
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "gcloud", "auth", "print-access-token" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("gcloud error: {s}\n", .{result.stderr});
            return common.AIError.AuthenticationFailed;
        }

        // Trim newline and cache token
        const token = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        self.access_token = try self.allocator.dupe(u8, token);
        return self.access_token.?;
    }

    /// Send a single message
    pub fn sendMessage(
        self: *VertexClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *VertexClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        var timer = std.time.Timer.start() catch unreachable;

        // Get access token
        const token = try self.getAccessToken();

        // Build contents array (Gemini format, same as Gemini client)
        var contents = std.ArrayList(u8){};
        defer contents.deinit(self.allocator);

        try contents.appendSlice(self.allocator, "[");

        // Context messages
        for (context, 0..) |msg, i| {
            if (i > 0) try contents.appendSlice(self.allocator, ",");
            try self.appendMessage(&contents, msg);
        }

        // Current prompt
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

            const response = try self.makeRequest(config.model, token, payload);
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
                    .input_tokens = 0, // Vertex doesn't provide breakdown
                    .output_tokens = total_tokens,
                },
                .metadata = .{
                    .model = try self.allocator.dupe(u8, config.model),
                    .provider = try self.allocator.dupe(u8, "vertex"),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                    .allocator = self.allocator,
                },
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    fn buildRequestPayload(
        self: *VertexClient,
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

    fn makeRequest(
        self: *VertexClient,
        model: []const u8,
        access_token: []const u8,
        payload: []const u8,
    ) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/projects/{s}/locations/{s}/publishers/google/models/{s}:generateContent",
            .{ VERTEX_API_BASE, self.project_id, self.location, model },
        );
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{access_token},
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
        self: *VertexClient,
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

    fn appendMessage(self: *VertexClient, writer: *std.ArrayList(u8), msg: common.AIMessage) !void {
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

    /// Helper: Create default config for Gemini Pro on Vertex
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.GEMINI_PRO_2_5,
            .max_tokens = 4096,
            .temperature = 0.7,
        };
    }

    /// Helper: Create config for fast responses
    pub fn fastConfig() common.RequestConfig {
        return .{
            .model = Models.GEMINI_FLASH_2_5,
            .max_tokens = 4096,
            .temperature = 0.7,
        };
    }
};

test "VertexClient initialization" {
    const allocator = std.testing.allocator;

    var client = VertexClient.init(allocator, .{
        .project_id = "test-project",
        .location = "us-central1",
    });
    defer client.deinit();

    try std.testing.expectEqualStrings("test-project", client.project_id);
    try std.testing.expectEqualStrings("us-central1", client.location);
}

test "VertexClient config helpers" {
    const default_cfg = VertexClient.defaultConfig();
    try std.testing.expectEqualStrings(VertexClient.Models.GEMINI_PRO_2_5, default_cfg.model);

    const fast_cfg = VertexClient.fastConfig();
    try std.testing.expectEqualStrings(VertexClient.Models.GEMINI_FLASH_2_5, fast_cfg.model);
}
