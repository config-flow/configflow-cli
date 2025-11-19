const std = @import("std");

/// File extension patterns to match
pub const FilePattern = struct {
    extensions: []const []const u8,
};

/// Options for file system scanning
pub const ScanOptions = struct {
    /// Extensions to include (e.g., &.{".js", ".jsx", ".ts"})
    extensions: []const []const u8,
    /// Directory names to ignore
    ignore_dirs: []const []const u8 = &.{
        "node_modules",
        ".git",
        "dist",
        "build",
        "zig-cache",
        "zig-out",
        ".next",
        "__pycache__",
        "venv",
        ".venv",
        "vendor",
        "target",
        // Test directories
        "test",
        "tests",
        "__tests__",
        "spec",
        "specs",
        "e2e",
        "integration",
        "fixtures",
    },
    /// Follow symbolic links (default: false for safety)
    follow_symlinks: bool = false,
    /// Maximum directory depth (0 = unlimited)
    max_depth: usize = 0,
};

/// Scanner for discovering source files in a directory tree
pub const Scanner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Scanner {
        return .{ .allocator = allocator };
    }

    /// Scan directory tree and return list of matching file paths
    /// Caller owns returned slice and all strings within it
    pub fn scan(
        self: Scanner,
        root_path: []const u8,
        options: ScanOptions,
        progress_node: std.Progress.Node,
    ) ![][]const u8 {
        var files = std.ArrayList([]const u8){};
        errdefer {
            for (files.items) |file| {
                self.allocator.free(file);
            }
            files.deinit(self.allocator);
        }

        try self.scanRecursive(root_path, options, &files, 0, progress_node);

        return files.toOwnedSlice(self.allocator);
    }

    fn scanRecursive(
        self: Scanner,
        dir_path: []const u8,
        options: ScanOptions,
        files: *std.ArrayList([]const u8),
        current_depth: usize,
        progress_node: std.Progress.Node,
    ) !void {
        // Check max depth
        if (options.max_depth > 0 and current_depth >= options.max_depth) {
            return;
        }

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            // Skip directories we can't open (permission errors, etc.)
            if (err == error.AccessDenied or err == error.FileNotFound) {
                return;
            }
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    // Check if directory should be ignored
                    if (shouldIgnoreDir(entry.name, options.ignore_dirs)) {
                        continue;
                    }

                    // Build subdirectory path
                    const subdir_path = try std.fs.path.join(
                        self.allocator,
                        &.{ dir_path, entry.name },
                    );
                    defer self.allocator.free(subdir_path);

                    // Recurse into subdirectory
                    try self.scanRecursive(subdir_path, options, files, current_depth + 1, progress_node);
                },
                .file => {
                    // Check if file extension matches
                    if (hasMatchingExtension(entry.name, options.extensions)) {
                        const file_path = try std.fs.path.join(
                            self.allocator,
                            &.{ dir_path, entry.name },
                        );
                        try files.append(self.allocator, file_path);
                        progress_node.completeOne();
                    }
                },
                .sym_link => {
                    if (options.follow_symlinks) {
                        // Get real path of symlink
                        const link_path = try std.fs.path.join(
                            self.allocator,
                            &.{ dir_path, entry.name },
                        );
                        defer self.allocator.free(link_path);

                        // Check if it's a directory or file
                        const stat = dir.statFile(entry.name) catch continue;
                        switch (stat.kind) {
                            .directory => {
                                if (!shouldIgnoreDir(entry.name, options.ignore_dirs)) {
                                    try self.scanRecursive(link_path, options, files, current_depth + 1, progress_node);
                                }
                            },
                            .file => {
                                if (hasMatchingExtension(entry.name, options.extensions)) {
                                    const file_path = try self.allocator.dupe(u8, link_path);
                                    try files.append(self.allocator, file_path);
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {}, // Skip other file types (pipes, sockets, etc.)
            }
        }
    }
};

/// Check if directory name should be ignored
fn shouldIgnoreDir(dir_name: []const u8, ignore_dirs: []const []const u8) bool {
    for (ignore_dirs) |ignore| {
        if (std.mem.eql(u8, dir_name, ignore)) {
            return true;
        }
    }
    return false;
}

/// Check if filename has a matching extension
fn hasMatchingExtension(filename: []const u8, extensions: []const []const u8) bool {
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, filename, ext)) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "shouldIgnoreDir identifies ignored directories" {
    const ignore_dirs = &.{ "node_modules", ".git", "dist" };

    try expect(shouldIgnoreDir("node_modules", ignore_dirs));
    try expect(shouldIgnoreDir(".git", ignore_dirs));
    try expect(shouldIgnoreDir("dist", ignore_dirs));
    try expect(!shouldIgnoreDir("src", ignore_dirs));
    try expect(!shouldIgnoreDir("lib", ignore_dirs));
}

test "hasMatchingExtension identifies valid extensions" {
    const extensions = &.{ ".js", ".ts", ".jsx" };

    try expect(hasMatchingExtension("server.js", extensions));
    try expect(hasMatchingExtension("app.ts", extensions));
    try expect(hasMatchingExtension("component.jsx", extensions));
    try expect(!hasMatchingExtension("readme.md", extensions));
    try expect(!hasMatchingExtension("config.json", extensions));
}

test "Scanner scan finds JavaScript files" {
    const allocator = std.testing.allocator;
    const scanner = Scanner.init(allocator);

    // Create temporary test directory structure
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    try tmp_dir.dir.writeFile(.{ .sub_path = "app.js", .data = "console.log('test');" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "server.ts", .data = "const x = 1;" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "readme.md", .data = "# Test" });

    // Create subdirectory with more files
    try tmp_dir.dir.makeDir("src");
    try tmp_dir.dir.writeFile(.{ .sub_path = "src/index.js", .data = "export {};" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "src/config.json", .data = "{}" });

    // Create ignored directory
    try tmp_dir.dir.makeDir("node_modules");
    try tmp_dir.dir.writeFile(.{ .sub_path = "node_modules/lib.js", .data = "module.exports = {};" });

    // Get real path of temp directory
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Scan for JavaScript/TypeScript files
    const options = ScanOptions{
        .extensions = &.{ ".js", ".ts" },
    };

    const files = try scanner.scan(tmp_path, options, std.Progress.Node.none);
    defer {
        for (files) |file| {
            allocator.free(file);
        }
        allocator.free(files);
    }

    // Should find 3 files (app.js, server.ts, src/index.js)
    // Should NOT find readme.md, config.json, or node_modules/lib.js
    try expectEqual(@as(usize, 3), files.len);

    // Verify at least one file has correct extension
    var found_js = false;
    var found_ts = false;
    for (files) |file| {
        if (std.mem.endsWith(u8, file, ".js")) found_js = true;
        if (std.mem.endsWith(u8, file, ".ts")) found_ts = true;
    }
    try expect(found_js);
    try expect(found_ts);
}

test "Scanner respects max_depth option" {
    const allocator = std.testing.allocator;
    const scanner = Scanner.init(allocator);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create nested directory structure: root/a/b/c/file.js
    try tmp_dir.dir.writeFile(.{ .sub_path = "root.js", .data = "" });
    try tmp_dir.dir.makeDir("a");
    try tmp_dir.dir.writeFile(.{ .sub_path = "a/level1.js", .data = "" });
    try tmp_dir.dir.makeDir("a/b");
    try tmp_dir.dir.writeFile(.{ .sub_path = "a/b/level2.js", .data = "" });
    try tmp_dir.dir.makeDir("a/b/c");
    try tmp_dir.dir.writeFile(.{ .sub_path = "a/b/c/level3.js", .data = "" });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Scan with max_depth = 2
    const options = ScanOptions{
        .extensions = &.{".js"},
        .max_depth = 2,
    };

    const files = try scanner.scan(tmp_path, options, std.Progress.Node.none);
    defer {
        for (files) |file| {
            allocator.free(file);
        }
        allocator.free(files);
    }

    // Should find 2 files (root.js, a/level1.js)
    // Should NOT find a/b/level2.js or a/b/c/level3.js
    try expectEqual(@as(usize, 2), files.len);
}

test "Scanner handles empty directory" {
    const allocator = std.testing.allocator;
    const scanner = Scanner.init(allocator);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const options = ScanOptions{
        .extensions = &.{".js"},
    };

    const files = try scanner.scan(tmp_path, options, std.Progress.Node.none);
    defer allocator.free(files);

    try expectEqual(@as(usize, 0), files.len);
}

test "Scanner handles multiple ignore patterns" {
    const allocator = std.testing.allocator;
    const scanner = Scanner.init(allocator);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files in ignored directories
    try tmp_dir.dir.makeDir("node_modules");
    try tmp_dir.dir.writeFile(.{ .sub_path = "node_modules/lib.js", .data = "" });
    try tmp_dir.dir.makeDir(".git");
    try tmp_dir.dir.writeFile(.{ .sub_path = ".git/config.js", .data = "" });
    try tmp_dir.dir.makeDir("dist");
    try tmp_dir.dir.writeFile(.{ .sub_path = "dist/bundle.js", .data = "" });

    // Create file in non-ignored directory
    try tmp_dir.dir.makeDir("src");
    try tmp_dir.dir.writeFile(.{ .sub_path = "src/app.js", .data = "" });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const options = ScanOptions{
        .extensions = &.{".js"},
    };

    const files = try scanner.scan(tmp_path, options, std.Progress.Node.none);
    defer {
        for (files) |file| {
            allocator.free(file);
        }
        allocator.free(files);
    }

    // Should find only src/app.js
    try expectEqual(@as(usize, 1), files.len);
}
