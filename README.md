# Zig HTTP Sentinel

A production-grade, **pure Zig** HTTP client library for Zig **0.16.0** — zero libc, zero `extern "c"`, zero `@cImport`. Extracted from high-frequency trading systems. Actively maintained and updated with each new Zig release.

> **Pure Zig**: Uses `std.Io.Threaded` architecture throughout. No C dependencies. Runs on any Zig target including freestanding OS kernels.

**Developed by [QUANTUM ENCODING LTD](https://quantumencoding.io)**
Contact: [info@quantumencoding.io](mailto:info@quantumencoding.io)

> Currently tested against Zig `0.16.0-dev.3091+`
>
> Part of [quantum-zig-forge](https://github.com/quantum-encoding/quantum-zig-forge) — our main development monorepo for all Zig programs and libraries.

---

## Features

- **Pure Zig**: Zero `extern "c"`, zero `std.c.*`, zero `@cImport` — `link_libc = false`
- **Modern Zig Architecture**: Built on `std.Io.Threaded` for reliable concurrent operations
- **Client-Per-Worker Pattern**: Each thread owns its HTTP client — zero contention, true parallelism
- **Memory-Safe**: RAII-style cleanup with explicit ownership
- **Full HTTP Support**: GET, POST, PUT, PATCH, DELETE, HEAD methods
- **Automatic GZIP Decompression**: Transparent handling of compressed responses
- **Configurable**: Request options for timeouts and body size limits
- **Production-Tested**: Running in live trading systems handling thousands of requests/second
- **Multi-Provider AI Clients**: Anthropic Claude, OpenAI, DeepSeek, Google Gemini, Grok, Vertex AI
- **Media Generation**: ElevenLabs, HeyGen, Meshy integration
- **Audio Support**: Text-to-Speech and Speech-to-Text via OpenAI and Google
- **Batch Processing**: CSV-based concurrent request execution (up to 200 parallel)
- **Resilience Engine**: Exponential backoff, circuit breaker, rate limiting

### Pure Zig — What Replaced What

| Was (C/libc) | Now (pure Zig) |
|---|---|
| `std.c.pthread_mutex_*` | Atomic spinlock (`std.atomic.Value`) |
| `std.c.clock_gettime` / `timespec` | `std.Io.Timestamp.now(io, .awake)` |
| `std.c.nanosleep` / `usleep` | `io.sleep(Duration, .awake)` |
| `std.c.arc4random_buf` | `std.Random.DefaultCsprng` |
| C `fopen`/`fread`/`fseek` | `std.Io.Dir.readFileAlloc` |
| `popen`/`pclose` | `std.process.run(allocator, io, ...)` |
| `std.c.getenv` | `std.process.Environ.Map.get()` |
| `std.c.environ` | `std.Io.Threaded.init(allocator, .{})` |
| `std.heap.c_allocator` | `std.heap.smp_allocator` |

---

## Quick Start

### Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .http_sentinel = .{
        .url = "https://github.com/quantum-encoding/zig-http-concurrent/archive/refs/heads/main.tar.gz",
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

### Basic Usage

```zig
const std = @import("std");
const HttpClient = @import("http-sentinel").HttpClient;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // Create client — pure Zig, no libc
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    // Make request
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
    };

    var response = try client.get("https://api.example.com/data", &headers);
    defer response.deinit();

    std.debug.print("Status: {}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
}
```

---

## Core Architecture

### The std.Io.Threaded Foundation

HTTP Sentinel is built entirely on Zig's `std.Io.Threaded` architecture — no C library calls:

```zig
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    io_threaded: *std.Io.Threaded,
    client: http.Client,

    pub fn init(allocator: std.mem.Allocator) !HttpClient {
        const io_threaded = try allocator.create(std.Io.Threaded);
        io_threaded.* = std.Io.Threaded.init(allocator, .{});
        const io_handle = io_threaded.io();

        return .{
            .allocator = allocator,
            .io_threaded = io_threaded,
            .client = http.Client{
                .allocator = allocator,
                .io = io_handle,
            },
        };
    }

    /// Get the Io handle for timing, sleep, random, etc.
    pub fn io(self: *HttpClient) std.Io {
        return self.io_threaded.io();
    }
};
```

**Why This Matters**:
- Each `HttpClient` owns its I/O subsystem
- Enables true thread-safe operation
- No hidden shared state
- Foundation of the client-per-worker pattern
- Runs on any target — including custom Zig OSes

---

## The Client-Per-Worker Pattern

### Each Thread Owns Its Client

```zig
const Worker = struct {
    allocator: std.mem.Allocator,

    fn run(self: @This()) void {
        // Each worker creates its own client
        var client = HttpClient.init(self.allocator) catch unreachable;
        defer client.deinit();

        // Make requests — no contention!
        var response = client.get(url, &.{}) catch return;
        defer response.deinit();

        // Process response...
    }
};

// Launch workers
for (&threads) |*thread| {
    thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
}
```

---

## API Reference

### HTTP Methods

```zig
// GET
var response = try client.get(url, headers);
defer response.deinit();

// POST
var response = try client.post(url, headers, body);
defer response.deinit();

// PUT / PATCH / DELETE / HEAD — same pattern
```

### Request Options

```zig
const options = HttpClient.RequestOptions{
    .max_body_size = 50 * 1024 * 1024,  // 50MB
    .timeout_ns = 30 * std.time.ns_per_s,  // 30 seconds
};

var response = try client.getWithOptions(url, headers, options);
defer response.deinit();
```

### AI Providers

Built-in clients for all major AI providers:

```zig
const ai = @import("http-sentinel").ai;

// Anthropic Claude
var claude = try ai.ClaudeClient.init(allocator, .{ .api_key = key });
defer claude.deinit();
var resp = try claude.sendMessage("Hello", .{ .model = "claude-sonnet-4-20250514" });

// Also: OpenAI, DeepSeek, Gemini, Grok, Vertex AI
```

### Batch Processing

```bash
# CSV input, concurrent execution across providers
zig-ai --batch requests.csv --concurrency 50 --output results.csv
```

---

## Testing

```bash
zig build test        # Run library tests
zig build cli         # Build AI CLI tool
zig build quantum     # Build Quantum Curl HTTP engine
```

---

## Production Deployment

### Requirements

- **Zig Version**: 0.16.0-dev.3091+ (run `zig version` to check)
- **OS**: Linux, macOS, Windows, or any Zig-supported target (no libc required)
- **Memory**: ~2-4MB per concurrent worker thread

### Production Checklist

- [ ] Use `std.heap.smp_allocator` for production (pure Zig, no libc)
- [ ] Configure `RequestOptions.max_body_size` based on your APIs
- [ ] Set `RequestOptions.timeout_ns` for all requests
- [ ] Always check `response.status` before parsing body
- [ ] Use `defer response.deinit()` immediately after request
- [ ] One `HttpClient` per worker thread (never share!)

---

## Documentation

- **[MODERN_ZIG_PATTERNS.md](MODERN_ZIG_PATTERNS.md)** - Implementation patterns for Zig 0.16
- **[examples/](examples/)** - Working code examples
- **[src/http_client.zig](src/http_client.zig)** - Core HTTP client implementation
- **[src/ai/](src/ai/)** - AI provider clients (Claude, OpenAI, DeepSeek, Gemini, Grok, Vertex, ElevenLabs, HeyGen, Meshy)
- **[src/audio/](src/audio/)** - Audio TTS/STT support
- **[src/batch/](src/batch/)** - Batch processing engine
- **[src/retry/](src/retry/)** - Resilience engine (backoff, circuit breaker, rate limiting)

---

## License

MIT License - See LICENSE file for details

```
Copyright (c) 2025-2026 QUANTUM ENCODING LTD
Website: https://quantumencoding.io
Contact: info@quantumencoding.io
```

---

## Support

- **Issues**: [GitHub Issues](https://github.com/quantum-encoding/zig-http-concurrent/issues)
- **Email**: [info@quantumencoding.io](mailto:info@quantumencoding.io)
- **Monorepo**: [quantum-zig-forge](https://github.com/quantum-encoding/quantum-zig-forge)
