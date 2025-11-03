# AI Provider Clients for Zig

High-performance, production-ready AI provider clients built on **zig-http-sentinel**.

## Supported Providers

| Provider | Models | Pricing (per 1M tokens) | Features |
|----------|--------|------------------------|----------|
| **Claude** (Anthropic) | Sonnet 4.5, Opus 4.1, Haiku | $3-$75 | Excellent reasoning, long context |
| **DeepSeek** | Chat, Reasoner | $0.14-$0.28 | **95% cheaper**, Anthropic-compatible |
| **Gemini** (Google) | Pro 2.5, Flash 2.5 | $0.075-$5 | Fast, multimodal |
| **Grok** (X.AI) | Code Fast/Deep | $5-$15 | Optimized for code |
| **Vertex AI** (GCP) | Gemini on Vertex | Varies | Enterprise features, OAuth2 |

## Quick Start

### Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .@"http-sentinel" = .{
        .url = "https://github.com/yourusername/zig-http-concurrent/archive/main.tar.gz",
        .hash = "...",
    },
},
```

### Basic Usage

```zig
const std = @import("std");
const http_sentinel = @import("http-sentinel");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get API key from environment
    const api_key = try std.process.getEnvVarOwned(allocator, "DEEPSEEK_API_KEY");
    defer allocator.free(api_key);

    // Initialize client
    var client = http_sentinel.DeepSeekClient.init(allocator, api_key);
    defer client.deinit();

    // Send a message
    var response = try client.sendMessage(
        "Explain Zig's allocator pattern in 2 sentences",
        http_sentinel.DeepSeekClient.defaultConfig(),
    );
    defer response.deinit();

    std.debug.print("Response: {s}\n", .{response.message.content});
    std.debug.print("Tokens: {} in, {} out\n", .{
        response.usage.input_tokens,
        response.usage.output_tokens,
    });
}
```

## Provider Setup

### Claude (Anthropic)

```bash
export ANTHROPIC_API_KEY=your_key_here
```

```zig
var client = http_sentinel.ClaudeClient.init(allocator, api_key);
defer client.deinit();

// Choose model/config
const config = http_sentinel.ClaudeClient.fastConfig();      // Haiku - fast & cheap
// const config = http_sentinel.ClaudeClient.defaultConfig(); // Sonnet - balanced
// const config = http_sentinel.ClaudeClient.deepConfig();    // Opus - most capable

var response = try client.sendMessage(prompt, config);
```

### DeepSeek (Recommended for Cost)

DeepSeek uses Anthropic's API format but at **95% lower cost**!

```bash
export DEEPSEEK_API_KEY=your_key_here
```

```zig
var client = http_sentinel.DeepSeekClient.init(allocator, api_key);
defer client.deinit();

var response = try client.sendMessage(prompt, .{
    .model = http_sentinel.DeepSeekClient.Models.CHAT,
    .max_tokens = 8000,
    .temperature = 1.0,
});
```

**Cost comparison** (1M tokens):
- Claude Sonnet: $3 input / $15 output
- DeepSeek: $0.14 input / $0.28 output (**95% cheaper!**)

### Gemini (Google)

```bash
export GENAI_API_KEY=your_key_here
# or
export GEMINI_API_KEY=your_key_here
```

```zig
var client = http_sentinel.GeminiClient.init(allocator, api_key);
defer client.deinit();

const config = http_sentinel.GeminiClient.fastConfig(); // Flash
var response = try client.sendMessage(prompt, config);
```

### Grok (X.AI)

```bash
export XAI_API_KEY=your_key_here
```

```zig
var client = http_sentinel.GrokClient.init(allocator, api_key);
defer client.deinit();

var response = try client.sendMessage(prompt, .{
    .model = http_sentinel.GrokClient.Models.CODE_FAST_1,
    .max_tokens = 8000,
    .temperature = 0.7,
});
```

### Vertex AI (Google Cloud)

Requires `gcloud` CLI:

```bash
gcloud auth login
gcloud auth application-default login
export GCP_PROJECT=your-project-id
```

```zig
var client = http_sentinel.VertexClient.init(allocator, .{
    .project_id = "your-project-id",
    .location = "us-central1",
});
defer client.deinit();

var response = try client.sendMessage(prompt, config);
```

## Advanced Features

### Multi-turn Conversations

```zig
var conversation = try http_sentinel.ai.ConversationContext.init(allocator);
defer conversation.deinit();

// Turn 1
var response1 = try client.sendMessage("What is Zig?", config);
try conversation.addMessage(response1.message);

// Turn 2 (with context)
var response2 = try client.sendMessageWithContext(
    "What makes it different from Rust?",
    conversation.messages.items,
    config,
);
try conversation.addMessage(response2.message);
```

### Response Management

Track all AI interactions across providers:

```zig
var manager = http_sentinel.ResponseManager.init(allocator);
defer manager.deinit();

// Store responses
const conv_id = "my-conversation";
const request = .{
    .prompt = prompt,
    .model = config.model,
    .config = config,
    .allocator = allocator,
};

try manager.storeResponse(conv_id, request, response);

// Get statistics
if (manager.getConversationStats(conv_id)) |stats| {
    std.debug.print("Total requests: {}\n", .{stats.total_requests});
    std.debug.print("Total tokens: {}\n", .{stats.totalTokens()});
    std.debug.print("Average latency: {}ms\n", .{stats.averageLatencyMs()});
}

// Export to JSON
var file = try std.fs.cwd().createFile("conversation.json", .{});
defer file.close();
try manager.exportConversationJson(conv_id, file.writer());

// Export to Markdown
var md_file = try std.fs.cwd().createFile("conversation.md", .{});
defer md_file.close();
try manager.exportConversationMarkdown(conv_id, md_file.writer());
```

### Unified AI Client

Use any provider with a single interface:

```zig
// Initialize for any provider
var client = http_sentinel.AIClient.init(allocator, .deepseek, .{
    .api_key = api_key,
});
defer client.deinit();

// Use the same API regardless of provider
var response = try client.sendMessage(prompt, config);
```

### Cost Estimation

```zig
const usage = response.usage;

// DeepSeek
const deepseek_cost = http_sentinel.DeepSeekClient.Pricing.calculateCost(usage);

// Claude
const claude_cost = usage.estimateCost(
    http_sentinel.ai.Pricing.CLAUDE_SONNET_INPUT,
    http_sentinel.ai.Pricing.CLAUDE_SONNET_OUTPUT,
);

std.debug.print("DeepSeek: ${d:.6}\n", .{deepseek_cost});
std.debug.print("Claude: ${d:.6}\n", .{claude_cost});
std.debug.print("Savings: {d:.1}%\n", .{(1.0 - deepseek_cost / claude_cost) * 100});
```

## Error Handling

```zig
const response = client.sendMessage(prompt, config) catch |err| {
    switch (err) {
        error.AuthenticationFailed => {
            std.debug.print("Invalid API key\n", .{});
        },
        error.RateLimitExceeded => {
            std.debug.print("Rate limit hit, retry later\n", .{});
        },
        error.MaxTokensExceeded => {
            std.debug.print("Prompt too large\n", .{});
        },
        else => {
            std.debug.print("API error: {}\n", .{err});
        },
    }
    return err;
};
```

## Examples

Run the provided examples:

```bash
# Comprehensive demo of all providers
zig build run-ai-demo

# Multi-turn conversation example
zig build run-ai-conversation
```

## Architecture

### Common Types
- `AIError` - Unified error types
- `AIMessage` - Message with role, content, timestamp
- `AIResponse` - Complete response with usage stats
- `RequestConfig` - Model, temperature, max_tokens, etc.
- `UsageStats` - Token counts and cost estimation

### Provider Clients
Each client implements:
- `init(allocator, config)` - Initialize with credentials
- `deinit()` - Clean up resources
- `sendMessage(prompt, config)` - Single-turn request
- `sendMessageWithContext(prompt, context, config)` - Multi-turn with history
- `defaultConfig()` / `fastConfig()` / etc. - Preset configurations

### Response Manager
- Thread-safe response storage
- Conversation tracking
- Statistics aggregation
- JSON/Markdown export

## Performance

All clients use **zig-http-sentinel** for maximum performance:
- Zero-copy operations where possible
- Connection pooling (optional)
- Automatic retry with exponential backoff
- Thread-safe by design
- Minimal allocations

## Future Features

- [x] Core AI client implementations
- [x] Response management system
- [x] Multi-turn conversations
- [ ] Streaming responses
- [ ] Tool/function calling support
- [ ] Vision/multimodal inputs
- [ ] Batch request processing
- [ ] Connection pooling for AI requests
- [ ] Automatic retry strategies per provider

## Contributing

Contributions welcome! Please ensure:
1. All tests pass: `zig build test`
2. Examples compile: `zig build`
3. Code follows existing patterns
4. Add tests for new features

## License

MIT License - see LICENSE file for details.

---

Built with ❤️ using Zig and zig-http-sentinel
