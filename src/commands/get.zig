const std = @import("std");
const zcli = @import("zcli");
const yaml = @import("yaml");
const sources = @import("sources");
const SourceResolver = sources.SourceResolver;

pub const meta = .{
    .description = "Get a configuration value from a source",
    .examples = &.{
        "configflow get DATABASE_URL",
        "configflow get DATABASE_URL --env staging",
        "configflow get API_KEY --env prod",
    },
    .options = .{
        .env = .{
            .description = "Environment to fetch from (local, staging, prod)",
            .short = 'e',
        },
    },
};

pub const Args = struct {
    key: []const u8,
};

pub const Options = struct {
    env: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
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

    // Determine environment (default to local)
    const env = options.env orelse "local";

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

    // Verify the key exists in schema
    const key_config = config_map.get(args.key) orelse {
        try stderr.print("Error: Key '{s}' not found in schema\n", .{args.key});
        return error.KeyNotFound;
    };

    const key_config_map = key_config.asMap() orelse {
        try stderr.print("Error: Invalid configuration for key '{s}'\n", .{args.key});
        return error.InvalidKeyConfig;
    };

    // Get sources section from key config
    const sources_value = key_config_map.get("sources") orelse {
        try stderr.print("Error: No sources configured for key '{s}'\n", .{args.key});
        return error.NoSources;
    };

    const sources_map = sources_value.asMap() orelse {
        try stderr.print("Error: Invalid sources format for key '{s}'\n", .{args.key});
        return error.InvalidSources;
    };

    // Get source name for this environment
    const env_source_value = sources_map.get(env) orelse {
        try stderr.print("Error: No source configured for environment '{s}'\n", .{env});
        return error.NoSourceForEnv;
    };

    // Check if source is null (not configured)
    if (env_source_value.asScalar()) |source_name| {
        if (std.mem.eql(u8, source_name, "null")) {
            try stderr.print("Error: Source for environment '{s}' is not configured\n", .{env});
            try stderr.print("Update schema.yml to configure this source.\n", .{});
            return error.SourceNotConfigured;
        }

        // Now we have the source name, we need to get its configuration
        // from the top-level 'sources' section
        const sources_section = root_map.get("sources") orelse {
            try stderr.print("Error: schema.yml missing 'sources' section\n", .{});
            return error.MissingSources;
        };

        // Initialize source resolver
        var resolver = SourceResolver.init(allocator);
        defer resolver.deinit();

        // Parse and register sources
        try resolver.parseAndRegisterSources(sources_section);

        // Get the backend for this source
        const backend = resolver.getSource(source_name) orelse {
            try stderr.print("Error: Source '{s}' not found or not configured\n", .{source_name});
            return error.SourceNotFound;
        };

        // First check environment variable (highest precedence)
        if (std.process.getEnvVarOwned(allocator, args.key)) |env_value| {
            defer allocator.free(env_value);
            try stdout.print("{s}\n", .{env_value});
            return;
        } else |_| {
            // Environment variable not found, continue to source
        }

        // Fetch the value from the source
        if (try backend.fetch(allocator, args.key)) |value| {
            defer {
                var mut_value = value;
                mut_value.deinit();
            }
            try stdout.print("{s}\n", .{value.value});
        } else {
            try stderr.print("Error: Key '{s}' not found in source '{s}'\n", .{ args.key, source_name });
            return error.ValueNotFound;
        }
    } else {
        try stderr.print("Error: Invalid source configuration for environment '{s}'\n", .{env});
        return error.InvalidSourceConfig;
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
