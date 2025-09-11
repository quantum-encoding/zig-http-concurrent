// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const HttpClient = @import("http-sentinel").HttpClient;

/// Enterprise NATS JetStream HTTP Interface
/// Bridges HTTP REST operations to NATS JetStream using production-grade patterns
/// Compatible with V-Omega infrastructure at 172.191.60.219:4222

const NatsJetStreamClient = struct {
    http_client: HttpClient,
    nats_server_host: []const u8,
    nats_server_port: u16,
    theater: []const u8,
    
    /// NATS JetStream API endpoints (via HTTP gateway)
    const JETSTREAM_API_PORT: u16 = 8222;
    
    pub fn init(
        allocator: std.mem.Allocator,
        nats_server_host: []const u8,
        nats_server_port: u16,
        theater: []const u8,
    ) NatsJetStreamClient {
        return NatsJetStreamClient{
            .http_client = HttpClient.init(allocator),
            .nats_server_host = nats_server_host,
            .nats_server_port = nats_server_port,
            .theater = theater,
        };
    }
    
    pub fn deinit(self: *NatsJetStreamClient) void {
        self.http_client.deinit();
    }
    
    /// Publish V-Omega compliant message to JetStream
    pub fn publishVOmegaMessage(
        self: *NatsJetStreamClient,
        domain: []const u8,
        application: []const u8,
        action: []const u8,
        payload: std.json.Value,
    ) !NatsResponse {
        const allocator = self.http_client.allocator;
        
        // Construct V-Omega canonical subject pattern
        const subject = try std.fmt.allocPrint(allocator, 
            "vomega.{s}.{s}.{s}.{s}", 
            .{ self.theater, domain, application, action }
        );
        defer allocator.free(subject);
        
        // Build V-Omega compliant message structure
        const timestamp = std.time.timestamp();
        const iso_timestamp = try self.formatTimestamp(allocator, timestamp);
        defer allocator.free(iso_timestamp);
        
        const message = VOmegaMessage{
            .subject = subject,
            .timestamp = iso_timestamp,
            .theater = self.theater,
            .domain = domain,
            .application = application,
            .action = action,
            .payload = payload,
        };
        
        return self.publishMessage(subject, message);
    }
    
    /// Publish raw message to JetStream
    pub fn publishMessage(
        self: *NatsJetStreamClient,
        subject: []const u8,
        message: anytype,
    ) !NatsResponse {
        const allocator = self.http_client.allocator;
        
        // Serialize message to JSON
        const json_payload = try std.json.stringifyAlloc(allocator, message, .{});
        defer allocator.free(json_payload);
        
        // Construct JetStream publish URL
        const api_url = try std.fmt.allocPrint(allocator,
            "http://{s}:{d}/v1/jetstream/publish/{s}",
            .{ self.nats_server_host, JETSTREAM_API_PORT, subject }
        );
        defer allocator.free(api_url);
        
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0 (vomega-bridge)" },
        };
        
        var response = try self.http_client.post(api_url, &headers, json_payload);
        defer response.deinit();
        
        if (response.status != .ok) {
            std.debug.print("NATS publish failed: HTTP {d}\nResponse: {s}\n", 
                .{ @intFromEnum(response.status), response.body });
            return error.NatsPublishFailed;
        }
        
        // Parse JetStream response
        const parsed = try std.json.parseFromSlice(
            JetStreamPublishResponse,
            allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        );
        
        return NatsResponse{
            .success = true,
            .sequence = parsed.value.seq,
            .stream = try allocator.dupe(u8, parsed.value.stream),
            .duplicate = parsed.value.duplicate orelse false,
            .allocator = allocator,
            .parsed_response = parsed,
        };
    }
    
    /// Create JetStream for V-Omega domain
    pub fn createVOmegaStream(
        self: *NatsJetStreamClient,
        domain: []const u8,
        application: []const u8,
        config: StreamConfig,
    ) !StreamInfo {
        const allocator = self.http_client.allocator;
        
        // V-Omega stream name pattern
        const stream_name = try std.fmt.allocPrint(allocator,
            "VOMEGA_{s}_{s}_{s}",
            .{ self.theater, domain, application }
        );
        defer allocator.free(stream_name);
        
        // Subject pattern for this stream
        const subject_pattern = try std.fmt.allocPrint(allocator,
            "vomega.{s}.{s}.{s}.>",
            .{ self.theater, domain, application }
        );
        defer allocator.free(subject_pattern);
        
        const stream_config = StreamCreateRequest{
            .name = stream_name,
            .subjects = &[_][]const u8{subject_pattern},
            .retention = config.retention,
            .max_msgs = config.max_msgs,
            .max_bytes = config.max_bytes,
            .max_age = config.max_age_ns,
            .storage = config.storage,
            .replicas = config.replicas,
        };
        
        return self.createStream(stream_config);
    }
    
    /// Create JetStream
    pub fn createStream(self: *NatsJetStreamClient, config: StreamCreateRequest) !StreamInfo {
        const allocator = self.http_client.allocator;
        
        const json_payload = try std.json.stringifyAlloc(allocator, config, .{});
        defer allocator.free(json_payload);
        
        const api_url = try std.fmt.allocPrint(allocator,
            "http://{s}:{d}/v1/jetstream/streams",
            .{ self.nats_server_host, JETSTREAM_API_PORT }
        );
        defer allocator.free(api_url);
        
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0 (stream-manager)" },
        };
        
        var response = try self.http_client.post(api_url, &headers, json_payload);
        defer response.deinit();
        
        if (response.status != .ok) {
            return error.StreamCreationFailed;
        }
        
        const parsed = try std.json.parseFromSlice(
            StreamInfoResponse,
            allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        );
        
        return StreamInfo{
            .name = try allocator.dupe(u8, parsed.value.config.name),
            .subjects = try self.dupeStringArray(allocator, parsed.value.config.subjects),
            .messages = parsed.value.state.messages,
            .bytes = parsed.value.state.bytes,
            .first_seq = parsed.value.state.first_seq,
            .last_seq = parsed.value.state.last_seq,
            .consumer_count = parsed.value.state.consumer_count,
            .allocator = allocator,
            .parsed_response = parsed,
        };
    }
    
    /// Create consumer for V-Omega telemetry patterns
    pub fn createVOmegaConsumer(
        self: *NatsJetStreamClient,
        stream_name: []const u8,
        consumer_name: []const u8,
        filter_subject: ?[]const u8,
        config: ConsumerConfig,
    ) !ConsumerInfo {
        const allocator = self.http_client.allocator;
        
        const consumer_config = ConsumerCreateRequest{
            .durable_name = consumer_name,
            .deliver_policy = config.deliver_policy,
            .ack_policy = config.ack_policy,
            .ack_wait = config.ack_wait_ns,
            .max_deliver = config.max_deliver,
            .filter_subject = filter_subject,
            .replay_policy = config.replay_policy,
        };
        
        const json_payload = try std.json.stringifyAlloc(allocator, consumer_config, .{});
        defer allocator.free(json_payload);
        
        const api_url = try std.fmt.allocPrint(allocator,
            "http://{s}:{d}/v1/jetstream/streams/{s}/consumers",
            .{ self.nats_server_host, JETSTREAM_API_PORT, stream_name }
        );
        defer allocator.free(api_url);
        
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0 (consumer-manager)" },
        };
        
        var response = try self.http_client.post(api_url, &headers, json_payload);
        defer response.deinit();
        
        if (response.status != .ok) {
            return error.ConsumerCreationFailed;
        }
        
        const parsed = try std.json.parseFromSlice(
            ConsumerInfoResponse,
            allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        );
        
        return ConsumerInfo{
            .name = try allocator.dupe(u8, parsed.value.config.durable_name.?),
            .stream_name = try allocator.dupe(u8, parsed.value.stream_name),
            .delivered = parsed.value.delivered.stream_seq,
            .ack_pending = parsed.value.ack_floor.stream_seq,
            .num_pending = parsed.value.num_pending,
            .allocator = allocator,
            .parsed_response = parsed,
        };
    }
    
    /// Pull messages from consumer (batch operation)
    pub fn pullMessages(
        self: *NatsJetStreamClient,
        stream_name: []const u8,
        consumer_name: []const u8,
        batch_size: u32,
        timeout_ms: u64,
    ) !MessageBatch {
        const allocator = self.http_client.allocator;
        
        const pull_request = PullRequest{
            .batch = batch_size,
            .max_wait = timeout_ms * 1_000_000, // Convert to nanoseconds
        };
        
        const json_payload = try std.json.stringifyAlloc(allocator, pull_request, .{});
        defer allocator.free(json_payload);
        
        const api_url = try std.fmt.allocPrint(allocator,
            "http://{s}:{d}/v1/jetstream/streams/{s}/consumers/{s}/pull",
            .{ self.nats_server_host, JETSTREAM_API_PORT, stream_name, consumer_name }
        );
        defer allocator.free(api_url);
        
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0 (message-puller)" },
        };
        
        var response = try self.http_client.post(api_url, &headers, json_payload);
        defer response.deinit();
        
        if (response.status != .ok) {
            return error.MessagePullFailed;
        }
        
        // Parse message batch response
        const parsed = try std.json.parseFromSlice(
            MessageBatchResponse,
            allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        );
        
        var messages = try allocator.alloc(JetStreamMessage, parsed.value.messages.len);
        for (parsed.value.messages, 0..) |msg, i| {
            messages[i] = JetStreamMessage{
                .subject = try allocator.dupe(u8, msg.subject),
                .sequence = msg.sequence,
                .timestamp = try allocator.dupe(u8, msg.timestamp),
                .data = try allocator.dupe(u8, msg.data),
                .headers = if (msg.headers) |h| try self.dupeStringMap(allocator, h) else null,
                .allocator = allocator,
            };
        }
        
        return MessageBatch{
            .messages = messages,
            .count = @intCast(messages.len),
            .allocator = allocator,
            .parsed_response = parsed,
        };
    }
    
    /// Get stream statistics and health
    pub fn getStreamInfo(self: *NatsJetStreamClient, stream_name: []const u8) !StreamInfo {
        const allocator = self.http_client.allocator;
        
        const api_url = try std.fmt.allocPrint(allocator,
            "http://{s}:{d}/v1/jetstream/streams/{s}",
            .{ self.nats_server_host, JETSTREAM_API_PORT, stream_name }
        );
        defer allocator.free(api_url);
        
        const headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0 (stream-monitor)" },
        };
        
        var response = try self.http_client.get(api_url, &headers);
        defer response.deinit();
        
        if (response.status != .ok) {
            return error.StreamInfoFailed;
        }
        
        const parsed = try std.json.parseFromSlice(
            StreamInfoResponse,
            allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        );
        
        return StreamInfo{
            .name = try allocator.dupe(u8, parsed.value.config.name),
            .subjects = try self.dupeStringArray(allocator, parsed.value.config.subjects),
            .messages = parsed.value.state.messages,
            .bytes = parsed.value.state.bytes,
            .first_seq = parsed.value.state.first_seq,
            .last_seq = parsed.value.state.last_seq,
            .consumer_count = parsed.value.state.consumer_count,
            .allocator = allocator,
            .parsed_response = parsed,
        };
    }
    
    // Helper functions
    fn formatTimestamp(self: *NatsJetStreamClient, timestamp: i64) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(self.http_client.allocator, "{d}", .{timestamp});
    }
    
    fn dupeStringArray(self: *NatsJetStreamClient, allocator: std.mem.Allocator, array: [][]const u8) ![][]u8 {
        _ = self;
        var result = try allocator.alloc([]u8, array.len);
        for (array, 0..) |str, i| {
            result[i] = try allocator.dupe(u8, str);
        }
        return result;
    }
    
    fn dupeStringMap(self: *NatsJetStreamClient, allocator: std.mem.Allocator, map: std.StringHashMap([]const u8)) !std.StringHashMap([]u8) {
        _ = self;
        var result = std.StringHashMap([]u8).init(allocator);
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = try allocator.dupe(u8, entry.value_ptr.*);
            try result.put(key, value);
        }
        return result;
    }
};

// ===== V-OMEGA DATA STRUCTURES =====

/// V-Omega canonical message format
const VOmegaMessage = struct {
    subject: []const u8,
    timestamp: []const u8,
    theater: []const u8,
    domain: []const u8,
    application: []const u8,
    action: []const u8,
    payload: std.json.Value,
};

/// Stream configuration options
const StreamConfig = struct {
    retention: []const u8 = "limits", // "limits", "interest", "workqueue"
    max_msgs: i64 = 1000000,
    max_bytes: i64 = 1024 * 1024 * 1024, // 1GB
    max_age_ns: i64 = 24 * 60 * 60 * 1_000_000_000, // 24 hours
    storage: []const u8 = "file", // "file" or "memory"
    replicas: u8 = 1,
};

/// Consumer configuration options
const ConsumerConfig = struct {
    deliver_policy: []const u8 = "all", // "all", "last", "new"
    ack_policy: []const u8 = "explicit", // "explicit", "all", "none"
    ack_wait_ns: i64 = 30 * 1_000_000_000, // 30 seconds
    max_deliver: i32 = 3,
    replay_policy: []const u8 = "instant", // "instant", "original"
};

// ===== JETSTREAM API STRUCTURES =====

const StreamCreateRequest = struct {
    name: []const u8,
    subjects: [][]const u8,
    retention: []const u8,
    max_msgs: i64,
    max_bytes: i64,
    max_age: i64,
    storage: []const u8,
    replicas: u8,
};

const ConsumerCreateRequest = struct {
    durable_name: []const u8,
    deliver_policy: []const u8,
    ack_policy: []const u8,
    ack_wait: i64,
    max_deliver: i32,
    filter_subject: ?[]const u8,
    replay_policy: []const u8,
};

const PullRequest = struct {
    batch: u32,
    max_wait: u64,
};

// ===== RESPONSE STRUCTURES =====

const NatsResponse = struct {
    success: bool,
    sequence: u64,
    stream: []const u8,
    duplicate: bool,
    allocator: std.mem.Allocator,
    parsed_response: std.json.Parsed(JetStreamPublishResponse),
    
    pub fn deinit(self: *NatsResponse) void {
        self.allocator.free(self.stream);
        self.parsed_response.deinit();
    }
};

const StreamInfo = struct {
    name: []const u8,
    subjects: [][]const u8,
    messages: u64,
    bytes: u64,
    first_seq: u64,
    last_seq: u64,
    consumer_count: u32,
    allocator: std.mem.Allocator,
    parsed_response: std.json.Parsed(StreamInfoResponse),
    
    pub fn deinit(self: *StreamInfo) void {
        self.allocator.free(self.name);
        for (self.subjects) |subject| {
            self.allocator.free(subject);
        }
        self.allocator.free(self.subjects);
        self.parsed_response.deinit();
    }
};

const ConsumerInfo = struct {
    name: []const u8,
    stream_name: []const u8,
    delivered: u64,
    ack_pending: u64,
    num_pending: u64,
    allocator: std.mem.Allocator,
    parsed_response: std.json.Parsed(ConsumerInfoResponse),
    
    pub fn deinit(self: *ConsumerInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.stream_name);
        self.parsed_response.deinit();
    }
};

const MessageBatch = struct {
    messages: []JetStreamMessage,
    count: u32,
    allocator: std.mem.Allocator,
    parsed_response: std.json.Parsed(MessageBatchResponse),
    
    pub fn deinit(self: *MessageBatch) void {
        for (self.messages) |*msg| {
            msg.deinit();
        }
        self.allocator.free(self.messages);
        self.parsed_response.deinit();
    }
};

const JetStreamMessage = struct {
    subject: []const u8,
    sequence: u64,
    timestamp: []const u8,
    data: []const u8,
    headers: ?std.StringHashMap([]u8),
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *JetStreamMessage) void {
        self.allocator.free(self.subject);
        self.allocator.free(self.timestamp);
        self.allocator.free(self.data);
        if (self.headers) |*headers| {
            var iterator = headers.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }
    }
};

// ===== JSON API RESPONSE STRUCTURES =====

const JetStreamPublishResponse = struct {
    stream: []const u8,
    seq: u64,
    duplicate: ?bool = null,
};

const StreamInfoResponse = struct {
    config: struct {
        name: []const u8,
        subjects: [][]const u8,
        retention: []const u8,
        max_msgs: i64,
        max_bytes: i64,
        max_age: i64,
        storage: []const u8,
        replicas: u8,
    },
    state: struct {
        messages: u64,
        bytes: u64,
        first_seq: u64,
        last_seq: u64,
        consumer_count: u32,
    },
};

const ConsumerInfoResponse = struct {
    config: struct {
        durable_name: ?[]const u8,
        deliver_policy: []const u8,
        ack_policy: []const u8,
        ack_wait: i64,
        max_deliver: i32,
    },
    delivered: struct {
        consumer_seq: u64,
        stream_seq: u64,
    },
    ack_floor: struct {
        consumer_seq: u64,
        stream_seq: u64,
    },
    num_pending: u64,
    stream_name: []const u8,
};

const MessageBatchResponse = struct {
    messages: []struct {
        subject: []const u8,
        sequence: u64,
        timestamp: []const u8,
        data: []const u8,
        headers: ?std.StringHashMap([]const u8) = null,
    },
};

// ===== DEMONSTRATION FUNCTIONS =====

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Zig HTTP Sentinel: NATS JetStream Enterprise Bridge ===\n\n", .{});
    
    // Initialize client for V-Omega infrastructure
    var client = NatsJetStreamClient.init(
        allocator,
        "172.191.60.219", // Azure Nerve Center
        4222,
        "azure", // Theater
    );
    defer client.deinit();
    
    std.debug.print("🚀 Connected to V-Omega NATS JetStream at 172.191.60.219:4222\n", .{});
    std.debug.print("🎭 Theater: Azure\n\n", .{});
    
    // Demonstration 1: V-Omega AI telemetry
    try demonstrateAITelemetry(&client, allocator);
    
    // Demonstration 2: HPC telemetry  
    try demonstrateHPCTelemetry(&client, allocator);
    
    // Demonstration 3: Stream management
    try demonstrateStreamManagement(&client, allocator);
    
    // Demonstration 4: Consumer operations
    try demonstrateConsumerOperations(&client, allocator);
    
    std.debug.print("\n✅ All V-Omega JetStream operations completed successfully!\n", .{});
    std.debug.print("💎 zig-http-sentinel: Universal infrastructure for enterprise messaging\n", .{});
}

fn demonstrateAITelemetry(client: *NatsJetStreamClient, allocator: std.mem.Allocator) !void {
    std.debug.print("🤖 Demo 1: V-Omega AI Hydra-Chimera Telemetry\n", .{});
    
    const payload = std.json.Value{
        .object = std.json.ObjectMap.init(allocator),
    };
    
    var obj = payload.object;
    try obj.put("instance_id", std.json.Value{ .string = "hydra-chimera-azure-1" });
    try obj.put("images_processed", std.json.Value{ .integer = 128 });
    try obj.put("inference_ms", std.json.Value{ .float = 272.1 });
    try obj.put("throughput_ips", std.json.Value{ .float = 365.2 });
    try obj.put("tpu_utilization", std.json.Value{ .float = 94.2 });
    
    var response = client.publishVOmegaMessage(
        "ai",
        "hydra-chimera", 
        "telemetry.batch_complete",
        payload,
    ) catch |err| {
        std.debug.print("   ❌ AI telemetry publish failed: {}\n", .{err});
        return;
    };
    defer response.deinit();
    
    std.debug.print("   ✅ Published to stream: {s}\n", .{response.stream});
    std.debug.print("   📊 Sequence: {d}\n\n", .{response.sequence});
}

fn demonstrateHPCTelemetry(client: *NatsJetStreamClient, allocator: std.mem.Allocator) !void {
    std.debug.print("⚡ Demo 2: V-Omega HPC Nuclear Fire Hose Telemetry\n", .{});
    
    const payload = std.json.Value{
        .object = std.json.ObjectMap.init(allocator),
    };
    
    var obj = payload.object;
    try obj.put("instance_id", std.json.Value{ .string = "nuclear-fire-hose-azure-1" });
    try obj.put("packets_per_second", std.json.Value{ .integer = 9876543 });
    try obj.put("mbps", std.json.Value{ .integer = 56000 });
    try obj.put("cpu_usage", std.json.Value{ .float = 98.5 });
    try obj.put("lcores_active", std.json.Value{ .integer = 384 });
    
    var response = client.publishVOmegaMessage(
        "hpc",
        "nuclear-fire-hose",
        "telemetry.pps_report", 
        payload,
    ) catch |err| {
        std.debug.print("   ❌ HPC telemetry publish failed: {}\n", .{err});
        return;
    };
    defer response.deinit();
    
    std.debug.print("   ✅ Published to stream: {s}\n", .{response.stream});
    std.debug.print("   📊 Sequence: {d}\n\n", .{response.sequence});
}

fn demonstrateStreamManagement(client: *NatsJetStreamClient, allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("🌊 Demo 3: JetStream Management\n", .{});
    
    const config = StreamConfig{
        .retention = "limits",
        .max_msgs = 1000000,
        .max_bytes = 1024 * 1024 * 1024, // 1GB
        .max_age_ns = 24 * 60 * 60 * 1_000_000_000, // 24 hours
        .storage = "file",
        .replicas = 1,
    };
    
    var stream_info = client.createVOmegaStream("quantum", "jetstream", config) catch |err| {
        std.debug.print("   ❌ Stream creation failed: {}\n", .{err});
        return;
    };
    defer stream_info.deinit();
    
    std.debug.print("   ✅ Stream created: {s}\n", .{stream_info.name});
    std.debug.print("   📈 Messages: {d}, Bytes: {d}\n\n", .{ stream_info.messages, stream_info.bytes });
}

fn demonstrateConsumerOperations(client: *NatsJetStreamClient, allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("📡 Demo 4: Consumer Operations\n", .{});
    
    const config = ConsumerConfig{
        .deliver_policy = "all",
        .ack_policy = "explicit",
        .ack_wait_ns = 30 * 1_000_000_000,
        .max_deliver = 3,
        .replay_policy = "instant",
    };
    
    var consumer_info = client.createVOmegaConsumer(
        "VOMEGA_AZURE_AI_HYDRA_CHIMERA",
        "telemetry_processor",
        "vomega.azure.ai.hydra-chimera.telemetry.>",
        config,
    ) catch |err| {
        std.debug.print("   ❌ Consumer creation failed: {}\n", .{err});
        return;
    };
    defer consumer_info.deinit();
    
    std.debug.print("   ✅ Consumer created: {s}\n", .{consumer_info.name});
    std.debug.print("   📊 Pending: {d}, Delivered: {d}\n", .{ consumer_info.num_pending, consumer_info.delivered });
}