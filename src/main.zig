// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! AI Providers CLI - Main Entry Point

const std = @import("std");
const cli = @import("cli.zig");
const batch = @import("batch.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments
    var config = cli.CLIConfig{};
    var provider_set = false;
    var prompt: ?[]const u8 = null;
    var show_list = false;
    var show_help = false;

    // Batch mode options
    var batch_mode = false;
    var batch_input: ?[]const u8 = null;
    var batch_output: ?[]const u8 = null;
    var batch_concurrency: u32 = 50;
    var batch_full_responses = false;
    var batch_retry: u32 = 2;

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            show_list = true;
        } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            config.interactive = true;
        } else if (std.mem.eql(u8, arg, "--temperature") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("❌ Error: --temperature requires a value\n", .{});
                return error.MissingArgument;
            }
            config.temperature = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, arg, "--max-tokens") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("❌ Error: --max-tokens requires a value\n", .{});
                return error.MissingArgument;
            }
            config.max_tokens = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("❌ Error: --system requires a value\n", .{});
                return error.MissingArgument;
            }
            config.system_prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--no-usage")) {
            config.show_usage = false;
        } else if (std.mem.eql(u8, arg, "--no-cost")) {
            config.show_cost = false;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("❌ Error: Unknown option: {s}\n", .{arg});
            cli.printUsage();
            return error.UnknownOption;
        } else {
            // Check if it's a provider name
            if (!provider_set) {
                if (cli.Provider.fromString(arg)) |provider| {
                    config.provider = provider;
                    provider_set = true;
                    continue;
                }
            }

            // Otherwise it's the prompt
            if (prompt == null) {
                prompt = arg;
            } else {
                std.debug.print("❌ Error: Multiple prompts provided. Use quotes for multi-word prompts.\n", .{});
                return error.MultiplePrompts;
            }
        }
    }

    // Handle special commands
    if (show_help) {
        cli.printUsage();
        return;
    }

    if (show_list) {
        cli.listProviders();
        return;
    }

    // Check if API key is set
    const env_var = config.provider.getEnvVar();
    const has_key = std.process.hasEnvVar(allocator, env_var) catch false;
    if (!has_key) {
        std.debug.print("❌ Error: {s} environment variable not set\n", .{env_var});
        std.debug.print("\n   Set it with:\n", .{});
        std.debug.print("   export {s}=your_api_key_here\n\n", .{env_var});
        return error.MissingApiKey;
    }

    var tool = cli.CLI.init(allocator, config);

    // Run interactive or one-shot mode
    if (config.interactive) {
        try tool.interactive();
    } else {
        if (prompt) |p| {
            try tool.query(p);
        } else {
            std.debug.print("❌ Error: No prompt provided\n\n", .{});
            cli.printUsage();
            return error.MissingPrompt;
        }
    }
}
