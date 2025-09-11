// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");

// Core HTTP client
pub const HttpClient = @import("http_client.zig").HttpClient;

// Connection pooling (legacy - has issues with Zig 0.16.0)
pub const pool = @import("pool/pool.zig");

// Client pooling (recommended - client-per-worker pattern)
pub const client_pool = @import("pool/client_pool.zig");

// Retry engine
pub const retry = @import("retry/retry.zig");

// Error definitions
pub const errors = @import("errors.zig");

// Re-export main types for convenience
pub const ConnectionPool = pool.ConnectionPool;
pub const ClientPool = client_pool.ClientPool;
pub const HttpWorker = client_pool.HttpWorker;
pub const RetryEngine = retry.RetryEngine;
pub const HttpError = errors.HttpError;

test {
    std.testing.refAllDecls(@This());
}