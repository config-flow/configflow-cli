const std = @import("std");

/// AWS Secrets Manager client with SigV4 authentication
pub const AwsSecretsManagerClient = struct {
    allocator: std.mem.Allocator,
    region: []const u8,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        region: []const u8,
        access_key_id: []const u8,
        secret_access_key: []const u8,
        session_token: ?[]const u8,
    ) !*AwsSecretsManagerClient {
        const self = try allocator.create(AwsSecretsManagerClient);
        self.* = .{
            .allocator = allocator,
            .region = try allocator.dupe(u8, region),
            .access_key_id = try allocator.dupe(u8, access_key_id),
            .secret_access_key = try allocator.dupe(u8, secret_access_key),
            .session_token = if (session_token) |token| try allocator.dupe(u8, token) else null,
        };
        return self;
    }

    pub fn deinit(self: *AwsSecretsManagerClient) void {
        const allocator = self.allocator;
        allocator.free(self.region);
        allocator.free(self.access_key_id);
        allocator.free(self.secret_access_key);
        if (self.session_token) |token| {
            allocator.free(token);
        }
        allocator.destroy(self);
    }

    /// Get a secret value from AWS Secrets Manager
    pub fn getSecretValue(self: *AwsSecretsManagerClient, secret_id: []const u8) ![]const u8 {
        const allocator = self.allocator;

        // Build request body
        const request_body = try std.fmt.allocPrint(
            allocator,
            "{{\"SecretId\":\"{s}\"}}",
            .{secret_id},
        );
        defer allocator.free(request_body);

        // Make signed request
        const response = try self.makeSignedRequest(
            "secretsmanager.GetSecretValue",
            request_body,
        );
        defer allocator.free(response);

        // Parse response to extract SecretString or SecretBinary
        return try self.parseSecretResponse(response);
    }

    /// Make a signed AWS API request
    fn makeSignedRequest(
        self: *AwsSecretsManagerClient,
        target: []const u8,
        body: []const u8,
    ) ![]const u8 {
        const allocator = self.allocator;

        // Get current timestamp
        const timestamp = try self.getTimestamp();
        defer allocator.free(timestamp);

        const date = timestamp[0..8]; // YYYYMMDD

        // Build endpoint
        const host = try std.fmt.allocPrint(
            allocator,
            "secretsmanager.{s}.amazonaws.com",
            .{self.region},
        );
        defer allocator.free(host);

        // Calculate payload hash
        const payload_hash = try self.sha256Hex(body);
        defer allocator.free(payload_hash);

        // Build canonical headers
        const canonical_headers = try std.fmt.allocPrint(
            allocator,
            "content-type:application/x-amz-json-1.1\nhost:{s}\nx-amz-date:{s}\nx-amz-target:{s}\n",
            .{ host, timestamp, target },
        );
        defer allocator.free(canonical_headers);

        const signed_headers = "content-type;host;x-amz-date;x-amz-target";

        // Build canonical request
        const canonical_request = try std.fmt.allocPrint(
            allocator,
            "POST\n/\n\n{s}\n{s}\n{s}",
            .{ canonical_headers, signed_headers, payload_hash },
        );
        defer allocator.free(canonical_request);

        const canonical_request_hash = try self.sha256Hex(canonical_request);
        defer allocator.free(canonical_request_hash);

        // Build string to sign
        const credential_scope = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/secretsmanager/aws4_request",
            .{ date, self.region },
        );
        defer allocator.free(credential_scope);

        const string_to_sign = try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
            .{ timestamp, credential_scope, canonical_request_hash },
        );
        defer allocator.free(string_to_sign);

        // Calculate signature
        const signature = try self.calculateSignature(date, string_to_sign);
        defer allocator.free(signature);

        // Build authorization header
        const authorization = try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
            .{ self.access_key_id, credential_scope, signed_headers, signature },
        );
        defer allocator.free(authorization);

        // Make HTTP request
        return try self.httpPost(host, target, timestamp, authorization, body);
    }

    /// Calculate AWS SigV4 signature
    fn calculateSignature(self: *AwsSecretsManagerClient, date: []const u8, string_to_sign: []const u8) ![]const u8 {
        const allocator = self.allocator;

        // kSecret = "AWS4" + secret_access_key
        const k_secret = try std.fmt.allocPrint(allocator, "AWS4{s}", .{self.secret_access_key});
        defer allocator.free(k_secret);

        // kDate = HMAC-SHA256("AWS4" + secret_access_key, date)
        const k_date = try self.hmacSha256(k_secret, date);
        defer allocator.free(k_date);

        // kRegion = HMAC-SHA256(kDate, region)
        const k_region = try self.hmacSha256Bytes(k_date, self.region);
        defer allocator.free(k_region);

        // kService = HMAC-SHA256(kRegion, "secretsmanager")
        const k_service = try self.hmacSha256Bytes(k_region, "secretsmanager");
        defer allocator.free(k_service);

        // kSigning = HMAC-SHA256(kService, "aws4_request")
        const k_signing = try self.hmacSha256Bytes(k_service, "aws4_request");
        defer allocator.free(k_signing);

        // signature = HMAC-SHA256(kSigning, string_to_sign)
        const signature_bytes = try self.hmacSha256Bytes(k_signing, string_to_sign);
        defer allocator.free(signature_bytes);

        // Convert to hex
        return try self.bytesToHex(signature_bytes);
    }

    /// Calculate SHA256 hash and return as hex string
    fn sha256Hex(self: *AwsSecretsManagerClient, data: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
        return try self.bytesToHex(&hash);
    }

    /// Calculate HMAC-SHA256 from string key
    fn hmacSha256(self: *AwsSecretsManagerClient, key: []const u8, data: []const u8) ![]const u8 {
        const allocator = self.allocator;
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, data, key);
        return try allocator.dupe(u8, &mac);
    }

    /// Calculate HMAC-SHA256 from byte array key
    fn hmacSha256Bytes(self: *AwsSecretsManagerClient, key: []const u8, data: []const u8) ![]const u8 {
        const allocator = self.allocator;
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, data, key);
        return try allocator.dupe(u8, &mac);
    }

    /// Convert bytes to hex string
    fn bytesToHex(self: *AwsSecretsManagerClient, bytes: []const u8) ![]const u8 {
        const allocator = self.allocator;
        const hex_chars = "0123456789abcdef";
        var result = try allocator.alloc(u8, bytes.len * 2);
        for (bytes, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0F];
        }
        return result;
    }

    /// Get current timestamp in ISO8601 format (YYYYMMDDTHHMMSSZ)
    fn getTimestamp(self: *AwsSecretsManagerClient) ![]const u8 {
        const allocator = self.allocator;
        const timestamp_seconds = std.time.timestamp();
        const epoch_seconds = @as(i64, @intCast(timestamp_seconds));

        // Calculate date/time components
        const days_since_epoch = @divFloor(epoch_seconds, 86400);
        const seconds_today = @mod(epoch_seconds, 86400);

        // Simple epoch-to-date conversion (approximate)
        const year: u32 = 1970 + @as(u32, @intCast(@divFloor(days_since_epoch, 365)));
        const day_of_year = @mod(days_since_epoch, 365);
        const month: u32 = 1 + @as(u32, @intCast(@divFloor(day_of_year, 30)));
        const day: u32 = 1 + @as(u32, @intCast(@mod(day_of_year, 30)));

        const hour: u32 = @as(u32, @intCast(@divFloor(seconds_today, 3600)));
        const minute: u32 = @as(u32, @intCast(@divFloor(@mod(seconds_today, 3600), 60)));
        const second: u32 = @as(u32, @intCast(@mod(seconds_today, 60)));

        return try std.fmt.allocPrint(
            allocator,
            "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
            .{ year, month, day, hour, minute, second },
        );
    }

    /// Make HTTP POST request
    fn httpPost(
        self: *AwsSecretsManagerClient,
        host: []const u8,
        target: []const u8,
        timestamp: []const u8,
        authorization: []const u8,
        body: []const u8,
    ) ![]const u8 {
        const allocator = self.allocator;

        // Build URL
        const url = try std.fmt.allocPrint(allocator, "https://{s}/", .{host});
        defer allocator.free(url);

        // Parse URI
        const uri = try std.Uri.parse(url);

        // Create HTTP client
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        // Build request headers
        var headers = std.http.Headers{ .allocator = allocator };
        defer headers.deinit();

        try headers.append("Content-Type", "application/x-amz-json-1.1");
        try headers.append("X-Amz-Date", timestamp);
        try headers.append("X-Amz-Target", target);
        try headers.append("Authorization", authorization);

        if (self.session_token) |token| {
            try headers.append("X-Amz-Security-Token", token);
        }

        // Make request
        var request = try client.open(.POST, uri, headers, .{});
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = body.len };

        try request.send(.{});
        try request.writeAll(body);
        try request.finish();

        try request.wait();

        // Check status code
        if (request.response.status != .ok) {
            std.debug.print("AWS API error: HTTP {d}\n", .{@intFromEnum(request.response.status)});
            return error.AwsApiError;
        }

        // Read response body
        var response_body = std.ArrayList(u8).init(allocator);
        defer response_body.deinit();

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try request.reader().read(&buffer);
            if (bytes_read == 0) break;
            try response_body.appendSlice(buffer[0..bytes_read]);
        }

        return try response_body.toOwnedSlice();
    }

    /// Parse GetSecretValue response
    fn parseSecretResponse(self: *AwsSecretsManagerClient, response_json: []const u8) ![]const u8 {
        const allocator = self.allocator;

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            response_json,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;

        // Try to get SecretString first
        if (root.get("SecretString")) |secret_string| {
            if (secret_string == .string) {
                return try allocator.dupe(u8, secret_string.string);
            }
        }

        // If no SecretString, try SecretBinary (base64 encoded)
        if (root.get("SecretBinary")) |secret_binary| {
            if (secret_binary == .string) {
                // Decode base64
                const decoded = try self.decodeBase64(secret_binary.string);
                return decoded;
            }
        }

        return error.SecretNotFound;
    }

    /// Decode base64 string
    fn decodeBase64(self: *AwsSecretsManagerClient, encoded: []const u8) ![]const u8 {
        const allocator = self.allocator;
        const decoder = std.base64.standard.Decoder;
        const decoded_len = try decoder.calcSizeForSlice(encoded);
        const decoded = try allocator.alloc(u8, decoded_len);
        try decoder.decode(decoded, encoded);
        return decoded;
    }
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "AwsSecretsManagerClient init and deinit" {
    const allocator = std.testing.allocator;

    const client = try AwsSecretsManagerClient.init(
        allocator,
        "us-east-1",
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        null,
    );
    defer client.deinit();

    try expectEqualStrings("us-east-1", client.region);
    try expectEqualStrings("AKIAIOSFODNN7EXAMPLE", client.access_key_id);
    try expect(client.session_token == null);
}

test "AwsSecretsManagerClient init with session token" {
    const allocator = std.testing.allocator;

    const client = try AwsSecretsManagerClient.init(
        allocator,
        "us-west-2",
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "FwoGZXIvYXdzEBEaDCx1...",
    );
    defer client.deinit();

    try expect(client.session_token != null);
    try expectEqualStrings("FwoGZXIvYXdzEBEaDCx1...", client.session_token.?);
}

test "bytesToHex conversion" {
    const allocator = std.testing.allocator;

    const client = try AwsSecretsManagerClient.init(
        allocator,
        "us-east-1",
        "test",
        "test",
        null,
    );
    defer client.deinit();

    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const hex = try client.bytesToHex(&bytes);
    defer allocator.free(hex);

    try expectEqualStrings("deadbeef", hex);
}

test "sha256Hex produces correct hash" {
    const allocator = std.testing.allocator;

    const client = try AwsSecretsManagerClient.init(
        allocator,
        "us-east-1",
        "test",
        "test",
        null,
    );
    defer client.deinit();

    const hash = try client.sha256Hex("hello");
    defer allocator.free(hash);

    // SHA256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    try expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hash);
}
