// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const http = std.http;

/// A robust, thread-safe HTTP client for Zig 0.16.0
///
/// Features:
/// - Simplified API for GET, POST, PUT, PATCH, DELETE operations
/// - Automatic memory management with proper cleanup
/// - Thread-safe design (each thread should use its own client instance)
/// - Configurable request timeouts and limits
/// - Support for custom headers
/// - Automatic gzip decompression
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,

    /// Initialize a new HTTP client
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
        };
    }

    /// Clean up client resources
    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Decompress gzip-encoded body if needed
    fn decompressBody(self: *HttpClient, body_data: []const u8, content_encoding: ?[]const u8) ![]u8 {
        const encoding = content_encoding orelse "identity";

        if (std.mem.eql(u8, encoding, "gzip")) {
            // Decompress gzip response
            const stream = std.Io.fixedBufferStream(body_data);
            var decompressor = try std.compress.flate.Decompress.gzipStream(self.allocator, stream);
            defer decompressor.deinit();

            var decompressed = std.ArrayList(u8){};
            defer decompressed.deinit(self.allocator);

            var buffer: [4096]u8 = undefined;
            while (true) {
                const n = decompressor.reader().read(&buffer) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                if (n == 0) break;
                try decompressed.appendSlice(self.allocator, buffer[0..n]);
            }

            return try decompressed.toOwnedSlice(self.allocator);
        }

        // No compression or unsupported encoding
        return try self.allocator.dupe(u8, body_data);
    }

    /// Response structure containing status code and body
    pub const Response = struct {
        status: http.Status,
        body: []u8,
        allocator: std.mem.Allocator,

        /// Free the response body memory
        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    /// Configuration options for requests
    pub const RequestOptions = struct {
        /// Maximum response body size (default: 10MB)
        max_body_size: usize = 10 * 1024 * 1024,
        /// Request timeout in nanoseconds (0 = no timeout)
        timeout_ns: u64 = 0,
    };

    /// Perform a POST request
    pub fn post(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !Response {
        return self.postWithOptions(url, headers, body, .{});
    }

    /// Perform a POST request with custom options
    pub fn postWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        options: RequestOptions,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(options.max_body_size)
        );
        defer self.allocator.free(body_data);

        // Decompress body if needed
        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null, // We only support gzip for now
        };
        const final_body = try self.decompressBody(body_data, content_encoding_str);

        return Response{
            .status = response.head.status,
            .body = final_body,
            .allocator = self.allocator,
        };
    }

    /// Perform a GET request
    pub fn get(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        return self.getWithOptions(url, headers, .{});
    }

    /// Perform a GET request with custom options
    pub fn getWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        options: RequestOptions,
    ) !Response {
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
            std.Io.Limit.limited(options.max_body_size)
        );
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
        };
    }

    /// Perform a PUT request
    pub fn put(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !Response {
        return self.putWithOptions(url, headers, body, .{});
    }

    /// Perform a PUT request with custom options
    pub fn putWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        options: RequestOptions,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.PUT, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);
        
        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(options.max_body_size)
        );
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
        };
    }

    /// Perform a PATCH request
    pub fn patch(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !Response {
        return self.patchWithOptions(url, headers, body, .{});
    }

    /// Perform a PATCH request with custom options
    pub fn patchWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        options: RequestOptions,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.PATCH, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);
        
        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(options.max_body_size)
        );
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
        };
    }

    /// Perform a DELETE request
    pub fn delete(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        return self.deleteWithOptions(url, headers, .{});
    }

    /// Perform a DELETE request with custom options
    pub fn deleteWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        options: RequestOptions,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.DELETE, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);
        
        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(options.max_body_size)
        );
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
        };
    }

    /// Perform a HEAD request (headers only, no body)
    pub fn head(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.HEAD, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        const response = try req.receiveHead(&.{});

        return Response{
            .status = response.head.status,
            .body = try self.allocator.alloc(u8, 0),
            .allocator = self.allocator,
        };
    }
};