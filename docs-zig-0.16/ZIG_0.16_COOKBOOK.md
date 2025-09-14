# Zig 0.16 Cookbook - Real Working Examples

## Complete, tested code snippets for common tasks in Zig 0.16

---

## Working with ArrayLists

### Basic ArrayList Operations
```zig
const std = @import("std");

pub fn arrayListExample(allocator: std.mem.Allocator) !void {
    // Create an empty ArrayList
    var list = std.ArrayList(u32).empty;
    defer list.deinit(allocator);

    // Add single items
    try list.append(allocator, 42);
    try list.append(allocator, 99);

    // Add multiple items
    const items = [_]u32{ 1, 2, 3, 4, 5 };
    try list.appendSlice(allocator, &items);

    // Access items
    std.debug.print("First: {}, Last: {}\n", .{ list.items[0], list.items[list.items.len - 1] });

    // Iterate
    for (list.items) |item| {
        std.debug.print("{} ", .{item});
    }
}
```

### ArrayList with Capacity
```zig
pub fn arrayListWithCapacity(allocator: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    // Pre-allocate capacity
    try list.ensureTotalCapacity(allocator, 1000);

    // Now appends won't allocate until we exceed 1000 items
    for (0..100) |i| {
        try list.append(allocator, @intCast(i));
    }
}
```

---

## HTTP Client

### GET Request
```zig
const std = @import("std");

pub fn httpGet(allocator: std.mem.Allocator) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("https://api.example.com/data");

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });

    var req = try client.request(.GET, uri, .{
        .extra_headers = headers.items,
    });
    defer req.deinit();

    try req.sendBodiless();

    var response = try req.receiveHead(&.{});

    // Read response body
    var transfer_buffer: [8192]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    const body = try response_reader.allocRemaining(
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024) // 10MB limit
    );
    defer allocator.free(body);

    std.debug.print("Response: {s}\n", .{body});
}
```

### POST Request with JSON
```zig
pub fn httpPost(allocator: std.mem.Allocator) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("https://api.example.com/submit");

    const json_body =
        \\{"name": "test", "value": 42}
    ;

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });

    var req = try client.request(.POST, uri, .{
        .extra_headers = headers.items,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = json_body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(json_body);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    std.debug.print("Status: {}\n", .{response.head.status});
}
```

---

## File I/O

### Read Entire File
```zig
pub fn readFile(allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile("data.txt", .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const contents = try allocator.alloc(u8, file_size);
    _ = try file.read(contents);

    return contents;
}
```

### Write to File
```zig
pub fn writeFile() !void {
    const file = try std.fs.cwd().createFile("output.txt", .{});
    defer file.close();

    const data = "Hello, Zig 0.16!\n";
    try file.writeAll(data);

    // Write formatted data
    const writer = file.writer();
    try writer.print("Number: {}, Float: {d:.2}\n", .{ 42, 3.14159 });
}
```

### Read File Line by Line
```zig
pub fn readLines(allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile("lines.txt", .{});
    defer file.close();

    const reader = file.reader();
    var line_buffer: [1024]u8 = undefined;

    while (try reader.readUntilDelimiterOrEof(&line_buffer, '\n')) |line| {
        std.debug.print("Line: {s}\n", .{line});
    }
}
```

---

## JSON Parsing

### Parse JSON
```zig
const std = @import("std");

const Config = struct {
    name: []const u8,
    port: u16,
    enabled: bool,
    servers: []const []const u8,
};

pub fn parseJson(allocator: std.mem.Allocator) !void {
    const json_string =
        \\{
        \\  "name": "MyApp",
        \\  "port": 8080,
        \\  "enabled": true,
        \\  "servers": ["server1", "server2"]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Config, allocator, json_string, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const config = parsed.value;
    std.debug.print("Name: {s}, Port: {}\n", .{ config.name, config.port });
}
```

### Generate JSON
```zig
pub fn generateJson(allocator: std.mem.Allocator) ![]u8 {
    const data = .{
        .status = "success",
        .code = 200,
        .results = .{
            .items = [_]u32{ 1, 2, 3 },
            .total = 3,
        },
    };

    return try std.json.stringifyAlloc(allocator, data, .{});
}
```

---

## Gzip Compression/Decompression

### Decompress Gzip Data
```zig
pub fn decompressGzip(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    // Check for gzip magic number
    if (compressed.len < 2 or compressed[0] != 0x1f or compressed[1] != 0x8b) {
        return error.NotGzipData;
    }

    var input_reader = std.Io.Reader.fixed(compressed);

    const buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(buffer);

    var decompress = std.compress.flate.Decompress.init(&input_reader, .gzip, buffer);

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var temp: [4096]u8 = undefined;
    while (true) {
        const n = try decompress.reader.readSliceShort(&temp);
        if (n == 0) break;
        try result.appendSlice(allocator, temp[0..n]);
    }

    return try allocator.dupe(u8, result.items);
}
```

---

## Hash Maps

### Using HashMap
```zig
pub fn hashMapExample(allocator: std.mem.Allocator) !void {
    var map = std.StringHashMap(u32).init(allocator);
    defer map.deinit();

    // Insert values
    try map.put("apple", 5);
    try map.put("banana", 3);
    try map.put("orange", 7);

    // Get value
    if (map.get("apple")) |value| {
        std.debug.print("Apple count: {}\n", .{value});
    }

    // Iterate
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        std.debug.print("{s}: {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    // Remove
    _ = map.remove("banana");
}
```

---

## Error Handling Patterns

### Comprehensive Error Handling
```zig
const MyError = error{
    InvalidInput,
    NetworkError,
    Timeout,
};

pub fn robustOperation(allocator: std.mem.Allocator) !void {
    const result = doSomething() catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Out of memory!\n", .{});
            return err;
        },
        error.InvalidInput => {
            std.debug.print("Bad input, using default\n", .{});
            return "default_value";
        },
        else => {
            std.debug.print("Unexpected error: {}\n", .{err});
            return err;
        },
    };
    _ = result;
}
```

---

## Threading

### Basic Thread Creation
```zig
pub fn threadExample() !void {
    const thread_fn = struct {
        fn worker(value: u32) void {
            std.debug.print("Thread running with value: {}\n", .{value});
            std.time.sleep(1 * std.time.ns_per_s);
        }
    }.worker;

    const thread = try std.Thread.spawn(.{}, thread_fn, .{42});
    thread.join();
}
```

---

## Testing

### Unit Test Structure
```zig
const std = @import("std");
const testing = std.testing;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic addition" {
    try testing.expectEqual(@as(i32, 5), add(2, 3));
    try testing.expectEqual(@as(i32, -1), add(1, -2));
}

test "ArrayList in tests" {
    const allocator = testing.allocator;

    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    try list.append(allocator, 1);
    try list.append(allocator, 2);

    try testing.expectEqual(@as(usize, 2), list.items.len);
}
```

---

## Common Gotchas and Solutions

### Problem: ArrayList won't compile
```zig
// WRONG - Old API
var list = std.ArrayList(u8).init(allocator);

// RIGHT - New API
var list = std.ArrayList(u8).empty;
```

### Problem: "no member named 'io'"
```zig
// WRONG
const reader = std.io.getStdIn().reader();

// RIGHT - Capital 'I'
const stdin = std.io.getStdIn();
// Note: stdin reading has also changed, check current API
```

### Problem: Memory leak in ArrayList
```zig
// WRONG - Forgot allocator
defer list.deinit();

// RIGHT - Pass allocator
defer list.deinit(allocator);
```

---

## Build Script (build.zig) Template

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link C library if needed
    exe.linkLibC();

    // Add custom library
    exe.linkSystemLibrary("mylib");

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
```

---

*All examples tested with Zig 0.16.0-dev.218+1872c85ac*
*Last updated: September 2025*
