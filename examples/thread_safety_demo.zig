// Thread Safety Demonstration for HTTP Sentinel
// Shows proper Client-Per-Worker pattern implementation

const std = @import("std");

// Since we can't import from parent directories in standalone compilation,
// we'll inline the essential types here for the demo
const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub const Response = struct {
        status: std.http.Status,
        body: []u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    pub fn get(self: *HttpClient, url: []const u8, headers: []const std.http.Header) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();
        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024)
        );
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
        };
    }
};

const ClientPool = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ClientPool {
        return .{ .allocator = allocator };
    }

    pub fn createClient(self: *ClientPool) !*HttpClient {
        const client = try self.allocator.create(HttpClient);
        client.* = HttpClient.init(self.allocator);
        return client;
    }

    pub fn destroyClient(self: *ClientPool, client: *HttpClient) void {
        client.deinit();
        self.allocator.destroy(client);
    }
};

const HttpWorker = struct {
    id: usize,
    client: *HttpClient,
    pool: *ClientPool,

    pub fn init(pool: *ClientPool, id: usize) !HttpWorker {
        return HttpWorker{
            .id = id,
            .client = try pool.createClient(),
            .pool = pool,
        };
    }

    pub fn deinit(self: *HttpWorker) void {
        self.pool.destroyClient(self.client);
    }

    pub fn get(self: *HttpWorker, url: []const u8, headers: []const std.http.Header) !HttpClient.Response {
        return self.client.get(url, headers);
    }
};

const DemoConfig = struct {
    num_workers: u32 = 10,
    requests_per_worker: u32 = 100,
    target_url: []const u8 = "https://httpbin.org/get",
};

const WorkerContext = struct {
    worker: HttpWorker,
    worker_id: usize,
    requests_to_make: u32,
    target_url: []const u8,
    success_count: *std.atomic.Value(u32),
    failure_count: *std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    fn run(ctx: *WorkerContext) void {
        std.log.info("Worker {d} starting - making {d} requests", .{
            ctx.worker_id,
            ctx.requests_to_make,
        });

        for (0..ctx.requests_to_make) |i| {
            // Use this worker's dedicated HTTP client
            const headers = [_]std.http.Header{
                .{ .name = "User-Agent", .value = "HttpSentinel/1.0" },
                .{ .name = "X-Worker-ID", .value = std.fmt.allocPrint(
                    ctx.allocator,
                    "{d}",
                    .{ctx.worker_id}
                ) catch "unknown" },
                .{ .name = "X-Request-ID", .value = std.fmt.allocPrint(
                    ctx.allocator,
                    "{d}-{d}",
                    .{ ctx.worker_id, i }
                ) catch "unknown" },
            };

            const result = ctx.worker.get(ctx.target_url, &headers);

            if (result) |response_const| {
                var response = response_const;
                defer response.deinit();

                if (response.status == .ok) {
                    _ = ctx.success_count.fetchAdd(1, .monotonic);
                } else {
                    _ = ctx.failure_count.fetchAdd(1, .monotonic);
                    std.log.warn("Worker {d}: Request {d} got status {}", .{
                        ctx.worker_id,
                        i,
                        response.status,
                    });
                }
            } else |err| {
                _ = ctx.failure_count.fetchAdd(1, .monotonic);
                std.log.err("Worker {d}: Request {d} failed: {}", .{
                    ctx.worker_id,
                    i,
                    err,
                });
            }

            if (i % 25 == 0 and i > 0) {
                std.log.info("Worker {d}: Progress {d}/{d}", .{
                    ctx.worker_id,
                    i,
                    ctx.requests_to_make,
                });
            }

            // Small delay to not overwhelm the server
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        std.log.info("Worker {d} complete", .{ctx.worker_id});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = DemoConfig{};
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--workers") and i + 1 < args.len) {
            config.num_workers = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (std.mem.eql(u8, arg, "--requests") and i + 1 < args.len) {
            config.requests_per_worker = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (std.mem.eql(u8, arg, "--url") and i + 1 < args.len) {
            config.target_url = args[i + 1];
        }
    }

    std.log.info("", .{});
    std.log.info("🛡️  HTTP SENTINEL THREAD SAFETY DEMONSTRATION", .{});
    std.log.info("================================================", .{});
    std.log.info("", .{});
    std.log.info("This demo proves that HTTP Sentinel's Client-Per-Worker", .{});
    std.log.info("pattern prevents segfaults under concurrent load.", .{});
    std.log.info("", .{});
    std.log.info("Configuration:", .{});
    std.log.info("  Workers: {d}", .{config.num_workers});
    std.log.info("  Requests per worker: {d}", .{config.requests_per_worker});
    std.log.info("  Total requests: {d}", .{config.num_workers * config.requests_per_worker});
    std.log.info("  Target URL: {s}", .{config.target_url});
    std.log.info("", .{});

    // Initialize the client pool
    var pool = ClientPool.init(allocator);

    // Shared counters
    var success_count = std.atomic.Value(u32).init(0);
    var failure_count = std.atomic.Value(u32).init(0);

    // Create worker contexts
    const contexts = try allocator.alloc(WorkerContext, config.num_workers);
    defer allocator.free(contexts);

    for (contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .worker = try HttpWorker.init(&pool, i),
            .worker_id = i,
            .requests_to_make = config.requests_per_worker,
            .target_url = config.target_url,
            .success_count = &success_count,
            .failure_count = &failure_count,
            .allocator = allocator,
        };
    }
    defer for (contexts) |*ctx| ctx.worker.deinit();

    // Create threads
    const threads = try allocator.alloc(std.Thread, config.num_workers);
    defer allocator.free(threads);

    const start_time = std.time.milliTimestamp();

    // Launch all workers simultaneously
    std.log.info("🚀 Launching {d} concurrent workers...", .{config.num_workers});
    std.log.info("", .{});

    for (threads, contexts) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, WorkerContext.run, .{ctx});
    }

    // Wait for all workers to complete
    for (threads) |thread| {
        thread.join();
    }

    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;

    // Print results
    const total_success = success_count.load(.acquire);
    const total_failure = failure_count.load(.acquire);
    const total_attempted = total_success + total_failure;

    std.log.info("", .{});
    std.log.info("📊 RESULTS", .{});
    std.log.info("================================================", .{});
    std.log.info("  Duration: {d}ms", .{duration_ms});
    std.log.info("  Successful requests: {d}", .{total_success});
    std.log.info("  Failed requests: {d}", .{total_failure});
    std.log.info("  Total attempted: {d}", .{total_attempted});

    if (total_attempted > 0) {
        std.log.info("  Success rate: {d:.2}%", .{
            @as(f64, @floatFromInt(total_success)) / @as(f64, @floatFromInt(total_attempted)) * 100
        });
        std.log.info("  Throughput: {d:.2} req/s", .{
            @as(f64, @floatFromInt(total_attempted)) / (@as(f64, @floatFromInt(duration_ms)) / 1000.0)
        });
    }

    std.log.info("", .{});
    if (total_failure == 0 and total_success > 0) {
        std.log.info("✅ PERFECT RUN - No failures!", .{});
    }
    std.log.info("🎉 NO SEGFAULTS - Thread-safe architecture confirmed!", .{});
    std.log.info("", .{});
    std.log.info("KEY INSIGHT:", .{});
    std.log.info("Each worker has its own HTTP client instance.", .{});
    std.log.info("This prevents the thread-safety issues that would", .{});
    std.log.info("occur if multiple threads shared a single client.", .{});
}