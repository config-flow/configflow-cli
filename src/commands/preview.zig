const std = @import("std");
const zcli = @import("zcli");
const yaml = @import("yaml");
const sources = @import("sources");
const validation = @import("validation");

const SourceResolver = sources.SourceResolver;

pub const meta = .{
    .description = "Preview configuration values for a specific context",
    .examples = &.{
        "configflow preview",
        "configflow preview --context prod",
        "configflow preview --context staging --show-secrets",
    },
    .options = .{
        .context = .{ .description = "Context to preview (default: local)", .short = 'c' },
        .show_secrets = .{ .description = "Show unredacted secret values", .short = 's' },
    },
};

pub const Args = struct {};

pub const Options = struct {
    context: ?[]const u8 = null,
    show_secrets: bool = false,
};

pub fn execute(_: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout();
    const stderr = context.stderr();

    const ctx = options.context orelse "local";

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

    try stdout.print("Configuration preview for context '{s}':\n\n", .{ctx});

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

    // Get sources section
    const sources_value = root_map.get("sources");

    // Initialize source resolver
    var resolver = SourceResolver.init(allocator);
    defer resolver.deinit();

    if (sources_value) |sources_section| {
        try resolver.parseAndRegisterSources(sources_section);
    }

    // Get context's default source
    const contexts_value = root_map.get("contexts");
    var default_source: ?[]const u8 = null;

    if (contexts_value) |contexts_section| {
        if (contexts_section.asMap()) |ctx_map| {
            if (ctx_map.get(ctx)) |ctx_config| {
                if (ctx_config.asMap()) |cfg| {
                    if (cfg.get("default_source")) |src_value| {
                        default_source = src_value.asScalar();
                    }
                }
            }
        }
    }

    // Track statistics
    var total_fields: usize = 0;
    var valid_fields: usize = 0;
    var invalid_fields: usize = 0;
    var missing_required: usize = 0;
    var warnings: usize = 0;

    // Process each field
    for (fields) |field| {
        total_fields += 1;

        // Resolve value (precedence: env var -> source -> default)
        var value: ?[]const u8 = null;
        var value_source: []const u8 = "not set";
        var value_allocated = false;

        // Check environment variable
        if (std.process.getEnvVarOwned(allocator, field.name)) |env_value| {
            value = env_value;
            value_source = "environment";
            value_allocated = true;
        } else |_| {
            // Check configured source
            if (default_source) |src| {
                if (resolver.getSource(src)) |backend| {
                    if (try backend.fetch(allocator, field.name)) |source_value| {
                        defer {
                            var mut_val = source_value;
                            mut_val.deinit();
                        }
                        value = try allocator.dupe(u8, source_value.value);
                        value_source = src;
                        value_allocated = true;
                    }
                }
            }

            // Check default value
            if (value == null and field.default != null) {
                value = field.default.?;
                value_source = "default";
                value_allocated = false;
            }
        }

        defer {
            if (value_allocated and value != null) {
                allocator.free(value.?);
            }
        }

        // Display field info
        try stdout.print("{s}:\n", .{field.name});

        if (value) |v| {
            // Display value (redact secrets if needed)
            const display_value = if (field.field_type == .secret and !options.show_secrets)
                try redactValue(allocator, v)
            else
                try allocator.dupe(u8, v);
            defer allocator.free(display_value);

            try stdout.print("  Value: {s}\n", .{display_value});
            try stdout.print("  Source: {s}\n", .{value_source});
            try stdout.print("  Type: {s}\n", .{field.field_type.toString()});

            // Validate the value
            const result = try validation.validateField(allocator, field, v, ctx);
            defer result.deinit(allocator);

            if (result.success) {
                try stdout.print("  Status: ✓ valid\n", .{});
                valid_fields += 1;
            } else {
                try stdout.print("  Status: ❌ invalid\n", .{});
                if (result.error_message) |err_msg| {
                    try stdout.print("  Error: {s}\n", .{err_msg});
                }
                invalid_fields += 1;
            }

            // Check for warnings
            if (!std.mem.eql(u8, ctx, "local")) {
                if (std.mem.indexOf(u8, v, "localhost") != null or
                    std.mem.indexOf(u8, v, "127.0.0.1") != null)
                {
                    try stdout.print("  ⚠️  Warning: contains localhost in '{s}' context\n", .{ctx});
                    warnings += 1;
                }

                if (field.field_type == .secret and std.mem.indexOf(u8, v, "test") != null) {
                    try stdout.print("  ⚠️  Warning: secret contains 'test' in '{s}' context\n", .{ctx});
                    warnings += 1;
                }
            }
        } else {
            try stdout.print("  Value: (not set)\n", .{});
            try stdout.print("  Type: {s}\n", .{field.field_type.toString()});

            if (validation.isRequired(field, ctx)) {
                try stdout.print("  Status: ❌ REQUIRED but missing\n", .{});
                missing_required += 1;
                invalid_fields += 1;
            } else {
                try stdout.print("  Status: ⚠️  optional, not set\n", .{});
            }
        }

        try stdout.print("\n", .{});
    }

    // Print summary
    try stdout.print("─────────────────────────────────────\n", .{});
    try stdout.print("Summary:\n", .{});
    try stdout.print("  Total fields: {d}\n", .{total_fields});
    try stdout.print("  Valid: {d}\n", .{valid_fields});
    try stdout.print("  Invalid: {d}\n", .{invalid_fields});
    if (missing_required > 0) {
        try stdout.print("  Missing required: {d}\n", .{missing_required});
    }
    if (warnings > 0) {
        try stdout.print("  Warnings: {d}\n", .{warnings});
    }
    try stdout.print("\n", .{});

    if (invalid_fields > 0) {
        try stdout.print("❌ Configuration has errors - cannot be used\n", .{});
    } else if (warnings > 0) {
        try stdout.print("⚠️  Configuration is valid but has warnings\n", .{});
    } else {
        try stdout.print("✓ Configuration is valid and ready to use\n", .{});
    }
}

fn redactValue(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len <= 8) {
        return try allocator.dupe(u8, "***");
    }

    // Show first 4 and last 4 characters
    return try std.fmt.allocPrint(allocator, "{s}***{s}", .{ value[0..4], value[value.len - 4 ..] });
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
