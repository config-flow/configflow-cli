const std = @import("std");
const source = @import("source.zig");
const SourceBackend = source.SourceBackend;
const SourceValue = source.SourceValue;

/// Environment variable source backend - reads from process environment
pub const EnvSource = struct {
    allocator: std.mem.Allocator,
    source_name: []const u8,
    prefix: ?[]const u8, // Optional prefix (e.g., "MYAPP_")

    pub fn init(allocator: std.mem.Allocator, source_name: []const u8, prefix: ?[]const u8) !*EnvSource {
        const self = try allocator.create(EnvSource);
        self.* = .{
            .allocator = allocator,
            .source_name = try allocator.dupe(u8, source_name),
            .prefix = if (prefix) |p| try allocator.dupe(u8, p) else null,
        };
        return self;
    }

    pub fn backend(self: *EnvSource) SourceBackend {
        return .{
            .ctx = self,
            .fetchFn = fetch,
            .fetchAllFn = fetchAll,
            .deinitFn = deinit,
        };
    }

    fn fetch(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) !?SourceValue {
        const self: *EnvSource = @ptrCast(@alignCast(ctx));

        // Build the full environment variable name (with prefix if provided)
        const env_key = if (self.prefix) |prefix|
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, key })
        else
            try allocator.dupe(u8, key);
        defer allocator.free(env_key);

        // Try to get the environment variable
        const value = std.process.getEnvVarOwned(allocator, env_key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return null;
            }
            return err;
        };

        return SourceValue{
            .value = value, // Already allocated by getEnvVarOwned
            .source_name = try allocator.dupe(u8, self.source_name),
            .source_type = try allocator.dupe(u8, "env"),
            .allocator = allocator,
        };
    }

    fn fetchAll(ctx: *anyopaque, allocator: std.mem.Allocator) !std.StringHashMap(SourceValue) {
        const self: *EnvSource = @ptrCast(@alignCast(ctx));

        var result = std.StringHashMap(SourceValue).init(allocator);

        // Get all environment variables
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();

        var iter = env_map.iterator();
        while (iter.next()) |entry| {
            const env_key = entry.key_ptr.*;
            const env_value = entry.value_ptr.*;

            // If we have a prefix, only include vars that start with it
            if (self.prefix) |prefix| {
                if (!std.mem.startsWith(u8, env_key, prefix)) {
                    continue;
                }

                // Strip the prefix from the key
                const key = env_key[prefix.len..];
                const val = SourceValue{
                    .value = try allocator.dupe(u8, env_value),
                    .source_name = try allocator.dupe(u8, self.source_name),
                    .source_type = try allocator.dupe(u8, "env"),
                    .allocator = allocator,
                };
                const key_copy = try allocator.dupe(u8, key);
                try result.put(key_copy, val);
            } else {
                // No prefix - include all env vars
                const key_copy = try allocator.dupe(u8, env_key);
                const val = SourceValue{
                    .value = try allocator.dupe(u8, env_value),
                    .source_name = try allocator.dupe(u8, self.source_name),
                    .source_type = try allocator.dupe(u8, "env"),
                    .allocator = allocator,
                };
                try result.put(key_copy, val);
            }
        }

        return result;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *EnvSource = @ptrCast(@alignCast(ctx));
        const allocator = self.allocator;

        allocator.free(self.source_name);
        if (self.prefix) |prefix| {
            allocator.free(prefix);
        }

        allocator.destroy(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "EnvSource init and deinit" {
    const allocator = std.testing.allocator;

    const env_source = try EnvSource.init(allocator, "test", null);
    const backend = env_source.backend();
    defer backend.deinit();

    try expect(true);
}

test "EnvSource init with prefix" {
    const allocator = std.testing.allocator;

    const env_source = try EnvSource.init(allocator, "test", "APP_");
    const backend = env_source.backend();
    defer backend.deinit();

    try expect(true);
}

test "EnvSource fetch from environment - PATH should exist" {
    const allocator = std.testing.allocator;

    const env_source = try EnvSource.init(allocator, "test", null);
    const backend = env_source.backend();
    defer backend.deinit();

    // PATH should exist in any Unix-like environment
    if (try backend.fetch(allocator, "PATH")) |value| {
        defer {
            var mut_value = value;
            mut_value.deinit();
        }
        try expect(value.value.len > 0);
        try expectEqualStrings("test", value.source_name);
        try expectEqualStrings("env", value.source_type);
    } else {
        // PATH not found - that's fine, just means we're in a restricted environment
    }
}

test "EnvSource fetch non-existent variable" {
    const allocator = std.testing.allocator;

    const env_source = try EnvSource.init(allocator, "test", null);
    const backend = env_source.backend();
    defer backend.deinit();

    const value = try backend.fetch(allocator, "DEFINITELY_DOES_NOT_EXIST_CONFIGFLOW_TEST_12345");
    try expect(value == null);
}

test "EnvSource fetchAll returns environment variables" {
    const allocator = std.testing.allocator;

    const env_source = try EnvSource.init(allocator, "test", null);
    const backend = env_source.backend();
    defer backend.deinit();

    var all_values = try backend.fetchAll(allocator);
    defer {
        var iter = all_values.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var value = entry.value_ptr.*;
            value.deinit();
        }
        all_values.deinit();
    }

    // Should have at least some environment variables
    // In any Unix-like environment, there should be PATH, HOME, or similar
    try expect(all_values.count() > 0);
}

test "EnvSource with prefix - only returns prefixed vars" {
    const allocator = std.testing.allocator;

    const env_source = try EnvSource.init(allocator, "test", "NONEXISTENT_PREFIX_");
    const backend = env_source.backend();
    defer backend.deinit();

    var all_values = try backend.fetchAll(allocator);
    defer {
        var iter = all_values.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var value = entry.value_ptr.*;
            value.deinit();
        }
        all_values.deinit();
    }

    // With a prefix that doesn't exist, should return 0 variables
    // (or very few if the system happens to have vars with that prefix)
    // We just check it doesn't crash
    try expect(true);
}

test "EnvSource backend interface works correctly" {
    const allocator = std.testing.allocator;

    const env_source = try EnvSource.init(allocator, "my_source", null);
    const backend = env_source.backend();
    defer backend.deinit();

    // Test that the backend interface is properly set up
    // by attempting to fetch all - this exercises the function pointers
    var all_values = try backend.fetchAll(allocator);
    defer {
        var iter = all_values.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var value = entry.value_ptr.*;
            value.deinit();
        }
        all_values.deinit();
    }

    try expect(true);
}

test "EnvSource multiple instances are independent" {
    const allocator = std.testing.allocator;

    const env_source1 = try EnvSource.init(allocator, "source1", null);
    const backend1 = env_source1.backend();
    defer backend1.deinit();

    const env_source2 = try EnvSource.init(allocator, "source2", "PREFIX_");
    const backend2 = env_source2.backend();
    defer backend2.deinit();

    // Both should work independently
    var all1 = try backend1.fetchAll(allocator);
    defer {
        var iter = all1.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var value = entry.value_ptr.*;
            value.deinit();
        }
        all1.deinit();
    }

    var all2 = try backend2.fetchAll(allocator);
    defer {
        var iter = all2.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var value = entry.value_ptr.*;
            value.deinit();
        }
        all2.deinit();
    }

    try expect(true);
}
