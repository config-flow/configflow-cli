const std = @import("std");
const zcli = @import("zcli");
const yaml = @import("yaml");

pub const meta = .{
    .description = "List all configured variables",
    .examples = &.{
        "configflow ls",
        "configflow ls --verbose",
    },
    .options = .{
        .verbose = .{ .description = "Show detailed information", .short = 'v' },
    },
};

pub const Args = struct {};

pub const Options = struct {
    verbose: bool = false,
};

pub fn execute(_: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout();
    const stderr = context.stderr();

    // Check if .configflow directory exists
    if (!checkDirExists(".configflow")) {
        try stderr.print("Error: .configflow directory not found.\n", .{});
        try stderr.print("Run 'configflow init' first to initialize ConfigFlow.\n", .{});
        return error.NotInitialized;
    }

    // Check if schema.yml exists
    if (!checkFileExists(".configflow/schema.yml")) {
        try stderr.print("Error: schema.yml not found.\n", .{});
        try stderr.print("Run 'configflow init' first to initialize ConfigFlow.\n", .{});
        return error.SchemaNotFound;
    }

    // Read and parse schema.yml
    const schema_content = readFile(allocator, ".configflow/schema.yml") catch |err| {
        try stderr.print("Error reading schema.yml: {}\n", .{err});
        return err;
    };
    defer allocator.free(schema_content);

    // Parse YAML
    var parsed = yaml.Yaml{
        .source = schema_content,
    };
    defer parsed.deinit(allocator);

    parsed.load(allocator) catch |err| {
        try stderr.print("Error parsing schema.yml: {}\n", .{err});
        return err;
    };

    // Get root document
    const docs = parsed.docs.items;
    if (docs.len == 0) {
        try stderr.print("Error: schema.yml is empty\n", .{});
        return error.EmptySchema;
    }

    const root = docs[0];
    const root_map = root.asMap() orelse {
        try stderr.print("Error: schema.yml root must be a map\n", .{});
        return error.InvalidSchema;
    };

    // Get config section
    const config_value = root_map.get("config") orelse {
        try stderr.print("Error: schema.yml missing 'config' section\n", .{});
        return error.MissingConfig;
    };

    const config_map = config_value.asMap() orelse {
        try stderr.print("Error: 'config' must be a map\n", .{});
        return error.InvalidConfig;
    };

    // Count entries
    const count = config_map.count();

    if (count == 0) {
        try stdout.print("No configuration variables defined.\n", .{});
        return;
    }

    try stdout.print("Configuration variables ({}):\n\n", .{count});

    // List all entries
    var iter = config_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        try printConfigEntry(key, value, options.verbose, stdout);
    }
}

fn printConfigEntry(key: []const u8, entry: yaml.Yaml.Value, verbose: bool, stdout: anytype) !void {
    const entry_map = entry.asMap() orelse {
        // Skip invalid entries
        return;
    };

    // Get type
    const type_str = if (entry_map.get("type")) |type_val|
        type_val.asScalar() orelse "unknown"
    else
        "unknown";

    // Get required status
    const required = if (entry_map.get("required")) |req_val| blk: {
        if (req_val.asScalar()) |s| {
            break :blk std.mem.eql(u8, s, "true");
        }
        break :blk false;
    } else false;

    // Basic output: key [type] (required?)
    if (verbose) {
        try stdout.print("  {s}\n", .{key});
        try stdout.print("    Type: {s}\n", .{type_str});
        try stdout.print("    Required: {s}\n", .{if (required) "yes" else "no"});

        // Get description if present
        if (entry_map.get("description")) |desc_val| {
            if (desc_val.asScalar()) |desc| {
                try stdout.print("    Description: {s}\n", .{desc});
            }
        }

        // Show sources if present
        if (entry_map.get("sources")) |sources_val| {
            if (sources_val.asMap()) |sources_map| {
                try stdout.print("    Sources:\n", .{});
                var src_iter = sources_map.iterator();
                while (src_iter.next()) |src_entry| {
                    const env = src_entry.key_ptr.*;
                    const src = src_entry.value_ptr.*;

                    if (src.asScalar()) |s| {
                        if (std.mem.eql(u8, s, "null")) {
                            try stdout.print("      {s}: <not configured>\n", .{env});
                        } else {
                            try stdout.print("      {s}: {s}\n", .{ env, s });
                        }
                    }
                }
            }
        }

        try stdout.print("\n", .{});
    } else {
        // Compact output
        const req_marker = if (required) "*" else " ";
        try stdout.print("  {s} {s} ({s})\n", .{ req_marker, key, type_str });
    }
}

fn checkDirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn checkFileExists(path: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const contents = try file.readToEndAlloc(allocator, stat.size);
    return contents;
}
