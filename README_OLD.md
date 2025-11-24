# Zig HTTP Sentinel

A robust, thread-safe HTTP client library for Zig 0.16.0, battle-tested in production environments.

> **Note**: This library was extracted from production high-frequency trading systems where reliability and performance are critical.

**Developed by [QUANTUM ENCODING LTD](https://quantumencoding.io)**  
Contact: [rich@quantumencoding.io](mailto:rich@quantumencoding.io)

## Features

- **Production-Grade API**: Enterprise-level interface for all HTTP operations
- **Thread-Safe**: Designed for concurrent use (each thread should use its own client instance)
- **Memory-Safe**: Automatic memory management with proper cleanup
- **Full HTTP Support**: GET, POST, PUT, PATCH, DELETE, HEAD methods
- **Configurable**: Customizable request options including timeouts and body size limits
- **Production-Ready**: Extensively tested under high-load conditions

### Optional Advanced Modules

- **Retry Engine**: Battle-tested resilience patterns including exponential backoff, circuit breakers, and adaptive retry strategies
- **Connection Pool**: Enterprise-grade connection pooling with health monitoring, load balancing, and multi-host support

## Installation

Add this library to your `build.zig.zon`:

```zig
.dependencies = .{
    .http_sentinel = .{
        .url = "https://github.com/YOUR_USERNAME/zig-http-sentinel/archive/refs/tags/v1.0.0.tar.gz",
        .hash = "YOUR_HASH_HERE",
    },
},
```

Then in your `build.zig`:

```zig
const http_sentinel = b.dependency("http_sentinel", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("http-sentinel", http_sentinel.module("http-sentinel"));
```

## Production Deployment

```zig
const std = @import("std");
const HttpClient = @import("http-sentinel").HttpClient;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = HttpClient.init(allocator);
    defer client.deinit();

    // Make a GET request
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
    };
    
    var response = try client.get("https://api.example.com/data", &headers);
    defer response.deinit();

    std.debug.print("Status: {}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
}
```

## API Reference

### Enterprise Client Initialization

```zig
var client = HttpClient.init(allocator);
defer client.deinit();
```

### HTTP Methods

All methods return a `Response` struct that must be deinitialized:

```zig
pub const Response = struct {
    status: http.Status,
    body: []u8,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *Response) void;
};
```

#### GET Request
```zig
var response = try client.get(url, headers);
defer response.deinit();
```

#### POST Request
```zig
var response = try client.post(url, headers, body);
defer response.deinit();
```

#### PUT Request
```zig
var response = try client.put(url, headers, body);
defer response.deinit();
```

#### PATCH Request
```zig
var response = try client.patch(url, headers, body);
defer response.deinit();
```

#### DELETE Request
```zig
var response = try client.delete(url, headers);
defer response.deinit();
```

#### HEAD Request
```zig
var response = try client.head(url, headers);
defer response.deinit();
```

### Advanced Options

For more control, use the `WithOptions` variants:

```zig
const options = HttpClient.RequestOptions{
    .max_body_size = 50 * 1024 * 1024, // 50MB
    .timeout_ns = 30 * std.time.ns_per_s, // 30 seconds
};

var response = try client.getWithOptions(url, headers, options);
defer response.deinit();
```

## Advanced Optional Modules

### Retry Engine

The retry module provides enterprise resilience patterns extracted from production HFT systems:

```zig
const RetryEngine = @import("http-sentinel/retry");

// Configure retry strategy
const config = RetryEngine.RetryConfig{
    .max_attempts = 5,
    .initial_delay_ms = 100,
    .max_delay_ms = 10000,
    .backoff_multiplier = 2.0,
    .jitter_factor = 0.1,
};

var engine = RetryEngine.init(allocator, config);
defer engine.deinit();

// Use with HTTP requests
var attempt: u32 = 0;
while (attempt < config.max_attempts) : (attempt += 1) {
    var response = client.get(url, headers) catch |err| {
        const delay = engine.calculateDelay(attempt);
        std.time.sleep(delay * std.time.ns_per_ms);
        continue;
    };
    defer response.deinit();
    break; // Success
}
```

**Patterns Included:**
- Exponential backoff with jitter
- Circuit breaker pattern
- Adaptive retry based on health scores
- Configurable retry policies

### Connection Pool

Enterprise-grade connection pooling for high-throughput scenarios:

```zig
const ConnectionPool = @import("http-sentinel/pool");

// Configure pool
const config = ConnectionPool.PoolConfig{
    .max_connections = 20,
    .max_idle_connections = 10,
    .connection_timeout_ms = 5000,
    .idle_timeout_ms = 30000,
    .max_connection_lifetime_ms = 300000,
};

var pool = try ConnectionPool.init(allocator, config);
defer pool.deinit();

// Acquire and use connections
const conn = try pool.acquire("api.example.com", 443);
defer pool.release(conn);

// Use connection for HTTP operations
var response = try conn.request(.GET, "/data", headers);
defer response.deinit();
```

**Features:**
- Multi-host connection management
- Connection health monitoring
- Load balancing across backends
- Automatic connection lifecycle management
- Per-host statistics and metrics

Run the examples to see these patterns in action:
```bash
zig build retry-demo     # Demonstrates retry patterns
zig build pool-demo      # Shows connection pooling
```

## Thread Safety & Concurrency

**CRITICAL**: HTTP Sentinel uses the **client-per-worker pattern** for concurrent operations. This is the only reliable way to do concurrent HTTP requests in Zig 0.16.0.

### ✅ Correct Pattern (Client-Per-Worker)
```zig
fn workerThread(allocator: std.mem.Allocator) void {
    // Each thread creates its own client
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    // Use the client safely for this worker's requests
}
```

### ❌ Wrong Pattern (Will Segfault)
```zig
// DON'T DO THIS - Shared client will segfault under load
var shared_client = HttpClient.init(allocator);
var mutex = std.Thread.Mutex{};

fn workerThread(client: *HttpClient, mutex: *std.Thread.Mutex) void {
    mutex.lock();
    defer mutex.unlock();
    // This WILL segfault even with mutex protection!
    const response = client.get(...);
}
```

**Why**: Zig 0.16.0's `http.Client` has internal state that is not thread-safe. The client-per-worker pattern avoids all concurrency issues.

See [CONCURRENCY_PATTERN.md](CONCURRENCY_PATTERN.md) for detailed explanation and benchmarks.

## Examples

See the `examples/` directory for complete working examples including:
- Basic GET/POST requests
- JSON API interactions
- Concurrent request handling
- Error handling patterns

Run examples:
```bash
zig build examples
```

## Example: High-Performance AI Client

Demonstrating zig-http-sentinel's enterprise capabilities with Anthropic's Claude API - proving universal applicability beyond financial systems.

### Setup

1. Get your Anthropic API key from [https://console.anthropic.com/](https://console.anthropic.com/)
2. Set your environment variable:
   ```bash
   export ANTHROPIC_API_KEY=your_api_key_here
   ```

### Run the AI Client Demo

```bash
cd examples
zig run anthropic_client.zig --deps http-sentinel
```

### Features Demonstrated

- **Production JSON Construction**: Enterprise-grade payload building with proper escaping
- **Professional Header Management**: Complete API authentication and versioning
- **Multi-Turn Conversations**: Stateful conversation handling
- **Robust Error Handling**: Comprehensive API error processing
- **Memory Safety**: Proper allocation and cleanup patterns
- **Performance Metrics**: Token usage tracking and optimization

### Sample Output

```
=== Zig HTTP Sentinel: High-Performance AI Client ===

🚀 Initializing high-performance AI client...
📡 Using zig-http-sentinel for enterprise-grade HTTP operations

📝 Demo 1: Production Message Processing
🤖 Claude (claude-3-haiku-20240307):
Zig excels for HTTP clients through zero-cost abstractions, compile-time safety, 
manual memory management, and cross-platform compatibility. Its performance matches 
C while preventing common networking bugs through strong typing.
📊 Tokens: 23 in, 50 out

💬 Demo 2: Multi-Turn Conversation
🤖 Claude (claude-3-haiku-20240307):
zig-http-sentinel achieves these through Zig's allocator patterns for memory efficiency,
built-in thread safety, comprehensive error types, connection pooling architecture,
and clean generic interfaces that maintain zero-cost abstractions.
📊 Tokens: 67 in, 89 out

⚡ Demo 3: Technical Analysis
🤖 Claude (claude-3-haiku-20240307):
This pattern ensures deterministic cleanup, prevents memory leaks through RAII-style
resource management, enables zero-copy optimizations, and maintains explicit control
over allocation strategies—critical for high-frequency, low-latency systems.
📊 Tokens: 124 in, 156 out

✅ All demonstrations completed successfully!
💎 zig-http-sentinel: Enterprise-grade HTTP client for production AI systems
```

### Integration in Your Projects

```zig
const AnthropicClient = @import("your_ai_module.zig").AnthropicClient;

var ai_client = AnthropicClient.init(allocator, api_key);
defer ai_client.deinit();

var response = try ai_client.sendMessage(
    "claude-3-sonnet-20240229",
    "Analyze this trading algorithm...",
    1000,
);
defer response.deinit();

// Use response.content for your application logic
```

This example proves zig-http-sentinel's versatility across industries—from algorithmic trading to AI applications, delivering consistent enterprise-grade performance.

## Example: Enterprise NATS JetStream Bridge

Demonstrating production messaging infrastructure integration with NATS JetStream via HTTP gateway - proving enterprise messaging capabilities.

### Features

- **V-Omega Protocol Compliance**: Full integration with canonical V-Omega message patterns
- **JetStream Management**: Stream and consumer lifecycle operations
- **High-Performance Publishing**: Enterprise-grade message publishing with acknowledgments
- **Telemetry Integration**: Compatible with existing NATS infrastructure (172.191.60.219:4222)
- **Multi-Domain Support**: AI, HPC, and Quantum domain message routing

### Run the NATS Demo

```bash
zig build nats-demo
```

### V-Omega Message Pattern

```zig
// Canonical V-Omega message structure
vomega.{theater}.{domain}.{application}.{action}

// Examples:
vomega.azure.ai.hydra-chimera.telemetry.batch_complete
vomega.gcp.hpc.nuclear-fire-hose.telemetry.pps_report
vomega.aws.quantum.jetstream.telemetry.throughput
```

### Integration Examples

```zig
const NatsJetStreamClient = @import("nats_bridge.zig").NatsJetStreamClient;

var client = NatsJetStreamClient.init(allocator, "172.191.60.219", 4222, "azure");
defer client.deinit();

// Publish AI telemetry
const ai_payload = std.json.Value{ .object = payload_map };
var response = try client.publishVOmegaMessage(
    "ai", "hydra-chimera", "telemetry.batch_complete", ai_payload
);
defer response.deinit();

// Create enterprise stream
const config = StreamConfig{ .max_msgs = 1000000, .storage = "file" };
var stream = try client.createVOmegaStream("quantum", "jetstream", config);
defer stream.deinit();

// Pull message batches
var batch = try client.pullMessages("VOMEGA_AZURE_AI", "processor", 100, 5000);
defer batch.deinit();
```

### Supported Operations

- **Stream Management**: Create, configure, and monitor JetStream streams
- **Consumer Operations**: Durable consumers with acknowledgment policies  
- **Message Publishing**: V-Omega compliant message publishing with sequence tracking
- **Batch Processing**: High-throughput message pulling and processing
- **Monitoring**: Stream statistics and consumer health metrics

This integration demonstrates zig-http-sentinel's capability to bridge HTTP and enterprise messaging systems, enabling hybrid architectures with consistent performance patterns.

## Testing

Run the test suite:
```bash
zig build test
```

## Requirements

- Zig 0.16.0 or later
- No external dependencies

## Performance

This library has been optimized for high-throughput scenarios and has been tested under production loads handling thousands of requests per second.

## Contributing

Contributions are welcome! Please ensure:
1. All tests pass
2. Code follows Zig style conventions
3. New features include tests
4. Documentation is updated

## License

MIT License - See LICENSE file for details

Copyright © 2025 QUANTUM ENCODING LTD  
Website: [https://quantumencoding.io](https://quantumencoding.io)  
Contact: [rich@quantumencoding.io](mailto:rich@quantumencoding.io)

## Acknowledgments

This library emerged from real-world production needs and represents lessons learned from building high-performance trading systems at QUANTUM ENCODING LTD.