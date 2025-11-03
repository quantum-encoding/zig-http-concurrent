const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the main library module
    const http_sentinel = b.addModule("http-sentinel", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    // Build tests
    const lib_tests = b.addTest(.{
        .name = "lib-tests",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Build examples
    const examples = [_]struct {
        name: []const u8,
        src: []const u8,
        desc: []const u8,
    }{
        .{ .name = "basic", .src = "examples/basic.zig", .desc = "Run basic HTTP client example" },
        .{ .name = "concurrent", .src = "examples/concurrent_requests.zig", .desc = "Run concurrent requests example" },
        .{ .name = "pooling", .src = "examples/connection_pooling.zig", .desc = "Run connection pooling example" },
        .{ .name = "anthropic", .src = "examples/anthropic_client.zig", .desc = "Run Anthropic client example" },
        .{ .name = "ai-demo", .src = "examples/ai_providers_demo.zig", .desc = "Run AI providers demo" },
        .{ .name = "ai-conversation", .src = "examples/ai_conversation.zig", .desc = "Run AI conversation example" },
    };

    inline for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = b.path(example.src),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("http-sentinel", http_sentinel);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(
            b.fmt("run-{s}", .{example.name}),
            example.desc,
        );
        run_step.dependOn(&run_cmd.step);
    }
}
