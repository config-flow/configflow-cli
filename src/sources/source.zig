const std = @import("std");

/// Value fetched from a source with metadata
pub const SourceValue = struct {
    value: []const u8,
    source_name: []const u8, // e.g., "local", "staging", "prod"
    source_type: []const u8, // e.g., "file", "env", "vault"
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SourceValue) void {
        self.allocator.free(self.value);
        self.allocator.free(self.source_name);
        self.allocator.free(self.source_type);
    }
};

/// Source backend interface - all source types implement this
pub const SourceBackend = struct {
    const FetchFn = *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) anyerror!?SourceValue;

    const FetchAllFn = *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror!std.StringHashMap(SourceValue);

    const DeinitFn = *const fn (ctx: *anyopaque) void;

    ctx: *anyopaque,
    fetchFn: FetchFn,
    fetchAllFn: FetchAllFn,
    deinitFn: DeinitFn,

    /// Fetch a single value by key
    pub fn fetch(self: SourceBackend, allocator: std.mem.Allocator, key: []const u8) !?SourceValue {
        return self.fetchFn(self.ctx, allocator, key);
    }

    /// Fetch all values (useful for sync)
    pub fn fetchAll(self: SourceBackend, allocator: std.mem.Allocator) !std.StringHashMap(SourceValue) {
        return self.fetchAllFn(self.ctx, allocator);
    }

    /// Clean up backend resources
    pub fn deinit(self: SourceBackend) void {
        self.deinitFn(self.ctx);
    }
};

/// Source configuration parsed from schema.yml
pub const SourceConfig = struct {
    type: []const u8, // "file", "env", "vault", "aws", etc.
    config: std.StringHashMap([]const u8), // type-specific config

    pub fn deinit(self: *SourceConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.type);
        var iter = self.config.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.config.deinit();
    }
};
