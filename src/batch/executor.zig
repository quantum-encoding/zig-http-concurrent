// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Batch executor - Concurrent request processing with thread pool

const std = @import("std");
const types = @import("types.zig");
const cli = @import("../cli.zig");
const ai_common = @import("../ai/common.zig");
const anthropic = @import("../ai/anthropic.zig");
const deepseek = @import("../ai/deepseek.zig");
const gemini = @import("../ai/gemini.zig");
const grok = @import("../ai/grok.zig");
const vertex = @import("../ai/vertex.zig");

/// Thread-safe batch executor using fixed-size thread pool
pub const BatchExecutor = struct {
    allocator: std.mem.Allocator,
    requests: []types.BatchRequest,
    results: std.ArrayList(types.BatchResult),
    results_mutex: std.Thread.Mutex,
    completed: std.atomic.Value(u32),
    failed: std.atomic.Value(u32),
    config: types.BatchConfig,

    pub fn init(
        allocator: std.mem.Allocator,
        requests: []types.BatchRequest,
        config: types.BatchConfig,
    ) !BatchExecutor {
        return .{
            .allocator = allocator,
            .requests = requests,
            .results = std.ArrayList(types.BatchResult){},
            .results_mutex = .{},
            .completed = std.atomic.Value(u32).init(0),
            .failed = std.atomic.Value(u32).init(0),
            .config = config,
        };
    }

    pub fn deinit(self: *BatchExecutor) void {
        for (self.results.items) |*result| {
            result.deinit();
        }
        self.results.deinit(self.allocator);
    }

    /// Execute all requests using thread pool
    pub fn execute(self: *BatchExecutor) !void {
        var timer = try std.time.Timer.start();

        // Determine thread count (cap at request count and concurrency limit)
        const thread_count = @min(self.requests.len, self.config.concurrency);

        if (self.config.show_progress) {
            std.debug.print("\n🔄 Starting batch processing...\n", .{});
            std.debug.print("   Requests: {}\n", .{self.requests.len});
            std.debug.print("   Concurrency: {}\n", .{thread_count});
            std.debug.print("   Retry count: {}\n\n", .{self.config.retry_count});
        }

        // Initialize thread pool
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = self.allocator,
            .n_jobs = thread_count,
        });
        defer pool.deinit();

        // Spawn work for each request
        for (self.requests) |*request| {
            try pool.spawn(executeRequest, .{ self, request });
        }

        // Progress reporting loop
        if (self.config.show_progress) {
            while (self.completed.load(.acquire) + self.failed.load(.acquire) < self.requests.len) {
                const completed = self.completed.load(.acquire);
                const failed = self.failed.load(.acquire);
                const total = completed + failed;

                std.debug.print("\r[INFO] Processed {}/{} requests (success: {} failed: {})...", .{
                    total,
                    self.requests.len,
                    completed,
                    failed,
                });

                std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
            }
            std.debug.print("\r[INFO] Processed {}/{} requests (success: {} failed: {})...Done!\n\n", .{
                self.requests.len,
                self.requests.len,
                self.completed.load(.acquire),
                self.failed.load(.acquire),
            });
        }

        const elapsed_ns = timer.read();
        const duration_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);

        if (self.config.show_progress) {
            std.debug.print("Batch complete!\n", .{});
            std.debug.print("   Total time: {d:.2}s\n", .{duration_s});
            std.debug.print("   Success: {}\n", .{self.completed.load(.acquire)});
            std.debug.print("   Failed: {}\n\n", .{self.failed.load(.acquire)});
        }
    }

    /// Execute a single request (called by worker thread)
    fn executeRequest(self: *BatchExecutor, request: *const types.BatchRequest) void {
        var timer = std.time.Timer.start() catch unreachable;

        var result = types.BatchResult{
            .id = request.id,
            .provider = request.provider,
            .prompt = undefined,
            .response = null,
            .input_tokens = 0,
            .output_tokens = 0,
            .cost = 0.0,
            .execution_time_ms = 0,
            .error_message = null,
            .allocator = self.allocator,
        };

        // Duplicate prompt for result
        result.prompt = self.allocator.dupe(u8, request.prompt) catch |err| {
            result.prompt = self.allocator.dupe(u8, "[error copying prompt]") catch unreachable;
            result.error_message = std.fmt.allocPrint(
                self.allocator,
                "Failed to allocate prompt: {any}",
                .{err},
            ) catch null;
            self.storeResult(result);
            _ = self.failed.fetchAdd(1, .release);
            return;
        };

        // Execute with retries
        var attempts: u32 = 0;
        const max_attempts = self.config.retry_count + 1;

        while (attempts < max_attempts) : (attempts += 1) {
            if (attempts > 0) {
                // Exponential backoff
                const delay_ms = @as(u64, 1000) * (@as(u64, 1) << @intCast(attempts - 1));
                const delay_ns = delay_ms * std.time.ns_per_ms;
                std.posix.nanosleep(0, delay_ns);
            }

            // Execute the request
            var execute_result = self.executeWithProvider(request);

            if (execute_result) |*ai_response| {
                defer ai_response.deinit();

                // Success - populate result
                result.response = self.allocator.dupe(u8, ai_response.message.content) catch |err| {
                    result.error_message = std.fmt.allocPrint(
                        self.allocator,
                        "Failed to copy response: {any}",
                        .{err},
                    ) catch null;
                    break;
                };
                result.input_tokens = ai_response.usage.input_tokens;
                result.output_tokens = ai_response.usage.output_tokens;
                result.cost = request.provider.calculateCost(
                    ai_response.metadata.model,
                    ai_response.usage.input_tokens,
                    ai_response.usage.output_tokens,
                );

                const elapsed_ns = timer.read();
                result.execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms);

                self.storeResult(result);
                _ = self.completed.fetchAdd(1, .release);
                return;
            } else |err| {
                // Determine if we should retry
                const should_retry = switch (err) {
                    ai_common.AIError.RateLimitExceeded,
                    ai_common.AIError.ApiRequestFailed,
                    => true,
                    else => false,
                };

                if (!should_retry or attempts == max_attempts - 1) {
                    // Final failure - store error
                    result.error_message = std.fmt.allocPrint(
                        self.allocator,
                        "{any}",
                        .{err},
                    ) catch null;

                    const elapsed_ns = timer.read();
                    result.execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms);

                    self.storeResult(result);
                    _ = self.failed.fetchAdd(1, .release);
                    return;
                }

                // Continue to retry
            }
        }
    }

    /// Execute request with appropriate provider
    fn executeWithProvider(
        self: *BatchExecutor,
        request: *const types.BatchRequest,
    ) !ai_common.AIResponse {

        // Build request config
        const req_config = ai_common.RequestConfig{
            .model = request.provider.getDefaultModel(),
            .temperature = request.temperature,
            .max_tokens = request.max_tokens,
            .system_prompt = request.system_prompt,
            .max_turns = 1, // Single turn for batch processing
        };

        // Execute based on provider
        return switch (request.provider) {
            .claude => blk: {
                const api_key = std.process.getEnvVarOwned(
                    self.allocator,
                    "ANTHROPIC_API_KEY",
                ) catch return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(api_key);

                var client = try anthropic.AnthropicClient.init(
                    self.allocator,
                    .{ .api_key = api_key },
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
            .deepseek => blk: {
                const api_key = std.process.getEnvVarOwned(
                    self.allocator,
                    "DEEPSEEK_API_KEY",
                ) catch return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(api_key);

                var client = try deepseek.DeepSeekClient.init(
                    self.allocator,
                    api_key,
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
            .gemini => blk: {
                const api_key = std.process.getEnvVarOwned(
                    self.allocator,
                    "GOOGLE_GENAI_API_KEY",
                ) catch return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(api_key);

                var client = try gemini.GeminiClient.init(
                    self.allocator,
                    api_key,
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
            .grok => blk: {
                const api_key = std.process.getEnvVarOwned(
                    self.allocator,
                    "XAI_API_KEY",
                ) catch return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(api_key);

                var client = try grok.GrokClient.init(
                    self.allocator,
                    api_key,
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
            .vertex => blk: {
                const project_id = std.process.getEnvVarOwned(
                    self.allocator,
                    "VERTEX_PROJECT_ID",
                ) catch return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(project_id);

                var client = try vertex.VertexClient.init(
                    self.allocator,
                    .{ .project_id = project_id },
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
        };
    }

    /// Thread-safe result storage
    fn storeResult(self: *BatchExecutor, result: types.BatchResult) void {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();

        self.results.append(self.allocator, result) catch |err| {
            std.debug.print("⚠️  Warning: Failed to store result {}: {}\n", .{ result.id, err });
        };
    }

    /// Get results sorted by ID
    pub fn getResults(self: *BatchExecutor) ![]types.BatchResult {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();

        // Sort by ID using new Zig 0.16.0 API
        std.mem.sort(types.BatchResult, self.results.items, {}, struct {
            pub fn lessThan(_: void, a: types.BatchResult, b: types.BatchResult) bool {
                return a.id < b.id;
            }
        }.lessThan);

        return self.results.items;
    }
};
