// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const HttpClient = @import("http-sentinel").HttpClient;

/// High-Performance AI Client using zig-http-sentinel
/// Demonstrates enterprise-grade HTTP client capabilities with Anthropic's Claude API
/// 
/// This example showcases the production-ready features of zig-http-sentinel:
/// - Robust JSON payload construction and parsing
/// - Professional HTTP header management
/// - Enterprise error handling
/// - High-throughput AI API integration

const AnthropicClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    base_url: []const u8 = "https://api.anthropic.com",
    
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) AnthropicClient {
        return AnthropicClient{
            .http_client = HttpClient.init(allocator),
            .api_key = api_key,
        };
    }
    
    pub fn deinit(self: *AnthropicClient) void {
        self.http_client.deinit();
    }
    
    /// Send a message to Claude and receive a response
    pub fn sendMessage(
        self: *AnthropicClient, 
        model: []const u8,
        user_message: []const u8,
        max_tokens: u32,
    ) !AnthropicResponse {
        const allocator = self.http_client.allocator;
        
        // Construct JSON payload with proper escaping
        const escaped_message = try self.escapeJsonString(allocator, user_message);
        defer allocator.free(escaped_message);
        
        const json_payload = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "model": "{s}",
            \\  "max_tokens": {d},
            \\  "messages": [
            \\    {{
            \\      "role": "user",
            \\      "content": "{s}"
            \\    }}
            \\  ]
            \\}}
        , .{ model, max_tokens, escaped_message });
        defer allocator.free(json_payload);
        
        // Construct headers for Anthropic API
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0 (high-performance-ai-client)" },
        };
        
        // Send request using our production-grade HTTP client
        const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
        defer allocator.free(endpoint);
        
        var response = try self.http_client.post(endpoint, &headers, json_payload);
        defer response.deinit();
        
        // Handle response
        if (response.status != .ok) {
            const error_msg = try std.fmt.allocPrint(allocator, 
                "Anthropic API error: HTTP {d}\nResponse: {s}", 
                .{ @intFromEnum(response.status), response.body }
            );
            defer allocator.free(error_msg);
            std.debug.print("{s}\n", .{error_msg});
            return error.AnthropicApiError;
        }
        
        // Parse JSON response
        const parsed = std.json.parseFromSlice(
            AnthropicApiResponse,
            allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        ) catch |err| {
            std.debug.print("JSON parsing error: {}\nResponse body: {s}\n", .{ err, response.body });
            return error.JsonParseError;
        };
        
        // Extract the response content
        if (parsed.value.content.len == 0) {
            return error.EmptyResponse;
        }
        
        const content_block = parsed.value.content[0];
        if (!std.mem.eql(u8, content_block.type, "text")) {
            return error.UnexpectedContentType;
        }
        
        return AnthropicResponse{
            .content = try allocator.dupe(u8, content_block.text),
            .model = try allocator.dupe(u8, parsed.value.model),
            .usage = UsageStats{
                .input_tokens = parsed.value.usage.input_tokens,
                .output_tokens = parsed.value.usage.output_tokens,
            },
            .allocator = allocator,
            .parsed_response = parsed,
        };
    }
    
    /// Multiple messages conversation
    pub fn conversation(
        self: *AnthropicClient,
        model: []const u8,
        messages: []const ConversationMessage,
        max_tokens: u32,
    ) !AnthropicResponse {
        const allocator = self.http_client.allocator;
        
        // Build messages array JSON
        var messages_json = std.ArrayList(u8){};
        defer messages_json.deinit(allocator);
        
        try messages_json.appendSlice("[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try messages_json.appendSlice(",");
            
            const escaped_content = try self.escapeJsonString(allocator, msg.content);
            defer allocator.free(escaped_content);
            
            const msg_json = try std.fmt.allocPrint(allocator,
                \\{{
                \\  "role": "{s}",
                \\  "content": "{s}"
                \\}}
            , .{ msg.role, escaped_content });
            defer allocator.free(msg_json);
            
            try messages_json.appendSlice(msg_json);
        }
        try messages_json.appendSlice("]");
        
        // Construct full payload
        const json_payload = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "model": "{s}",
            \\  "max_tokens": {d},
            \\  "messages": {s}
            \\}}
        , .{ model, max_tokens, messages_json.items });
        defer allocator.free(json_payload);
        
        // Use same headers and endpoint logic as sendMessage
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0 (conversation-client)" },
        };
        
        const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
        defer allocator.free(endpoint);
        
        var response = try self.http_client.post(endpoint, &headers, json_payload);
        defer response.deinit();
        
        if (response.status != .ok) {
            return error.AnthropicApiError;
        }
        
        const parsed = try std.json.parseFromSlice(
            AnthropicApiResponse,
            allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        );
        
        if (parsed.value.content.len == 0) {
            return error.EmptyResponse;
        }
        
        const content_block = parsed.value.content[0];
        return AnthropicResponse{
            .content = try allocator.dupe(u8, content_block.text),
            .model = try allocator.dupe(u8, parsed.value.model),
            .usage = UsageStats{
                .input_tokens = parsed.value.usage.input_tokens,
                .output_tokens = parsed.value.usage.output_tokens,
            },
            .allocator = allocator,
            .parsed_response = parsed,
        };
    }
    
    fn escapeJsonString(self: *AnthropicClient, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        _ = self;
        
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);
        
        for (input) |char| {
            switch (char) {
                '"' => try result.appendSlice("\\\""),
                '\\' => try result.appendSlice("\\\\"),
                '\n' => try result.appendSlice("\\n"),
                '\r' => try result.appendSlice("\\r"),
                '\t' => try result.appendSlice("\\t"),
                else => try result.append(char),
            }
        }
        
        return result.toOwnedSlice();
    }
};

/// Anthropic API response structures (production-grade type definitions)
const AnthropicApiResponse = struct {
    id: []const u8,
    type: []const u8,
    role: []const u8,
    model: []const u8,
    content: []ContentBlock,
    stop_reason: ?[]const u8 = null,
    stop_sequence: ?[]const u8 = null,
    usage: Usage,
};

const ContentBlock = struct {
    type: []const u8,
    text: []const u8,
};

const Usage = struct {
    input_tokens: u32,
    output_tokens: u32,
};

/// Public response interface
const AnthropicResponse = struct {
    content: []const u8,
    model: []const u8,
    usage: UsageStats,
    allocator: std.mem.Allocator,
    parsed_response: std.json.Parsed(AnthropicApiResponse),
    
    pub fn deinit(self: *AnthropicResponse) void {
        self.allocator.free(self.content);
        self.allocator.free(self.model);
        self.parsed_response.deinit();
    }
};

const UsageStats = struct {
    input_tokens: u32,
    output_tokens: u32,
};

const ConversationMessage = struct {
    role: []const u8, // "user" or "assistant"
    content: []const u8,
};

/// Demonstration of enterprise AI capabilities
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Zig HTTP Sentinel: High-Performance AI Client ===\n\n", .{});
    
    // Get API key from environment
    const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {
                std.debug.print("❌ ANTHROPIC_API_KEY environment variable not set\n", .{});
                std.debug.print("Please set your API key: export ANTHROPIC_API_KEY=your_key_here\n", .{});
                std.debug.print("Get your key from: https://console.anthropic.com/\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer allocator.free(api_key);
    
    // Initialize our enterprise-grade AI client
    var client = AnthropicClient.init(allocator, api_key);
    defer client.deinit();
    
    std.debug.print("🚀 Initializing high-performance AI client...\n", .{});
    std.debug.print("📡 Using zig-http-sentinel for enterprise-grade HTTP operations\n\n", .{});
    
    // Demonstration 1: Production message processing
    try demonstrateBasicChat(&client);
    
    // Demonstration 2: Multi-turn conversation
    try demonstrateConversation(&client);
    
    // Demonstration 3: Technical analysis
    try demonstrateTechnicalCapabilities(&client);
    
    std.debug.print("\n✅ All demonstrations completed successfully!\n", .{});
    std.debug.print("💎 zig-http-sentinel: Enterprise-grade HTTP client for production AI systems\n", .{});
}

fn demonstrateBasicChat(client: *AnthropicClient) !void {
    std.debug.print("📝 Demo 1: Production Message Processing\n", .{});
    
    var response = client.sendMessage(
        "claude-3-haiku-20240307",
        "Explain why Zig is an excellent choice for building high-performance HTTP clients in exactly 50 words.",
        256,
    ) catch |err| {
        std.debug.print("❌ API call failed: {}\n", .{err});
        return;
    };
    defer response.deinit();
    
    std.debug.print("🤖 Claude ({s}):\n{s}\n", .{ response.model, response.content });
    std.debug.print("📊 Tokens: {} in, {} out\n\n", .{ response.usage.input_tokens, response.usage.output_tokens });
}

fn demonstrateConversation(client: *AnthropicClient) !void {
    std.debug.print("💬 Demo 2: Multi-Turn Conversation\n", .{});
    
    const messages = [_]ConversationMessage{
        .{ .role = "user", .content = "What makes a great HTTP client library?" },
        .{ .role = "assistant", .content = "A great HTTP client should be thread-safe, memory-efficient, handle errors gracefully, support connection pooling, and provide a clean API." },
        .{ .role = "user", .content = "How does zig-http-sentinel achieve these goals?" },
    };
    
    var response = client.conversation(
        "claude-3-haiku-20240307",
        &messages,
        300,
    ) catch |err| {
        std.debug.print("❌ Conversation failed: {}\n", .{err});
        return;
    };
    defer response.deinit();
    
    std.debug.print("🤖 Claude ({s}):\n{s}\n", .{ response.model, response.content });
    std.debug.print("📊 Tokens: {} in, {} out\n\n", .{ response.usage.input_tokens, response.usage.output_tokens });
}

fn demonstrateTechnicalCapabilities(client: *AnthropicClient) !void {
    std.debug.print("⚡ Demo 3: Technical Analysis\n", .{});
    
    const technical_query = 
        \\Analyze this Zig HTTP client design pattern:
        \\
        \\```zig
        \\pub const Response = struct {
        \\    status: http.Status,
        \\    body: []u8,
        \\    allocator: std.mem.Allocator,
        \\    
        \\    pub fn deinit(self: *Response) void {
        \\        self.allocator.free(self.body);
        \\    }
        \\};
        \\```
        \\
        \\What are the key advantages of this approach for memory management in high-performance systems?
    ;
    
    var response = client.sendMessage(
        "claude-3-haiku-20240307",
        technical_query,
        400,
    ) catch |err| {
        std.debug.print("❌ Technical analysis failed: {}\n", .{err});
        return;
    };
    defer response.deinit();
    
    std.debug.print("🤖 Claude ({s}):\n{s}\n", .{ response.model, response.content });
    std.debug.print("📊 Tokens: {} in, {} out\n", .{ response.usage.input_tokens, response.usage.output_tokens });
}