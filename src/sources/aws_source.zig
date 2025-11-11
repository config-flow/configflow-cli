const std = @import("std");
const source = @import("source.zig");
const SourceBackend = source.SourceBackend;
const SourceValue = source.SourceValue;
const clients = @import("clients");
const AwsSecretsManagerClient = clients.AwsSecretsManagerClient;

/// AWS Secrets Manager fetch mode
pub const AwsMode = enum {
    /// Each config key is a separate AWS secret
    individual,
    /// One AWS secret contains JSON with multiple keys
    json,

    pub fn fromString(s: []const u8) !AwsMode {
        if (std.mem.eql(u8, s, "individual")) return .individual;
        if (std.mem.eql(u8, s, "json")) return .json;
        return error.InvalidMode;
    }
};

/// AWS Secrets Manager source backend
pub const AwsSource = struct {
    allocator: std.mem.Allocator,
    source_name: []const u8,
    client: *AwsSecretsManagerClient,
    mode: AwsMode,
    prefix: ?[]const u8, // For individual mode
    secret_name: ?[]const u8, // For json mode
    json_cache: ?std.StringHashMap([]const u8), // Cached JSON secret for json mode

    pub fn init(
        allocator: std.mem.Allocator,
        source_name: []const u8,
        region: ?[]const u8,
        mode: AwsMode,
        prefix: ?[]const u8,
        secret_name: ?[]const u8,
    ) !*AwsSource {
        // Resolve region with precedence: AWS_REGION env var > parameter > error
        const resolved_region = try resolveRegion(allocator, region);
        errdefer allocator.free(resolved_region);

        // Resolve credentials
        const credentials = try resolveCredentials(allocator);
        errdefer {
            allocator.free(credentials.access_key_id);
            allocator.free(credentials.secret_access_key);
            if (credentials.session_token) |token| allocator.free(token);
        }

        // Create AWS client
        const client = try AwsSecretsManagerClient.init(
            allocator,
            resolved_region,
            credentials.access_key_id,
            credentials.secret_access_key,
            credentials.session_token,
        );
        errdefer client.deinit();

        // Free credentials (client has copies)
        allocator.free(credentials.access_key_id);
        allocator.free(credentials.secret_access_key);
        if (credentials.session_token) |token| allocator.free(token);
        allocator.free(resolved_region);

        const self = try allocator.create(AwsSource);
        self.* = .{
            .allocator = allocator,
            .source_name = try allocator.dupe(u8, source_name),
            .client = client,
            .mode = mode,
            .prefix = if (prefix) |p| try allocator.dupe(u8, p) else null,
            .secret_name = if (secret_name) |s| try allocator.dupe(u8, s) else null,
            .json_cache = null,
        };

        // Validate configuration
        if (mode == .individual and self.prefix == null) {
            std.debug.print("Error: individual mode requires a prefix\n", .{});
            self.deinit();
            return error.MissingPrefix;
        }
        if (mode == .json and self.secret_name == null) {
            std.debug.print("Error: json mode requires a secret_name\n", .{});
            self.deinit();
            return error.MissingSecretName;
        }

        return self;
    }

    pub fn backend(self: *AwsSource) SourceBackend {
        return .{
            .ctx = self,
            .fetchFn = fetch,
            .fetchAllFn = fetchAll,
            .deinitFn = deinit,
        };
    }

    fn fetch(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) !?SourceValue {
        const self: *AwsSource = @ptrCast(@alignCast(ctx));

        const value_str = switch (self.mode) {
            .individual => blk: {
                // Build secret ID: prefix + key
                const secret_id = try std.fmt.allocPrint(
                    allocator,
                    "{s}{s}",
                    .{ self.prefix.?, key },
                );
                defer allocator.free(secret_id);

                // Fetch from AWS
                break :blk self.client.getSecretValue(secret_id) catch |err| {
                    if (err == error.SecretNotFound) {
                        return null;
                    }
                    return err;
                };
            },
            .json => blk: {
                // Load JSON secret into cache if not already loaded
                if (self.json_cache == null) {
                    try self.loadJsonCache();
                }

                // Look up key in cache
                const cached = self.json_cache.?.get(key) orelse return null;
                break :blk try allocator.dupe(u8, cached);
            },
        };

        return SourceValue{
            .value = value_str,
            .source_name = try allocator.dupe(u8, self.source_name),
            .source_type = try allocator.dupe(u8, "aws"),
            .allocator = allocator,
        };
    }

    fn fetchAll(ctx: *anyopaque, allocator: std.mem.Allocator) !std.StringHashMap(SourceValue) {
        const self: *AwsSource = @ptrCast(@alignCast(ctx));

        var result = std.StringHashMap(SourceValue).init(allocator);

        switch (self.mode) {
            .individual => {
                // In individual mode, we can't list all secrets from AWS without pagination
                // For now, return empty map (this is a limitation of individual mode)
                std.debug.print("Warning: fetchAll not fully supported in individual mode\n", .{});
                return result;
            },
            .json => {
                // Load JSON secret into cache if not already loaded
                if (self.json_cache == null) {
                    try self.loadJsonCache();
                }

                // Return all cached values
                var iter = self.json_cache.?.iterator();
                while (iter.next()) |entry| {
                    const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                    const val = SourceValue{
                        .value = try allocator.dupe(u8, entry.value_ptr.*),
                        .source_name = try allocator.dupe(u8, self.source_name),
                        .source_type = try allocator.dupe(u8, "aws"),
                        .allocator = allocator,
                    };
                    try result.put(key_copy, val);
                }
            },
        }

        return result;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *AwsSource = @ptrCast(@alignCast(ctx));
        const allocator = self.allocator;

        allocator.free(self.source_name);
        self.client.deinit();
        if (self.prefix) |prefix| allocator.free(prefix);
        if (self.secret_name) |secret_name| allocator.free(secret_name);

        // Free JSON cache
        if (self.json_cache) |*cache| {
            var iter = cache.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            cache.deinit();
        }

        allocator.destroy(self);
    }

    /// Load JSON secret into cache
    fn loadJsonCache(self: *AwsSource) !void {
        const allocator = self.allocator;

        // Fetch the JSON secret
        const secret_json = try self.client.getSecretValue(self.secret_name.?);
        defer allocator.free(secret_json);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            secret_json,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;

        // Build cache
        var cache = std.StringHashMap([]const u8).init(allocator);
        var iter = root.iterator();
        while (iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = switch (entry.value_ptr.*) {
                .string => |s| try allocator.dupe(u8, s),
                .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
                .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
                .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
                else => try allocator.dupe(u8, ""),
            };
            try cache.put(key, value);
        }

        self.json_cache = cache;
    }
};

/// AWS credentials
const AwsCredentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8,
};

/// Resolve AWS credentials with priority order:
/// 1. Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN)
/// 2. AWS credentials file (~/.aws/credentials) [default profile]
/// 3. Error if not found
fn resolveCredentials(allocator: std.mem.Allocator) !AwsCredentials {
    // Try environment variables first
    const access_key = std.process.getEnvVarOwned(allocator, "AWS_ACCESS_KEY_ID") catch null;
    const secret_key = std.process.getEnvVarOwned(allocator, "AWS_SECRET_ACCESS_KEY") catch null;
    const session_token = std.process.getEnvVarOwned(allocator, "AWS_SESSION_TOKEN") catch null;

    if (access_key != null and secret_key != null) {
        return AwsCredentials{
            .access_key_id = access_key.?,
            .secret_access_key = secret_key.?,
            .session_token = session_token,
        };
    }

    // Clean up partial env vars
    if (access_key) |key| allocator.free(key);
    if (secret_key) |key| allocator.free(key);
    if (session_token) |token| allocator.free(token);

    // Try AWS credentials file
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("Error: No AWS credentials found (env vars or ~/.aws/credentials)\n", .{});
        return error.NoCredentials;
    };
    defer allocator.free(home);

    const credentials_path = try std.fmt.allocPrint(allocator, "{s}/.aws/credentials", .{home});
    defer allocator.free(credentials_path);

    const creds = parseAwsCredentialsFile(allocator, credentials_path, "default") catch {
        std.debug.print("Error: No AWS credentials found (env vars or ~/.aws/credentials)\n", .{});
        return error.NoCredentials;
    };

    return creds;
}

/// Parse AWS credentials file
fn parseAwsCredentialsFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    profile: []const u8,
) !AwsCredentials {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var in_profile = false;
    var access_key_id: ?[]const u8 = null;
    var secret_access_key: ?[]const u8 = null;
    var session_token: ?[]const u8 = null;

    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Check for profile section
        if (trimmed[0] == '[') {
            const profile_name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
            in_profile = std.mem.eql(u8, profile_name, profile);
            continue;
        }

        if (!in_profile) continue;

        // Parse key = value
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            if (std.mem.eql(u8, key, "aws_access_key_id")) {
                access_key_id = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "aws_secret_access_key")) {
                secret_access_key = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "aws_session_token")) {
                session_token = try allocator.dupe(u8, value);
            }
        }
    }

    if (access_key_id == null or secret_access_key == null) {
        if (access_key_id) |key| allocator.free(key);
        if (secret_access_key) |key| allocator.free(key);
        if (session_token) |token| allocator.free(token);
        return error.InvalidCredentialsFile;
    }

    return AwsCredentials{
        .access_key_id = access_key_id.?,
        .secret_access_key = secret_access_key.?,
        .session_token = session_token,
    };
}

/// Resolve AWS region with priority order:
/// 1. AWS_REGION environment variable
/// 2. Parameter (from configflow.yml)
/// 3. Error if not found
///
/// If both are set and different, print a warning that AWS_REGION is overriding
fn resolveRegion(allocator: std.mem.Allocator, config_region: ?[]const u8) ![]const u8 {
    const env_region = std.process.getEnvVarOwned(allocator, "AWS_REGION") catch null;

    if (env_region) |env_r| {
        // AWS_REGION env var is set
        if (config_region) |config_r| {
            // Both are set - check if they differ
            if (!std.mem.eql(u8, env_r, config_r)) {
                std.debug.print(
                    "Warning: AWS_REGION env var '{s}' is overriding configflow.yml region '{s}'\n",
                    .{ env_r, config_r },
                );
            }
        }
        return env_r;
    }

    // No env var, use config
    if (config_region) |config_r| {
        return try allocator.dupe(u8, config_r);
    }

    // Neither set
    std.debug.print("Error: AWS region not configured (set AWS_REGION env var or region in configflow.yml)\n", .{});
    return error.NoRegion;
}

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test "AwsMode fromString parses valid modes" {
    try expect((try AwsMode.fromString("individual")) == .individual);
    try expect((try AwsMode.fromString("json")) == .json);
}

test "AwsMode fromString rejects invalid modes" {
    try expectError(error.InvalidMode, AwsMode.fromString("invalid"));
    try expectError(error.InvalidMode, AwsMode.fromString(""));
}

// Note: Region resolution tests are skipped because environment variable
// manipulation (setEnvVar/unsetEnvVar) is not available in Zig 0.15.1 test environment.
// The resolveRegion function is tested indirectly through integration tests.
