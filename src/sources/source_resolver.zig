const std = @import("std");
const yaml = @import("yaml");
const source = @import("source.zig");
const FileSource = @import("file_source.zig").FileSource;
const EnvSource = @import("env_source.zig").EnvSource;
const VaultSource = @import("vault_source.zig").VaultSource;

const SourceBackend = source.SourceBackend;
const SourceConfig = source.SourceConfig;

/// Source resolver - parses YAML config and creates appropriate backends
pub const SourceResolver = struct {
    allocator: std.mem.Allocator,
    sources: std.StringHashMap(SourceBackend),

    pub fn init(allocator: std.mem.Allocator) SourceResolver {
        return .{
            .allocator = allocator,
            .sources = std.StringHashMap(SourceBackend).init(allocator),
        };
    }

    pub fn deinit(self: *SourceResolver) void {
        var iter = self.sources.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.sources.deinit();
    }

    /// Parse sources from YAML and register them
    pub fn parseAndRegisterSources(self: *SourceResolver, sources_yaml: yaml.Yaml.Value) !void {
        const sources_map = sources_yaml.asMap() orelse return error.InvalidSourcesFormat;

        var iter = sources_map.iterator();
        while (iter.next()) |entry| {
            const source_name = entry.key_ptr.*;
            const source_config = entry.value_ptr.*;

            // Parse source configuration
            const config_map = source_config.asMap() orelse {
                std.debug.print("Warning: Invalid config for source '{s}', skipping\n", .{source_name});
                continue;
            };

            // Get source type
            const type_value = config_map.get("type") orelse {
                std.debug.print("Warning: No type specified for source '{s}', skipping\n", .{source_name});
                continue;
            };

            const source_type = type_value.asScalar() orelse {
                std.debug.print("Warning: Invalid type for source '{s}', skipping\n", .{source_name});
                continue;
            };

            // Skip null sources (not yet configured)
            if (std.mem.eql(u8, source_type, "null")) {
                continue;
            }

            // Create backend based on type
            const backend = try self.createBackend(source_name, source_type, config_map);
            const name_copy = try self.allocator.dupe(u8, source_name);
            try self.sources.put(name_copy, backend);
        }
    }

    /// Get a source backend by name
    pub fn getSource(self: *SourceResolver, source_name: []const u8) ?SourceBackend {
        return self.sources.get(source_name);
    }

    /// List all registered source names
    pub fn listSources(self: *SourceResolver, allocator: std.mem.Allocator) ![][]const u8 {
        const count = self.sources.count();
        const list = try allocator.alloc([]const u8, count);

        var i: usize = 0;
        var iter = self.sources.keyIterator();
        while (iter.next()) |key| : (i += 1) {
            list[i] = try allocator.dupe(u8, key.*);
        }

        return list;
    }

    fn createBackend(self: *SourceResolver, source_name: []const u8, source_type: []const u8, config: yaml.Yaml.Map) !SourceBackend {
        if (std.mem.eql(u8, source_type, "file")) {
            return try self.createFileBackend(source_name, config);
        } else if (std.mem.eql(u8, source_type, "env")) {
            return try self.createEnvBackend(source_name, config);
        } else if (std.mem.eql(u8, source_type, "vault")) {
            return try self.createVaultBackend(source_name, config);
        } else {
            std.debug.print("Warning: Unknown source type '{s}' for source '{s}'\n", .{ source_type, source_name });
            return error.UnknownSourceType;
        }
    }

    fn createFileBackend(self: *SourceResolver, source_name: []const u8, config: yaml.Yaml.Map) !SourceBackend {
        // Get file path from config
        const path_value = config.get("path") orelse return error.MissingFilePath;
        const file_path = path_value.asScalar() orelse return error.InvalidFilePath;

        const file_source = try FileSource.init(self.allocator, source_name, file_path);
        return file_source.backend();
    }

    fn createEnvBackend(self: *SourceResolver, source_name: []const u8, config: yaml.Yaml.Map) !SourceBackend {
        // Get optional prefix from config
        const prefix: ?[]const u8 = if (config.get("prefix")) |prefix_value|
            prefix_value.asScalar()
        else
            null;

        const env_source = try EnvSource.init(self.allocator, source_name, prefix);
        return env_source.backend();
    }

    fn createVaultBackend(self: *SourceResolver, source_name: []const u8, config: yaml.Yaml.Map) !SourceBackend {
        // Get optional vault_addr from config (defaults to VAULT_ADDR env var)
        const vault_addr: ?[]const u8 = if (config.get("addr")) |addr_value|
            addr_value.asScalar()
        else
            null;

        // Get optional vault_token from config (defaults to VAULT_TOKEN env var)
        const vault_token: ?[]const u8 = if (config.get("token")) |token_value|
            token_value.asScalar()
        else
            null;

        // Get mount path (e.g., "secret")
        const mount_value = config.get("mount") orelse return error.MissingVaultMount;
        const mount_path = mount_value.asScalar() orelse return error.InvalidVaultMount;

        // Get secret path (e.g., "myapp/config")
        const path_value = config.get("path") orelse return error.MissingVaultPath;
        const secret_path = path_value.asScalar() orelse return error.InvalidVaultPath;

        // Get optional KV version (defaults to 2)
        const kv_version: ?u8 = if (config.get("kv_version")) |kv_value|
            if (kv_value.asScalar()) |kv_str|
                std.fmt.parseInt(u8, kv_str, 10) catch 2
            else
                2
        else
            null;

        const vault_source = try VaultSource.init(
            self.allocator,
            source_name,
            vault_addr,
            vault_token,
            mount_path,
            secret_path,
            kv_version,
        );
        return vault_source.backend();
    }
};
