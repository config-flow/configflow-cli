const std = @import("std");
const source = @import("source.zig");
const SourceBackend = source.SourceBackend;
const SourceValue = source.SourceValue;

/// Vault source backend - reads secrets from HashiCorp Vault
pub const VaultSource = struct {
    allocator: std.mem.Allocator,
    source_name: []const u8,
    vault_addr: []const u8,
    vault_token: []const u8,
    mount_path: []const u8, // e.g., "secret"
    secret_path: []const u8, // e.g., "myapp/config"
    kv_version: u8, // 1 or 2 (default: 2)

    pub fn init(
        allocator: std.mem.Allocator,
        source_name: []const u8,
        vault_addr: ?[]const u8,
        vault_token: ?[]const u8,
        mount_path: []const u8,
        secret_path: []const u8,
        kv_version: ?u8,
    ) !*VaultSource {
        // Get Vault address from parameter or environment
        const addr = if (vault_addr) |a|
            try allocator.dupe(u8, a)
        else
            std.process.getEnvVarOwned(allocator, "VAULT_ADDR") catch |err| {
                std.debug.print("Error: VAULT_ADDR not set and no vault_addr provided\n", .{});
                return err;
            };

        // Get Vault token from parameter or environment
        const token = if (vault_token) |t|
            try allocator.dupe(u8, t)
        else
            std.process.getEnvVarOwned(allocator, "VAULT_TOKEN") catch |err| {
                std.debug.print("Error: VAULT_TOKEN not set and no vault_token provided\n", .{});
                allocator.free(addr);
                return err;
            };

        const self = try allocator.create(VaultSource);
        self.* = .{
            .allocator = allocator,
            .source_name = try allocator.dupe(u8, source_name),
            .vault_addr = addr,
            .vault_token = token,
            .mount_path = try allocator.dupe(u8, mount_path),
            .secret_path = try allocator.dupe(u8, secret_path),
            .kv_version = kv_version orelse 2,
        };
        return self;
    }

    pub fn backend(self: *VaultSource) SourceBackend {
        return .{
            .ctx = self,
            .fetchFn = fetch,
            .fetchAllFn = fetchAll,
            .deinitFn = deinit,
        };
    }

    fn fetch(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) !?SourceValue {
        const self: *VaultSource = @ptrCast(@alignCast(ctx));

        // Fetch all secrets from Vault
        var secrets = try self.fetchSecretsFromVault(allocator);
        defer {
            var iter = secrets.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            secrets.deinit();
        }

        // Look up the requested key
        const value = secrets.get(key) orelse return null;

        return SourceValue{
            .value = try allocator.dupe(u8, value),
            .source_name = try allocator.dupe(u8, self.source_name),
            .source_type = try allocator.dupe(u8, "vault"),
            .allocator = allocator,
        };
    }

    fn fetchAll(ctx: *anyopaque, allocator: std.mem.Allocator) !std.StringHashMap(SourceValue) {
        const self: *VaultSource = @ptrCast(@alignCast(ctx));

        // Fetch all secrets from Vault
        var secrets = try self.fetchSecretsFromVault(allocator);
        defer {
            var iter = secrets.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            secrets.deinit();
        }

        var result = std.StringHashMap(SourceValue).init(allocator);

        var iter = secrets.iterator();
        while (iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const val = SourceValue{
                .value = try allocator.dupe(u8, entry.value_ptr.*),
                .source_name = try allocator.dupe(u8, self.source_name),
                .source_type = try allocator.dupe(u8, "vault"),
                .allocator = allocator,
            };
            try result.put(key, val);
        }

        return result;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *VaultSource = @ptrCast(@alignCast(ctx));
        const allocator = self.allocator;

        allocator.free(self.source_name);
        allocator.free(self.vault_addr);
        allocator.free(self.vault_token);
        allocator.free(self.mount_path);
        allocator.free(self.secret_path);

        allocator.destroy(self);
    }

    fn fetchSecretsFromVault(self: *VaultSource, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = std.StringHashMap([]const u8).init(allocator);

        // Build the API path based on KV version
        const api_path = if (self.kv_version == 2)
            try std.fmt.allocPrint(allocator, "/v1/{s}/data/{s}", .{ self.mount_path, self.secret_path })
        else
            try std.fmt.allocPrint(allocator, "/v1/{s}/{s}", .{ self.mount_path, self.secret_path });
        defer allocator.free(api_path);

        // Build the full URL
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.vault_addr, api_path });
        defer allocator.free(url);

        const uri = try std.Uri.parse(url);

        // Create HTTP client
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        // Create request with custom headers
        var request = try client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "X-Vault-Token", .value = self.vault_token },
            },
        });
        defer request.deinit();

        // Send request
        try request.sendBodiless();

        // Receive response headers
        var redirect_buffer: [8 * 1024]u8 = undefined;
        const response = try request.receiveHead(&redirect_buffer);

        // Check response status
        if (response.head.status != .ok) {
            std.debug.print("Vault request failed with status: {}\n", .{response.head.status});
            return error.VaultRequestFailed;
        }

        // Read response body
        var transfer_buffer: [8 * 1024]u8 = undefined;
        var reader_buffer: [8 * 1024]u8 = undefined;
        const content_length = response.head.content_length;

        // Use chunked encoding if no content-length is provided
        const transfer_encoding: std.http.TransferEncoding = if (content_length == null) .chunked else .none;
        const reader = request.reader.bodyReader(&transfer_buffer, transfer_encoding, content_length);

        var response_body = std.ArrayList(u8){};
        defer response_body.deinit(allocator);

        var bytes_read: usize = 0;
        while (true) {
            const size = try reader.readSliceShort(&reader_buffer);
            if (size == 0) break;

            try response_body.appendSlice(allocator, reader_buffer[0..size]);
            bytes_read += size;

            if (content_length) |c_len| {
                if (bytes_read >= c_len) break;
            }

            if (size < reader_buffer.len) break;
        }

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body.items, .{});
        defer parsed.deinit();

        const root = parsed.value;

        // Navigate JSON structure based on KV version
        const data_obj = if (self.kv_version == 2) blk: {
            // KV v2: response.data.data
            const data = root.object.get("data") orelse return error.InvalidVaultResponse;
            break :blk data.object.get("data") orelse return error.InvalidVaultResponse;
        } else blk: {
            // KV v1: response.data
            break :blk root.object.get("data") orelse return error.InvalidVaultResponse;
        };

        // Extract key-value pairs
        var iter = data_obj.object.iterator();
        while (iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value_str = switch (entry.value_ptr.*) {
                .string => |s| try allocator.dupe(u8, s),
                .integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
                .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
                .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
                else => try allocator.dupe(u8, ""),
            };
            try result.put(key, value_str);
        }

        return result;
    }
};
