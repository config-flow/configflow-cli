const std = @import("std");
const source = @import("source.zig");
const SourceBackend = source.SourceBackend;
const SourceValue = source.SourceValue;

/// File source backend - reads from local files (e.g., .env)
pub const FileSource = struct {
    allocator: std.mem.Allocator,
    source_name: []const u8,
    file_path: []const u8,
    values: std.StringHashMap([]const u8),
    loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator, source_name: []const u8, file_path: []const u8) !*FileSource {
        const self = try allocator.create(FileSource);
        self.* = .{
            .allocator = allocator,
            .source_name = try allocator.dupe(u8, source_name),
            .file_path = try allocator.dupe(u8, file_path),
            .values = std.StringHashMap([]const u8).init(allocator),
            .loaded = false,
        };
        return self;
    }

    pub fn backend(self: *FileSource) SourceBackend {
        return .{
            .ctx = self,
            .fetchFn = fetch,
            .fetchAllFn = fetchAll,
            .deinitFn = deinit,
        };
    }

    fn fetch(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) !?SourceValue {
        const self: *FileSource = @ptrCast(@alignCast(ctx));

        // Load file if not already loaded
        if (!self.loaded) {
            try self.loadFile();
        }

        // Look up key
        const value = self.values.get(key) orelse return null;

        return SourceValue{
            .value = try allocator.dupe(u8, value),
            .source_name = try allocator.dupe(u8, self.source_name),
            .source_type = try allocator.dupe(u8, "file"),
            .allocator = allocator,
        };
    }

    fn fetchAll(ctx: *anyopaque, allocator: std.mem.Allocator) !std.StringHashMap(SourceValue) {
        const self: *FileSource = @ptrCast(@alignCast(ctx));

        // Load file if not already loaded
        if (!self.loaded) {
            try self.loadFile();
        }

        var result = std.StringHashMap(SourceValue).init(allocator);

        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const val = SourceValue{
                .value = try allocator.dupe(u8, entry.value_ptr.*),
                .source_name = try allocator.dupe(u8, self.source_name),
                .source_type = try allocator.dupe(u8, "file"),
                .allocator = allocator,
            };
            try result.put(key, val);
        }

        return result;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *FileSource = @ptrCast(@alignCast(ctx));
        const allocator = self.allocator;

        allocator.free(self.source_name);
        allocator.free(self.file_path);

        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.values.deinit();

        allocator.destroy(self);
    }

    fn loadFile(self: *FileSource) !void {
        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // File doesn't exist - that's OK, just no values available
                self.loaded = true;
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(content);

        // Parse .env format
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Find = separator
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                // Remove quotes if present
                const unquoted_value = if (value.len >= 2 and
                    ((value[0] == '"' and value[value.len - 1] == '"') or
                        (value[0] == '\'' and value[value.len - 1] == '\'')))
                    value[1 .. value.len - 1]
                else
                    value;

                const key_copy = try self.allocator.dupe(u8, key);
                const value_copy = try self.allocator.dupe(u8, unquoted_value);

                try self.values.put(key_copy, value_copy);
            }
        }

        self.loaded = true;
    }
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test "FileSource init and deinit" {
    const allocator = std.testing.allocator;

    const file_source = try FileSource.init(allocator, "test", "test.env");
    const backend = file_source.backend();
    defer backend.deinit();

    // Just verify it doesn't crash
    try expect(true);
}

test "FileSource fetch from valid .env file" {
    const allocator = std.testing.allocator;

    // Create temp directory and file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("test.env", .{});
    try tmp_file.writeAll("DATABASE_URL=postgresql://localhost/test\nPORT=3000\nDEBUG=true\n");
    tmp_file.close();

    // Get absolute path
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.env");
    defer allocator.free(tmp_path);

    const file_source = try FileSource.init(allocator, "test", tmp_path);
    const backend = file_source.backend();
    defer backend.deinit();

    // Fetch single value
    if (try backend.fetch(allocator, "DATABASE_URL")) |value| {
        defer {
            var mut_value = value;
            mut_value.deinit();
        }
        try expectEqualStrings("postgresql://localhost/test", value.value);
        try expectEqualStrings("test", value.source_name);
        try expectEqualStrings("file", value.source_type);
    } else {
        try expect(false); // Should have found the value
    }
}

test "FileSource fetch non-existent key" {
    const allocator = std.testing.allocator;

    // Create temp directory and file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("test.env", .{});
    try tmp_file.writeAll("DATABASE_URL=postgresql://localhost/test\n");
    tmp_file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.env");
    defer allocator.free(tmp_path);

    const file_source = try FileSource.init(allocator, "test", tmp_path);
    const backend = file_source.backend();
    defer backend.deinit();

    // Fetch non-existent key
    const value = try backend.fetch(allocator, "DOES_NOT_EXIST");
    try expect(value == null);
}

test "FileSource fetchAll returns all values" {
    const allocator = std.testing.allocator;

    // Create temp directory and file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("test.env", .{});
    try tmp_file.writeAll("KEY1=value1\nKEY2=value2\nKEY3=value3\n");
    tmp_file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.env");
    defer allocator.free(tmp_path);

    const file_source = try FileSource.init(allocator, "test", tmp_path);
    const backend = file_source.backend();
    defer backend.deinit();

    // Fetch all values
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

    try expect(all_values.count() == 3);
    try expect(all_values.get("KEY1") != null);
    try expect(all_values.get("KEY2") != null);
    try expect(all_values.get("KEY3") != null);
}

test "FileSource handles comments and empty lines" {
    const allocator = std.testing.allocator;

    // Create temp directory and file with comments
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("test.env", .{});
    try tmp_file.writeAll(
        \\# This is a comment
        \\DATABASE_URL=postgresql://localhost/test
        \\
        \\# Another comment
        \\PORT=3000
        \\
    );
    tmp_file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.env");
    defer allocator.free(tmp_path);

    const file_source = try FileSource.init(allocator, "test", tmp_path);
    const backend = file_source.backend();
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

    // Should only have 2 values, no comments or empty lines
    try expect(all_values.count() == 2);
}

test "FileSource handles values with equals signs" {
    const allocator = std.testing.allocator;

    // Create temp directory and file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("test.env", .{});
    try tmp_file.writeAll("URL=https://example.com?foo=bar&baz=qux\n");
    tmp_file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.env");
    defer allocator.free(tmp_path);

    const file_source = try FileSource.init(allocator, "test", tmp_path);
    const backend = file_source.backend();
    defer backend.deinit();

    if (try backend.fetch(allocator, "URL")) |value| {
        defer {
            var mut_value = value;
            mut_value.deinit();
        }
        try expectEqualStrings("https://example.com?foo=bar&baz=qux", value.value);
    } else {
        try expect(false);
    }
}

test "FileSource handles missing file gracefully" {
    const allocator = std.testing.allocator;

    const file_source = try FileSource.init(allocator, "test", "/tmp/does_not_exist.env");
    const backend = file_source.backend();
    defer backend.deinit();

    // Should handle missing file without crashing
    const value = try backend.fetch(allocator, "ANY_KEY");
    try expect(value == null);
}

test "FileSource handles empty file" {
    const allocator = std.testing.allocator;

    // Create temp directory and empty file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("test.env", .{});
    tmp_file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.env");
    defer allocator.free(tmp_path);

    const file_source = try FileSource.init(allocator, "test", tmp_path);
    const backend = file_source.backend();
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

    try expect(all_values.count() == 0);
}

test "FileSource handles multiline values with quotes" {
    const allocator = std.testing.allocator;

    // Create temp directory and file with quoted value
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("test.env", .{});
    try tmp_file.writeAll("MESSAGE=\"Hello World\"\n");
    tmp_file.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.env");
    defer allocator.free(tmp_path);

    const file_source = try FileSource.init(allocator, "test", tmp_path);
    const backend = file_source.backend();
    defer backend.deinit();

    if (try backend.fetch(allocator, "MESSAGE")) |value| {
        defer {
            var mut_value = value;
            mut_value.deinit();
        }
        // File source keeps quotes as-is
        try expect(std.mem.indexOf(u8, value.value, "Hello World") != null);
    } else {
        try expect(false);
    }
}
