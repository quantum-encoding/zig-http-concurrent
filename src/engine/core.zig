// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Universal HTTP Engine Core
//! Processes HTTP request manifests with full concurrency, retry, and circuit breaking

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const RetryEngine = @import("../retry/retry.zig").RetryEngine;
const manifest = @import("manifest.zig");

pub const EngineConfig = struct {
    /// Maximum concurrent requests
    max_concurrency: u32 = 50,

    /// Default timeout for requests (can be overridden per-request)
    default_timeout_ms: u64 = 30_000,

    /// Default retry attempts (can be overridden per-request)
    default_max_retries: u32 = 3,
};

pub fn Engine(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: EngineConfig,
        http_client: HttpClient,
        retry_engine: RetryEngine,

        /// Thread pool for concurrent execution
        thread_pool: std.Thread.Pool,

        /// Output writer for streaming results
        output_writer: WriterType,

        /// Mutex for synchronized output
        output_mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator, config: EngineConfig, output_writer: WriterType) !Self {
            var thread_pool: std.Thread.Pool = undefined;
            try thread_pool.init(.{
                .allocator = allocator,
                .n_jobs = config.max_concurrency,
            });

            return Self{
                .allocator = allocator,
                .config = config,
                .http_client = HttpClient.init(allocator),
                .retry_engine = RetryEngine.init(allocator, .{}),
                .thread_pool = thread_pool,
                .output_writer = output_writer,
                .output_mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.thread_pool.deinit();
            self.http_client.deinit();
        }

        /// Process a batch of request manifests
        pub fn processBatch(self: *Self, requests: []manifest.RequestManifest) !void {
            var wg = std.Thread.WaitGroup{};

            for (requests) |*request| {
                self.thread_pool.spawnWg(&wg, processRequest, .{ self, request });
            }

            wg.wait();
        }

        /// Process a single request (called by thread pool)
        fn processRequest(self: *Self, request: *manifest.RequestManifest) void {
        const start_time = std.time.milliTimestamp();

        var response = manifest.ResponseManifest{
            .id = undefined,
            .status = 0,
            .latency_ms = 0,
            .allocator = self.allocator,
        };

        // Duplicate ID for response
        response.id = self.allocator.dupe(u8, request.id) catch {
            self.writeError(request.id, "Memory allocation failed");
            return;
        };

        // Execute request with retry
        const max_retries = request.max_retries orelse self.config.default_max_retries;
        var retry_count: u32 = 0;

        while (retry_count <= max_retries) : (retry_count += 1) {
            var result = self.executeHttpRequest(request);

            if (result) |*http_response| {
                defer http_response.deinit();

                response.status = @intFromEnum(http_response.status);
                response.body = self.allocator.dupe(u8, http_response.body) catch null;
                response.retry_count = retry_count;
                break;
            } else |err| {
                if (retry_count < max_retries) {
                    // Calculate exponential backoff
                    const backoff_ms = @as(u64, 100) * (@as(u64, 1) << @intCast(retry_count));
                    std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                    continue;
                } else {
                    // Final failure
                    response.error_message = std.fmt.allocPrint(
                        self.allocator,
                        "{}",
                        .{err},
                    ) catch null;
                    response.retry_count = retry_count;
                    break;
                }
            }
        }

        const end_time = std.time.milliTimestamp();
        response.latency_ms = @intCast(end_time - start_time);

        self.writeResponse(&response);
        response.deinit();
    }

    /// Execute HTTP request
    fn executeHttpRequest(self: *Engine, request: *manifest.RequestManifest) !HttpClient.Response {
        // Build headers
        var headers = std.ArrayList(std.http.Header){};
        defer headers.deinit(self.allocator);

        if (request.headers) |*req_headers| {
            var it = req_headers.map.iterator();
            while (it.next()) |entry| {
                try headers.append(self.allocator, .{
                    .name = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                });
            }
        }

        // Execute based on method
        return switch (request.method) {
            .GET => try self.http_client.get(request.url, headers.items),
            .POST, .PUT, .PATCH => blk: {
                const body = request.body orelse "";
                if (request.method == .POST) {
                    break :blk try self.http_client.post(request.url, headers.items, body);
                } else if (request.method == .PUT) {
                    break :blk try self.http_client.put(request.url, headers.items, body);
                } else {
                    break :blk try self.http_client.patch(request.url, headers.items, body);
                }
            },
            .DELETE => try self.http_client.delete(request.url, headers.items),
            .HEAD, .OPTIONS => error.MethodNotSupported,
        };
    }

    /// Write response to output (thread-safe)
    fn writeResponse(self: *Engine, response: *manifest.ResponseManifest) void {
        self.output_mutex.lock();
        defer self.output_mutex.unlock();

        response.toJson(self.output_writer) catch |err| {
            std.debug.print("Error writing response: {}\n", .{err});
        };
    }

    /// Write error to output (thread-safe)
    fn writeError(self: *Engine, id: []const u8, error_message: []const u8) void {
        self.output_mutex.lock();
        defer self.output_mutex.unlock();

        self.output_writer.print(
            "{{\"id\":\"{s}\",\"status\":0,\"error\":\"{s}\"}}\n",
            .{ id, error_message },
        ) catch {};
    }
};
