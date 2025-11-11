const std = @import("std");
const zcli = @import("zcli");
const yaml = @import("yaml");
const sources = @import("sources");
const validation = @import("validation");

const SourceResolver = sources.SourceResolver;

pub const meta = .{
    .description = "Validate ConfigFlow schema and configuration values",
    .examples = &.{
        "configflow validate",
        "configflow validate --context prod",
        "configflow validate --verbose",
    },
    .options = .{
        .verbose = .{ .description = "Show detailed validation output", .short = 'v' },
        .context = .{ .description = "Context to validate (default: local)", .short = 'c' },
    },
};

pub const Args = struct {};

pub const Options = struct {
    verbose: bool = false,
    context: ?[]const u8 = null,
};

pub fn execute(_: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout();
    const stderr = context.stderr();

    // Determine context (default to local)
    const validation_context = options.context orelse "local";

    // Check if .configflow directory exists
    if (!checkDirExists(".configflow")) {
        try stderr.print("❌ Error: .configflow directory not found.\n", .{});
        try stderr.print("   Run 'configflow init' first to initialize ConfigFlow.\n\n", .{});
        return error.NotInitialized;
    }

    try stdout.print("Validating ConfigFlow configuration...\n", .{});
    try stdout.print("Context: {s}\n\n", .{validation_context});

    // Validate schema.yml exists
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
        try stderr.print("   Make sure the file is valid YAML\n\n", .{});
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

    if (options.verbose) {
        try stdout.print("✓ Parsed {} field(s) from schema\n\n", .{fields.len});
    }

    // Get sources section
    const sources_value = root_map.get("sources");

    // Initialize source resolver
    var resolver = SourceResolver.init(allocator);
    defer resolver.deinit();

    if (sources_value) |sources_section| {
        // Parse and register sources
        try resolver.parseAndRegisterSources(sources_section);

        if (options.verbose) {
            try stdout.print("✓ Registered configuration sources\n\n", .{});
        }
    }

    // Get contexts section to determine which source to use
    const contexts_value = root_map.get("contexts");
    var default_source: ?[]const u8 = null;

    if (contexts_value) |contexts_section| {
        if (contexts_section.asMap()) |ctx_map| {
            if (ctx_map.get(validation_context)) |ctx_config| {
                if (ctx_config.asMap()) |cfg| {
                    if (cfg.get("default_source")) |src_value| {
                        default_source = src_value.asScalar();
                    }
                }
            }
        }
    }

    // Validate each field
    var validation_errors = try std.ArrayList(ValidationError).initCapacity(allocator, 0);
    defer {
        for (validation_errors.items) |*err| {
            err.deinit(allocator);
        }
        validation_errors.deinit(allocator);
    }

    for (fields) |field| {
        if (options.verbose) {
            try stdout.print("Validating '{s}'...\n", .{field.name});
        }

        // Try to fetch value from source
        var value: ?[]const u8 = null;
        var value_owned: bool = false;
        defer {
            if (value_owned and value != null) {
                allocator.free(value.?);
            }
        }

        // First check environment variable (highest precedence)
        if (std.process.getEnvVarOwned(allocator, field.name)) |env_value| {
            value = env_value;
            value_owned = true;
            if (options.verbose) {
                try stdout.print("  ✓ Found in environment\n", .{});
            }
        } else |_| {
            // Try to fetch from default source if configured
            if (default_source) |source_name| {
                if (resolver.getSource(source_name)) |backend| {
                    if (try backend.fetch(allocator, field.name)) |source_value| {
                        defer {
                            var mut_val = source_value;
                            mut_val.deinit();
                        }
                        value = try allocator.dupe(u8, source_value.value);
                        value_owned = true;
                        if (options.verbose) {
                            try stdout.print("  ✓ Found in source '{s}'\n", .{source_name});
                        }
                    }
                }
            }
        }

        // Apply default if value not found and default is specified
        if (value == null and field.default != null) {
            value = field.default;
            value_owned = false; // Don't free, it's part of field
            if (options.verbose) {
                try stdout.print("  ✓ Using default value\n", .{});
            }
        }

        // Validate the field
        const result = try validation.validateField(
            allocator,
            field,
            value,
            validation_context,
        );

        if (!result.success) {
            const error_msg = if (result.error_message) |msg|
                try allocator.dupe(u8, msg)
            else
                try allocator.dupe(u8, "Unknown error");

            try validation_errors.append(allocator, ValidationError{
                .field = field.name,
                .error_message = error_msg,
                .field_type = field.field_type,
            });
            if (options.verbose) {
                try stderr.print("  ❌ {s}\n", .{error_msg});
            }
        } else {
            if (options.verbose) {
                try stdout.print("  ✓ Valid\n", .{});
            }
        }

        result.deinit(allocator);

        if (options.verbose) {
            try stdout.print("\n", .{});
        }
    }

    // Display results
    try stdout.print("\n", .{});

    if (validation_errors.items.len == 0) {
        try stdout.print("✅ All validation checks passed!\n", .{});
        try stdout.print("   {} field(s) validated in context '{s}'\n", .{ fields.len, validation_context });
    } else {
        try stdout.print("❌ Validation failed (context: {s})\n\n", .{validation_context});

        for (validation_errors.items) |err| {
            try stderr.print("Error: {s}\n", .{err.error_message});
            try stderr.print("  Field: {s}\n", .{err.field});
            try stderr.print("  Type: {s}\n", .{err.field_type.toString()});
            try stderr.print("  Context: {s}\n", .{validation_context});
            try stderr.print("\n", .{});

            // Provide "How to fix" suggestions
            if (std.mem.indexOf(u8, err.error_message, "required") != null) {
                try stderr.print("  How to fix:\n", .{});
                try stderr.print("    - Set as environment variable: export {s}=value\n", .{err.field});
                try stderr.print("    - Add to .env file: echo '{s}=value' >> .env\n", .{err.field});
                if (default_source) |source_name| {
                    try stderr.print("    - Add to source '{s}'\n", .{source_name});
                }
            } else if (std.mem.indexOf(u8, err.error_message, "invalid") != null) {
                try stderr.print("  How to fix:\n", .{});
                switch (err.field_type) {
                    .integer => try stderr.print("    Change to a valid integer (e.g., {s}=42)\n", .{err.field}),
                    .boolean => try stderr.print("    Change to 'true' or 'false' (lowercase)\n", .{}),
                    .url => try stderr.print("    Change to a valid URL starting with http:// or https://\n", .{}),
                    .connection_string => try stderr.print("    Change to a valid connection string (e.g., postgresql://host/db)\n", .{}),
                    .email => try stderr.print("    Change to a valid email address (e.g., user@example.com)\n", .{}),
                    else => {},
                }
            }
            try stderr.print("\n", .{});
        }

        try stdout.print("Summary:\n", .{});
        try stdout.print("  ❌ {} error(s)\n", .{validation_errors.items.len});
        try stdout.print("  ✓ {} field(s) passed\n", .{fields.len - validation_errors.items.len});
        try stdout.print("\n", .{});
        try stderr.print("Validation failed. Fix the errors above and try again.\n", .{});

        return error.ValidationFailed;
    }
}

const ValidationError = struct {
    field: []const u8,
    error_message: []const u8,
    field_type: validation.FieldType,

    pub fn deinit(self: *ValidationError, allocator: std.mem.Allocator) void {
        allocator.free(self.error_message);
    }
};

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
