const std = @import("std");
const zcli = @import("zcli");
const yaml = @import("yaml");
const sources = @import("sources");
const validation = @import("validation");

const SourceResolver = sources.SourceResolver;

pub const meta = .{
    .description = "Set a configuration value",
    .examples = &.{
        "configflow set DATABASE_URL=postgresql://localhost/mydb",
        "configflow set DEBUG=true --context staging",
        "configflow set API_KEY=sk_live_xyz --context prod",
    },
    .options = .{
        .context = .{ .description = "Context to set value for (default: local)", .short = 'c' },
    },
};

pub const Args = struct {
    assignment: []const u8,
};

pub const Options = struct {
    context: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout();
    const stderr = context.stderr();

    const ctx = options.context orelse "local";

    // Parse KEY=VALUE
    const assignment = args.assignment;
    const equals_pos = std.mem.indexOf(u8, assignment, "=") orelse {
        try stderr.print("❌ Error: Invalid format. Expected KEY=VALUE\n", .{});
        try stderr.print("   Example: configflow set DATABASE_URL=postgresql://localhost/mydb\n\n", .{});
        return error.InvalidFormat;
    };

    const key = assignment[0..equals_pos];
    const value = assignment[equals_pos + 1 ..];

    if (key.len == 0) {
        try stderr.print("❌ Error: Key cannot be empty\n", .{});
        return error.EmptyKey;
    }

    // Check if .configflow directory exists
    if (!checkDirExists(".configflow")) {
        try stderr.print("❌ Error: .configflow directory not found.\n", .{});
        try stderr.print("   Run 'configflow init' first to initialize ConfigFlow.\n\n", .{});
        return error.NotInitialized;
    }

    // Check if schema.yml exists
    if (!checkFileExists(".configflow/schema.yml")) {
        try stderr.print("❌ Error: schema.yml not found\n", .{});
        return error.SchemaNotFound;
    }

    // Read and parse schema.yml
    const schema_content = readFile(allocator, ".configflow/schema.yml") catch |err| {
        try stderr.print("❌ Error reading schema.yml: {}\n", .{err});
        return err;
    };
    defer allocator.free(schema_content);

    // Parse YAML
    var parsed = yaml.Yaml{
        .source = schema_content,
    };
    defer parsed.deinit(allocator);

    parsed.load(allocator) catch |err| {
        try stderr.print("❌ Error parsing schema.yml: {}\n", .{err});
        return err;
    };

    // Get root document
    const docs = parsed.docs.items;
    if (docs.len == 0) {
        try stderr.print("❌ Error: schema.yml is empty\n", .{});
        return error.EmptySchema;
    }

    const root = docs[0];
    const root_map = root.asMap() orelse {
        try stderr.print("❌ Error: schema.yml root must be a map\n", .{});
        return error.InvalidSchema;
    };

    // Parse schema into Field objects
    const fields = validation.parseSchema(allocator, &parsed) catch |err| {
        try stderr.print("❌ Error parsing schema: {}\n", .{err});
        return err;
    };
    defer validation.freeSchema(allocator, fields);

    // Find the field
    var target_field: ?validation.Field = null;
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            target_field = field;
            break;
        }
    }

    if (target_field == null) {
        try stderr.print("❌ Error: Key '{s}' not found in schema\n", .{key});
        try stderr.print("   Run 'configflow ls' to see available keys\n\n", .{});
        return error.KeyNotFound;
    }

    const field = target_field.?;

    // Validate the value
    const result = try validation.validateField(allocator, field, value, ctx);
    defer result.deinit(allocator);

    if (!result.success) {
        try stderr.print("❌ Error: Invalid value for {s}\n", .{key});
        if (result.error_message) |err_msg| {
            try stderr.print("   {s}\n", .{err_msg});
        }
        try stderr.print("\n   Expected type: {s}\n", .{field.field_type.toString()});
        return error.InvalidValue;
    }

    // Get sources section to find the target file
    const sources_value = root_map.get("sources");
    const contexts_value = root_map.get("contexts");

    // Find the source file for this context
    var target_file: ?[]const u8 = null;

    if (contexts_value) |contexts_section| {
        if (contexts_section.asMap()) |ctx_map| {
            if (ctx_map.get(ctx)) |ctx_config| {
                if (ctx_config.asMap()) |cfg| {
                    if (cfg.get("default_source")) |src_name_value| {
                        const src_name = src_name_value.asScalar();
                        if (src_name) |sn| {
                            // Look up the source in sources section
                            if (sources_value) |sources_section| {
                                if (sources_section.asMap()) |sources_map| {
                                    if (sources_map.get(sn)) |source_config| {
                                        if (source_config.asMap()) |sc| {
                                            if (sc.get("type")) |type_val| {
                                                const source_type = type_val.asScalar();
                                                if (source_type != null and std.mem.eql(u8, source_type.?, "file")) {
                                                    if (sc.get("path")) |path_val| {
                                                        target_file = path_val.asScalar();
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (target_file == null) {
        try stderr.print("❌ Error: Context '{s}' does not have a file-based source configured\n", .{ctx});
        try stderr.print("   Only file sources are supported for 'set' command in V1\n\n", .{});
        return error.NoFileSource;
    }

    // Update the file
    try updateEnvFile(allocator, target_file.?, key, value);

    try stdout.print("✓ Set {s}={s} in context '{s}'\n", .{ key, value, ctx });
    try stdout.print("  File: {s}\n\n", .{target_file.?});

    // Warn if it's a secret
    if (field.field_type == .secret) {
        try stdout.print("⚠️  Note: This is a secret field. Consider using a secure backend like Vault for production.\n", .{});
    }
}

fn updateEnvFile(allocator: std.mem.Allocator, file_path: []const u8, key: []const u8, value: []const u8) !void {
    // Read existing file content if it exists
    const existing_content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            // File doesn't exist, create it with just this key=value
            const new_line = try std.fmt.allocPrint(allocator, "{s}={s}\n", .{ key, value });
            defer allocator.free(new_line);
            const output_file = try std.fs.cwd().createFile(file_path, .{});
            defer output_file.close();
            try output_file.writeAll(new_line);
            return;
        } else {
            return err;
        }
    };
    defer allocator.free(existing_content);

    // Build new content
    var new_content = try std.ArrayList(u8).initCapacity(allocator, existing_content.len + 100);
    defer new_content.deinit(allocator);

    var lines = std.mem.splitScalar(u8, existing_content, '\n');
    var key_found = false;

    while (lines.next()) |line| {
        // Check if this line contains our key
        if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
            const line_key = std.mem.trim(u8, line[0..eq_pos], " \t");
            if (std.mem.eql(u8, line_key, key)) {
                // Update this line
                const updated_line = try std.fmt.allocPrint(allocator, "{s}={s}\n", .{ key, value });
                defer allocator.free(updated_line);
                try new_content.appendSlice(allocator, updated_line);
                key_found = true;
                continue;
            }
        }

        // Keep the line as-is (including comments and empty lines)
        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');
    }

    // If key wasn't found, append it
    if (!key_found) {
        const new_line = try std.fmt.allocPrint(allocator, "{s}={s}\n", .{ key, value });
        defer allocator.free(new_line);
        try new_content.appendSlice(allocator, new_line);
    }

    // Remove trailing newline if the original didn't have one
    if (existing_content.len > 0 and existing_content[existing_content.len - 1] != '\n') {
        if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] == '\n') {
            new_content.items.len -= 1;
        }
    }

    // Write back to file
    const output_file = try std.fs.cwd().createFile(file_path, .{});
    defer output_file.close();

    try output_file.writeAll(new_content.items);
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
