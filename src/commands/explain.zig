const std = @import("std");
const zcli = @import("zcli");
const yaml = @import("yaml");
const sources = @import("sources");
const validation = @import("validation");

const SourceResolver = sources.SourceResolver;

pub const meta = .{
    .description = "Explain where a configuration value comes from and why",
    .examples = &.{
        "configflow explain DATABASE_URL",
        "configflow explain API_KEY --context prod",
        "configflow explain PORT --verbose",
    },
    .options = .{
        .context = .{ .description = "Context to explain (default: local)", .short = 'c' },
        .verbose = .{ .description = "Show detailed resolution path", .short = 'v' },
    },
};

pub const Args = struct {
    key: []const u8,
};

pub const Options = struct {
    context: ?[]const u8 = null,
    verbose: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
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

    try stdout.print("Explaining {s} in context '{s}':\n\n", .{ args.key, ctx });

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
        if (std.mem.eql(u8, field.name, args.key)) {
            target_field = field;
            break;
        }
    }

    if (target_field == null) {
        try stderr.print("❌ Error: Key '{s}' not found in schema\n", .{args.key});
        return error.KeyNotFound;
    }

    const field = target_field.?;

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

    // Resolution path
    var resolution_steps = try std.ArrayList(ResolutionStep).initCapacity(allocator, 0);
    defer {
        for (resolution_steps.items) |step| {
            if (step.source_allocated) allocator.free(step.source);
            if (step.value) |v| allocator.free(v);
        }
        resolution_steps.deinit(allocator);
    }

    // Check environment variable
    if (std.process.getEnvVarOwned(allocator, args.key)) |env_value| {
        try resolution_steps.append(allocator, ResolutionStep{
            .source = "environment variable",
            .source_allocated = false,
            .found = true,
            .value = env_value,
        });
    } else |_| {
        try resolution_steps.append(allocator, ResolutionStep{
            .source = "environment variable",
            .source_allocated = false,
            .found = false,
            .value = null,
        });
    }

    // Check configured source
    if (default_source) |src| {
        if (resolver.getSource(src)) |backend| {
            if (try backend.fetch(allocator, args.key)) |source_value| {
                defer {
                    var mut_val = source_value;
                    mut_val.deinit();
                }
                try resolution_steps.append(allocator, ResolutionStep{
                    .source = try std.fmt.allocPrint(allocator, "source '{s}'", .{src}),
                    .source_allocated = true,
                    .found = true,
                    .value = try allocator.dupe(u8, source_value.value),
                });
            } else {
                try resolution_steps.append(allocator, ResolutionStep{
                    .source = try std.fmt.allocPrint(allocator, "source '{s}'", .{src}),
                    .source_allocated = true,
                    .found = false,
                    .value = null,
                });
            }
        }
    }

    // Check for default value
    if (field.default) |default_val| {
        try resolution_steps.append(allocator, ResolutionStep{
            .source = "default value",
            .source_allocated = false,
            .found = true,
            .value = try allocator.dupe(u8, default_val),
        });
    }

    // Display results
    var final_value: ?[]const u8 = null;
    var final_source: []const u8 = "not set";

    // Find the first found value (precedence order)
    for (resolution_steps.items) |step| {
        if (step.found) {
            final_value = step.value;
            final_source = step.source;
            break;
        }
    }

    if (final_value) |value| {
        const display_value = if (field.field_type == .secret)
            try redactValue(allocator, value)
        else
            try allocator.dupe(u8, value);
        defer allocator.free(display_value);

        try stdout.print("✓ Current value: {s}\n", .{display_value});
        try stdout.print("  Source: {s}\n", .{final_source});
        try stdout.print("  Type: {s}\n", .{field.field_type.toString()});

        // Validate the value
        const result = try validation.validateField(allocator, field, value, ctx);
        defer result.deinit(allocator);

        if (result.success) {
            try stdout.print("  Valid: ✓\n\n", .{});
        } else {
            try stdout.print("  Valid: ❌\n", .{});
            if (result.error_message) |err_msg| {
                try stdout.print("  Error: {s}\n\n", .{err_msg});
            }
        }

        // Show resolution path if verbose
        if (options.verbose) {
            try stdout.print("Resolution path (checked in order):\n", .{});
            for (resolution_steps.items, 0..) |step, i| {
                const marker = if (i == 0 and step.found) "→" else " ";
                if (step.found) {
                    try stdout.print("  {s} {d}. {s}: found\n", .{ marker, i + 1, step.source });
                } else {
                    try stdout.print("  {s} {d}. {s}: not found\n", .{ marker, i + 1, step.source });
                }
            }
            try stdout.print("\n", .{});
        }

        // Warnings
        var warnings_shown = false;

        if (!std.mem.eql(u8, ctx, "local")) {
            if (std.mem.indexOf(u8, value, "localhost") != null or
                std.mem.indexOf(u8, value, "127.0.0.1") != null)
            {
                if (!warnings_shown) {
                    try stdout.print("Warnings:\n", .{});
                    warnings_shown = true;
                }
                try stdout.print("  ⚠️  Value contains localhost in '{s}' context\n", .{ctx});
            }

            if (field.field_type == .secret and std.mem.indexOf(u8, value, "test") != null) {
                if (!warnings_shown) {
                    try stdout.print("Warnings:\n", .{});
                    warnings_shown = true;
                }
                try stdout.print("  ⚠️  Secret contains 'test' in '{s}' context\n", .{ctx});
            }
        }

        if (warnings_shown) {
            try stdout.print("\n", .{});
        }
    } else {
        try stdout.print("❌ Not set in context '{s}'\n\n", .{ctx});

        if (validation.isRequired(field, ctx)) {
            try stdout.print("  This field is REQUIRED in '{s}' but not provided!\n\n", .{ctx});
        }

        try stdout.print("Checked:\n", .{});
        for (resolution_steps.items, 0..) |step, i| {
            try stdout.print("  {d}. {s}: not found\n", .{ i + 1, step.source });
        }
        try stdout.print("\n", .{});

        try stdout.print("How to fix:\n", .{});
        try stdout.print("  - Set as environment variable: export {s}=value\n", .{args.key});
        if (default_source) |src| {
            try stdout.print("  - Add to source '{s}'\n", .{src});
        }
        try stdout.print("  - Add to .env file\n", .{});
    }

    // Show field schema info
    if (options.verbose) {
        try stdout.print("Schema definition:\n", .{});
        try stdout.print("  Type: {s}\n", .{field.field_type.toString()});
        if (field.description) |desc| {
            try stdout.print("  Description: {s}\n", .{desc});
        }
        if (field.default) |def| {
            try stdout.print("  Default: {s}\n", .{def});
        }
        try stdout.print("  Required: ", .{});
        switch (field.required) {
            .always => |req| try stdout.print("{s}\n", .{if (req) "yes (all contexts)" else "no"}),
            .contexts => |contexts| {
                try stdout.print("yes in [", .{});
                for (contexts, 0..) |c, i| {
                    if (i > 0) try stdout.print(", ", .{});
                    try stdout.print("{s}", .{c});
                }
                try stdout.print("]\n", .{});
            },
        }
    }
}

const ResolutionStep = struct {
    source: []const u8,
    source_allocated: bool, // true if source string needs to be freed
    found: bool,
    value: ?[]const u8,
};

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
