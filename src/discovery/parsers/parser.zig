const std = @import("std");

/// Configuration types that can be inferred from code
pub const ConfigType = enum {
    string,
    integer,
    boolean,
    url,
    connection_string,
    secret,
    email,

    pub fn toString(self: ConfigType) []const u8 {
        return switch (self) {
            .string => "string",
            .integer => "integer",
            .boolean => "boolean",
            .url => "url",
            .connection_string => "connection_string",
            .secret => "secret",
            .email => "email",
        };
    }
};

/// Confidence level for type inference
pub const Confidence = enum {
    high,   // Explicit conversion (parseInt, Boolean, etc.)
    medium, // Name-based heuristic or comparison
    low,    // Default/fallback

    pub fn toString(self: Confidence) []const u8 {
        return switch (self) {
            .high => "high",
            .medium => "medium",
            .low => "low",
        };
    }
};

/// Type inference result
pub const TypeInference = struct {
    type: ConfigType,
    confidence: Confidence,
};

/// Represents a discovered environment variable usage in code
pub const EnvVarUsage = struct {
    name: []const u8,           // Variable name (e.g., "PORT")
    inferred_type: ConfigType,  // Inferred configuration type
    file_path: []const u8,      // Relative file path
    line_number: usize,         // Line number in file
    confidence: Confidence,     // Confidence in type inference
    context: ?[]const u8,       // Optional code snippet for context
    default_value: ?[]const u8, // Optional default value detected in code
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EnvVarUsage) void {
        self.allocator.free(self.name);
        self.allocator.free(self.file_path);
        if (self.context) |ctx| {
            self.allocator.free(ctx);
        }
        if (self.default_value) |val| {
            self.allocator.free(val);
        }
    }
};

/// Warning about env var access that couldn't be determined
pub const Warning = struct {
    file_path: []const u8,
    line_number: usize,
    message: []const u8,
    warning_type: WarningType,
    allocator: std.mem.Allocator,

    pub const WarningType = enum {
        dynamic_access,    // process.env[variable]
        computed_key,      // process.env[`${prefix}_KEY`]
        unknown_pattern,   // customGetter('API_KEY')
    };

    pub fn deinit(self: *Warning) void {
        self.allocator.free(self.file_path);
        self.allocator.free(self.message);
    }
};

/// Result from parsing a file
pub const ParseResult = struct {
    usages: []EnvVarUsage,
    warnings: []Warning,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParseResult) void {
        for (self.usages) |*usage| {
            usage.deinit();
        }
        self.allocator.free(self.usages);

        for (self.warnings) |*warning| {
            warning.deinit();
        }
        self.allocator.free(self.warnings);
    }
};

/// Base parser interface using function pointers for polymorphism
pub const Parser = struct {
    const Self = @This();

    /// Context pointer for parser-specific data
    ctx: *anyopaque,

    /// Discover env vars in source code
    discoverFn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        source_code: []const u8,
    ) anyerror!ParseResult,

    /// Deinitialize parser-specific resources
    deinitFn: *const fn (ctx: *anyopaque) void,

    pub fn discover(
        self: Self,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        source_code: []const u8,
    ) !ParseResult {
        return self.discoverFn(self.ctx, allocator, file_path, source_code);
    }

    pub fn deinit(self: Self) void {
        self.deinitFn(self.ctx);
    }
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "ConfigType toString" {
    try expectEqualStrings("string", ConfigType.string.toString());
    try expectEqualStrings("integer", ConfigType.integer.toString());
    try expectEqualStrings("boolean", ConfigType.boolean.toString());
}

test "Confidence toString" {
    try expectEqualStrings("high", Confidence.high.toString());
    try expectEqualStrings("medium", Confidence.medium.toString());
    try expectEqualStrings("low", Confidence.low.toString());
}

test "EnvVarUsage lifecycle" {
    const allocator = std.testing.allocator;

    var usage = EnvVarUsage{
        .name = try allocator.dupe(u8, "PORT"),
        .inferred_type = .integer,
        .file_path = try allocator.dupe(u8, "src/server.ts"),
        .line_number = 42,
        .confidence = .high,
        .context = try allocator.dupe(u8, "const port = parseInt(process.env.PORT)"),
        .default_value = try allocator.dupe(u8, "3000"),
        .allocator = allocator,
    };
    defer usage.deinit();

    try expectEqualStrings("PORT", usage.name);
    try expectEqual(ConfigType.integer, usage.inferred_type);
    try expectEqual(@as(usize, 42), usage.line_number);
}

test "ParseResult lifecycle" {
    const allocator = std.testing.allocator;

    var usages = try allocator.alloc(EnvVarUsage, 1);
    usages[0] = EnvVarUsage{
        .name = try allocator.dupe(u8, "API_KEY"),
        .inferred_type = .secret,
        .file_path = try allocator.dupe(u8, "src/api.ts"),
        .line_number = 10,
        .confidence = .high,
        .context = null,
        .default_value = null,
        .allocator = allocator,
    };

    const warnings = try allocator.alloc(Warning, 0);

    var result = ParseResult{
        .usages = usages,
        .warnings = warnings,
        .allocator = allocator,
    };
    defer result.deinit();

    try expectEqual(@as(usize, 1), result.usages.len);
    try expectEqual(@as(usize, 0), result.warnings.len);
}
