const std = @import("std");
const zcli = @import("zcli");
const yaml = @import("yaml");
const sources = @import("sources");
const validation = @import("validation");

const SourceResolver = sources.SourceResolver;

pub const meta = .{
    .description = "Compare configuration between two contexts",
    .examples = &.{
        "configflow diff local prod",
        "configflow diff staging prod --key DATABASE_URL",
        "configflow diff local staging --show-secrets",
    },
    .options = .{
        .key = .{ .description = "Only compare a specific key", .short = 'k' },
        .show_secrets = .{ .description = "Show full secret values (default: redacted)", .short = 's' },
    },
};

pub const Args = struct {
    context1: []const u8,
    context2: []const u8,
};

pub const Options = struct {
    key: ?[]const u8 = null,
    show_secrets: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout();
    const stderr = context.stderr();

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

    try stdout.print("Comparing: {s} → {s}\n\n", .{ args.context1, args.context2 });

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

    // Get contexts section
    const contexts_value = root_map.get("contexts");
    var context1_source: ?[]const u8 = null;
    var context2_source: ?[]const u8 = null;

    if (contexts_value) |contexts_section| {
        if (contexts_section.asMap()) |ctx_map| {
            if (ctx_map.get(args.context1)) |ctx1_config| {
                if (ctx1_config.asMap()) |cfg| {
                    if (cfg.get("default_source")) |src_value| {
                        context1_source = src_value.asScalar();
                    }
                }
            }
            if (ctx_map.get(args.context2)) |ctx2_config| {
                if (ctx2_config.asMap()) |cfg| {
                    if (cfg.get("default_source")) |src_value| {
                        context2_source = src_value.asScalar();
                    }
                }
            }
        }
    }

    // Compare each field
    var differences: u32 = 0;
    var warnings: u32 = 0;
    var same: u32 = 0;

    for (fields) |field| {
        // Skip if filtering by key
        if (options.key) |filter_key| {
            if (!std.mem.eql(u8, field.name, filter_key)) {
                continue;
            }
        }

        // Fetch values for both contexts
        const value1 = try fetchValue(allocator, field.name, args.context1, context1_source, &resolver);
        defer if (value1) |v| allocator.free(v);

        const value2 = try fetchValue(allocator, field.name, args.context2, context2_source, &resolver);
        defer if (value2) |v| allocator.free(v);

        // Compare values
        const comparison = compareValues(field, value1, value2);

        try stdout.print("{s}:\n", .{field.name});

        // Display values (redact secrets if needed)
        const display1 = if (field.field_type == .secret and !options.show_secrets)
            try redactValue(allocator, value1)
        else if (value1) |v|
            try allocator.dupe(u8, v)
        else
            try allocator.dupe(u8, "(not set)");
        defer allocator.free(display1);

        const display2 = if (field.field_type == .secret and !options.show_secrets)
            try redactValue(allocator, value2)
        else if (value2) |v|
            try allocator.dupe(u8, v)
        else
            try allocator.dupe(u8, "(not set)");
        defer allocator.free(display2);

        try stdout.print("  {s}: {s}\n", .{ args.context1, display1 });
        try stdout.print("  {s}: {s}\n", .{ args.context2, display2 });

        switch (comparison) {
            .same => {
                try stdout.print("  ✓ Same\n", .{});
                same += 1;

                // Check for warnings
                if (value1 != null and value2 != null) {
                    if (field.field_type == .secret and std.mem.eql(u8, value1.?, value2.?)) {
                        try stdout.print("  ⚠️  WARNING: Same secret value in both contexts\n", .{});
                        warnings += 1;
                    }
                }
            },
            .different => {
                try stdout.print("  ↔️  Different\n", .{});
                differences += 1;
            },
            .only_in_first => {
                try stdout.print("  ⚠️  Only in {s}\n", .{args.context1});
                warnings += 1;
            },
            .only_in_second => {
                try stdout.print("  ⚠️  Only in {s}\n", .{args.context2});
                warnings += 1;
            },
        }

        // Additional warnings
        if (value2) |v2| {
            if (!std.mem.eql(u8, args.context2, "local")) {
                if (std.mem.indexOf(u8, v2, "localhost") != null or
                    std.mem.indexOf(u8, v2, "127.0.0.1") != null)
                {
                    try stdout.print("  ⚠️  WARNING: localhost detected in {s}\n", .{args.context2});
                    warnings += 1;
                }

                if (field.field_type == .secret) {
                    if (std.mem.indexOf(u8, v2, "test") != null) {
                        try stdout.print("  ⚠️  WARNING: 'test' detected in {s} secret\n", .{args.context2});
                        warnings += 1;
                    }
                }
            }
        }

        try stdout.print("\n", .{});
    }

    // Summary
    try stdout.print("Summary:\n", .{});
    try stdout.print("  ↔️  {} field(s) different\n", .{differences});
    try stdout.print("  ✓ {} field(s) same\n", .{same});
    if (warnings > 0) {
        try stdout.print("  ⚠️  {} warning(s)\n", .{warnings});
    }
}

const ComparisonResult = enum {
    same,
    different,
    only_in_first,
    only_in_second,
};

fn compareValues(field: validation.Field, value1: ?[]const u8, value2: ?[]const u8) ComparisonResult {
    _ = field;

    if (value1 == null and value2 == null) return .same;
    if (value1 != null and value2 == null) return .only_in_first;
    if (value1 == null and value2 != null) return .only_in_second;

    if (std.mem.eql(u8, value1.?, value2.?)) {
        return .same;
    } else {
        return .different;
    }
}

fn fetchValue(
    allocator: std.mem.Allocator,
    key: []const u8,
    context_name: []const u8,
    source_name: ?[]const u8,
    resolver: *SourceResolver,
) !?[]const u8 {
    _ = context_name;

    // First check environment variable (highest precedence)
    if (std.process.getEnvVarOwned(allocator, key)) |env_value| {
        return env_value;
    } else |_| {
        // Try to fetch from source if configured
        if (source_name) |src| {
            if (resolver.getSource(src)) |backend| {
                if (try backend.fetch(allocator, key)) |source_value| {
                    defer {
                        var mut_val = source_value;
                        mut_val.deinit();
                    }
                    return try allocator.dupe(u8, source_value.value);
                }
            }
        }
    }

    return null;
}

fn redactValue(allocator: std.mem.Allocator, value: ?[]const u8) ![]const u8 {
    if (value == null) {
        return try allocator.dupe(u8, "(not set)");
    }

    const v = value.?;
    if (v.len <= 8) {
        return try allocator.dupe(u8, "***");
    }

    // Show first 4 and last 4 characters
    return try std.fmt.allocPrint(allocator, "{s}***{s}", .{ v[0..4], v[v.len - 4 ..] });
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
