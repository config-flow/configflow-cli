const std = @import("std");
const parser_base = @import("parser.zig");
const ConfigType = parser_base.ConfigType;
const Confidence = parser_base.Confidence;
const EnvVarUsage = parser_base.EnvVarUsage;
const Warning = parser_base.Warning;
const ParseResult = parser_base.ParseResult;
const Parser = parser_base.Parser;

/// Zig bindings for tree-sitter
const ts = @import("tree_sitter");

/// External declaration for the JavaScript parser
extern fn tree_sitter_javascript() *const ts.Language;

/// JavaScript parser for discovering environment variable usage
pub const JavaScriptParser = struct {
    allocator: std.mem.Allocator,
    ts_parser: *ts.Parser,
    query: *ts.Query,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*JavaScriptParser {
        const ts_parser = ts.Parser.create();
        errdefer ts_parser.destroy();

        const language = tree_sitter_javascript();
        try ts_parser.setLanguage(language);

        // Query to find process.env accesses
        // Matches:
        // - process.env.KEY (member_expression)
        // - process.env["KEY"] (subscript_expression with string)
        // - process.env[variable] (subscript_expression with identifier - dynamic)
        const query_source =
            \\; Match process.env.KEY
            \\(member_expression
            \\  object: (member_expression
            \\    object: (identifier) @process (#eq? @process "process")
            \\    property: (property_identifier) @env (#eq? @env "env"))
            \\  property: (property_identifier) @key) @access
            \\
            \\; Match process.env["KEY"] with string literal
            \\(subscript_expression
            \\  object: (member_expression
            \\    object: (identifier) @process (#eq? @process "process")
            \\    property: (property_identifier) @env (#eq? @env "env"))
            \\  index: (string) @key_string) @access
            \\
            \\; Match process.env[variable] - dynamic access
            \\(subscript_expression
            \\  object: (member_expression
            \\    object: (identifier) @process (#eq? @process "process")
            \\    property: (property_identifier) @env (#eq? @env "env"))
            \\  index: (identifier) @dynamic_key) @dynamic_access
            \\
            \\; Match process.env[`template`] - template string
            \\(subscript_expression
            \\  object: (member_expression
            \\    object: (identifier) @process (#eq? @process "process")
            \\    property: (property_identifier) @env (#eq? @env "env"))
            \\  index: (template_string) @template_key) @computed_access
        ;

        var error_offset: u32 = 0;
        const query = ts.Query.create(language, query_source, &error_offset) catch |err| {
            ts_parser.destroy();
            return err;
        };

        const self = try allocator.create(JavaScriptParser);
        self.* = .{
            .allocator = allocator,
            .ts_parser = ts_parser,
            .query = query,
        };

        return self;
    }

    pub fn parser(self: *JavaScriptParser) Parser {
        return .{
            .ctx = self,
            .discoverFn = discover,
            .deinitFn = deinit,
        };
    }

    fn discover(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        source_code: []const u8,
    ) !ParseResult {
        const self: *JavaScriptParser = @ptrCast(@alignCast(ctx));

        // Parse the source code
        const tree = self.ts_parser.parseString(source_code, null) orelse {
            return error.ParseFailed;
        };
        defer tree.destroy();

        var usages = std.ArrayList(EnvVarUsage){};
        errdefer {
            for (usages.items) |*usage| usage.deinit();
            usages.deinit(allocator);
        }

        var warnings = std.ArrayList(Warning){};
        errdefer {
            for (warnings.items) |*warning| warning.deinit();
            warnings.deinit(allocator);
        }

        // Execute query
        const root_node = tree.rootNode();
        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.exec(self.query, root_node);

        while (cursor.nextMatch()) |match| {
            try processMatch(
                allocator,
                self.query,
                match,
                source_code,
                file_path,
                &usages,
                &warnings,
            );
        }

        return ParseResult{
            .usages = try usages.toOwnedSlice(allocator),
            .warnings = try warnings.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *JavaScriptParser = @ptrCast(@alignCast(ctx));
        const allocator = self.allocator;

        self.query.destroy();
        self.ts_parser.destroy();
        allocator.destroy(self);
    }

    /// Process a query match and extract env var usage or warning
    fn processMatch(
        allocator: std.mem.Allocator,
        query: *const ts.Query,
        match: ts.Query.Match,
        source_code: []const u8,
        file_path: []const u8,
        usages: *std.ArrayList(EnvVarUsage),
        warnings: *std.ArrayList(Warning),
    ) !void {
        var key_node: ?ts.Node = null;
        var access_node: ?ts.Node = null;
        var is_dynamic = false;
        var is_computed = false;

        // Extract captures from match
        for (match.captures) |capture| {
            const capture_name = query.captureNameForId(capture.index) orelse continue;

            if (std.mem.eql(u8, capture_name, "key")) {
                key_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "key_string")) {
                key_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "access")) {
                access_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "dynamic_key")) {
                is_dynamic = true;
                key_node = capture.node; // Store the identifier for potential future use
            } else if (std.mem.eql(u8, capture_name, "dynamic_access")) {
                access_node = capture.node; // The full subscript expression
            } else if (std.mem.eql(u8, capture_name, "template_key")) {
                is_computed = true;
                key_node = capture.node; // Store the template for potential future use
            } else if (std.mem.eql(u8, capture_name, "computed_access")) {
                access_node = capture.node; // The full subscript expression
            }
        }

        if (access_node == null) return;

        // Validate that this is actually a process.env access
        // Tree-sitter query predicates don't always filter correctly, so we do additional validation
        const access_start = access_node.?.startByte();
        const access_end = access_node.?.endByte();
        const access_text = source_code[access_start..access_end];

        // Check if the access starts with "process.env" (not just any object.env)
        // This filters out false matches like obj.env.PORT or myEnv.PORT
        if (!std.mem.startsWith(u8, access_text, "process.env")) {
            // This is a false match
            return;
        }

        // Get line number
        const start_point = access_node.?.startPoint();
        const line_number = start_point.row + 1;

        // Handle dynamic access (warning)
        if (is_dynamic) {
            const warning = Warning{
                .file_path = try allocator.dupe(u8, file_path),
                .line_number = line_number,
                .message = try allocator.dupe(u8, "Dynamic environment variable access detected"),
                .warning_type = .dynamic_access,
                .allocator = allocator,
            };
            try warnings.append(allocator, warning);
            return;
        }

        // Handle computed key (warning)
        if (is_computed) {
            const warning = Warning{
                .file_path = try allocator.dupe(u8, file_path),
                .line_number = line_number,
                .message = try allocator.dupe(u8, "Computed environment variable key detected"),
                .warning_type = .computed_key,
                .allocator = allocator,
            };
            try warnings.append(allocator, warning);
            return;
        }

        // Extract key name
        if (key_node) |node| {
            const start_byte = node.startByte();
            const end_byte = node.endByte();
            var key_text = source_code[start_byte..end_byte];

            // Remove quotes from string literals
            if (key_text.len >= 2) {
                if ((key_text[0] == '"' or key_text[0] == '\'') and
                    key_text[key_text.len - 1] == key_text[0])
                {
                    key_text = key_text[1 .. key_text.len - 1];
                }
            }

            // Get context (the full line)
            const context = try extractContext(allocator, source_code, access_node.?);

            // Detect default value
            const default_value = try detectDefaultValue(allocator, source_code, access_node.?);

            // Infer type from context
            const inference = inferType(key_text, context, source_code, access_node.?);

            const usage = EnvVarUsage{
                .name = try allocator.dupe(u8, key_text),
                .inferred_type = inference.type,
                .file_path = try allocator.dupe(u8, file_path),
                .line_number = line_number,
                .confidence = inference.confidence,
                .context = context,
                .default_value = default_value,
                .allocator = allocator,
            };

            try usages.append(allocator, usage);
        }
    }

    /// Extract context (surrounding code) for an env var access
    fn extractContext(
        allocator: std.mem.Allocator,
        source_code: []const u8,
        node: ts.Node,
    ) !?[]const u8 {
        const start_point = node.startPoint();

        // Find the start of the line
        var line_start: usize = 0;
        var current_row: u32 = 0;
        for (source_code, 0..) |char, i| {
            if (current_row == start_point.row) {
                line_start = i;
                break;
            }
            if (char == '\n') {
                current_row += 1;
            }
        }

        // Find the end of the line
        var line_end = line_start;
        while (line_end < source_code.len and source_code[line_end] != '\n') {
            line_end += 1;
        }

        const line = source_code[line_start..line_end];
        return try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r"));
    }

    /// Detect default value patterns like:
    /// - process.env.PORT || '3000'
    /// - process.env.PORT ?? '3000'
    /// - process.env.PORT ? process.env.PORT : '3000'
    fn detectDefaultValue(
        allocator: std.mem.Allocator,
        source_code: []const u8,
        node: ts.Node,
    ) !?[]const u8 {
        var current = node;

        // Walk up the tree to find if this node is part of a binary expression or ternary
        var parent = current.parent();
        while (parent) |p| {
            const parent_type = p.kind();

            // Check for binary expression (|| or ??)
            if (std.mem.eql(u8, parent_type, "binary_expression")) {
                // Get the operator
                const parent_start = p.startByte();
                const parent_end = p.endByte();
                const parent_text = source_code[parent_start..parent_end];

                // Check if our node is the left side of the binary expression
                const left_child = p.childByFieldName("left");
                if (left_child) |left| {
                    if (left.startByte() == current.startByte() and left.endByte() == current.endByte()) {
                        // Our node is on the left, check for || or ??
                        if (std.mem.indexOf(u8, parent_text, "||") != null or std.mem.indexOf(u8, parent_text, "??") != null) {
                            // Get the right side (the default value)
                            const right_child = p.childByFieldName("right");
                            if (right_child) |right| {
                                const right_start = right.startByte();
                                const right_end = right.endByte();
                                var default_text = source_code[right_start..right_end];

                                // Remove quotes from string literals
                                default_text = std.mem.trim(u8, default_text, " \t");
                                if (default_text.len >= 2) {
                                    if ((default_text[0] == '"' or default_text[0] == '\'' or default_text[0] == '`') and
                                        default_text[default_text.len - 1] == default_text[0])
                                    {
                                        default_text = default_text[1 .. default_text.len - 1];
                                    }
                                }

                                return try allocator.dupe(u8, default_text);
                            }
                        }
                    }
                }
            }

            // Check for ternary expression (condition ? true_value : false_value)
            // In JavaScript, this is a conditional_expression or ternary_expression
            if (std.mem.eql(u8, parent_type, "ternary_expression") or std.mem.eql(u8, parent_type, "conditional_expression")) {
                // Check if our node is the condition
                const condition_child = p.childByFieldName("condition");
                if (condition_child) |condition| {
                    if (condition.startByte() == current.startByte() and condition.endByte() == current.endByte()) {
                        // Our node is the condition, get the alternative (false branch)
                        const alternative_child = p.childByFieldName("alternative");
                        if (alternative_child) |alternative| {
                            const alt_start = alternative.startByte();
                            const alt_end = alternative.endByte();
                            var default_text = source_code[alt_start..alt_end];

                            // Remove quotes from string literals
                            default_text = std.mem.trim(u8, default_text, " \t");
                            if (default_text.len >= 2) {
                                if ((default_text[0] == '"' or default_text[0] == '\'' or default_text[0] == '`') and
                                    default_text[default_text.len - 1] == default_text[0])
                                {
                                    default_text = default_text[1 .. default_text.len - 1];
                                }
                            }

                            return try allocator.dupe(u8, default_text);
                        }
                    }
                }
            }

            // Move to the next parent
            current = p;
            parent = current.parent();
        }

        return null;
    }

    /// Case-insensitive substring search
    fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
                return true;
            }
        }
        return false;
    }

    /// Case-insensitive prefix check
    fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
    }

    /// Infer configuration type from variable name and usage context
    fn inferType(
        key_name: []const u8,
        context: ?[]const u8,
        source_code: []const u8,
        node: ts.Node,
    ) parser_base.TypeInference {
        _ = source_code;

        // Check context for explicit type conversions (high confidence)
        if (context) |ctx| {
            // parseInt, Number() -> integer
            if (std.mem.indexOf(u8, ctx, "parseInt(") != null or
                std.mem.indexOf(u8, ctx, "Number(") != null or
                std.mem.indexOf(u8, ctx, "parseFloat(") != null)
            {
                return .{ .type = .integer, .confidence = .high };
            }

            // Boolean() -> boolean
            if (std.mem.indexOf(u8, ctx, "Boolean(") != null) {
                return .{ .type = .boolean, .confidence = .high };
            }

            // === 'true', === true, === 'false', === false -> boolean
            if (std.mem.indexOf(u8, ctx, "=== 'true'") != null or
                std.mem.indexOf(u8, ctx, "=== 'false'") != null or
                std.mem.indexOf(u8, ctx, "=== true") != null or
                std.mem.indexOf(u8, ctx, "=== false") != null or
                std.mem.indexOf(u8, ctx, "== 'true'") != null or
                std.mem.indexOf(u8, ctx, "== 'false'") != null)
            {
                return .{ .type = .boolean, .confidence = .medium };
            }

            // new URL() -> url
            if (std.mem.indexOf(u8, ctx, "new URL(") != null) {
                return .{ .type = .url, .confidence = .high };
            }
        }

        // Name-based heuristics (medium confidence) - use case-insensitive matching
        // Check more specific patterns first before generic ones

        // Connection strings (check before URLs since they contain "URL")
        if (indexOfIgnoreCase(key_name, "DATABASE_URL") or
            indexOfIgnoreCase(key_name, "DATABASE_URI") or
            indexOfIgnoreCase(key_name, "DB_URL") or
            indexOfIgnoreCase(key_name, "DB_URI") or
            indexOfIgnoreCase(key_name, "REDIS_URL") or
            indexOfIgnoreCase(key_name, "REDIS_URI") or
            indexOfIgnoreCase(key_name, "MONGO_URL") or
            indexOfIgnoreCase(key_name, "MONGO_URI") or
            indexOfIgnoreCase(key_name, "MONGODB_URI") or
            indexOfIgnoreCase(key_name, "CONNECTION_STRING"))
        {
            return .{ .type = .connection_string, .confidence = .medium };
        }

        // Secrets
        if (indexOfIgnoreCase(key_name, "SECRET") or
            indexOfIgnoreCase(key_name, "API_KEY") or
            indexOfIgnoreCase(key_name, "APIKEY") or
            indexOfIgnoreCase(key_name, "TOKEN") or
            indexOfIgnoreCase(key_name, "PASSWORD") or
            indexOfIgnoreCase(key_name, "PRIVATE_KEY") or
            indexOfIgnoreCase(key_name, "CREDENTIALS"))
        {
            return .{ .type = .secret, .confidence = .medium };
        }

        // URLs (check after connection strings)
        if (indexOfIgnoreCase(key_name, "URL") or
            indexOfIgnoreCase(key_name, "ENDPOINT") or
            indexOfIgnoreCase(key_name, "HOST"))
        {
            return .{ .type = .url, .confidence = .medium };
        }

        // Emails
        if (indexOfIgnoreCase(key_name, "EMAIL") or
            indexOfIgnoreCase(key_name, "MAIL"))
        {
            return .{ .type = .email, .confidence = .medium };
        }

        // Integers
        if (indexOfIgnoreCase(key_name, "PORT") or
            indexOfIgnoreCase(key_name, "TIMEOUT") or
            indexOfIgnoreCase(key_name, "MAX") or
            indexOfIgnoreCase(key_name, "MIN") or
            indexOfIgnoreCase(key_name, "LIMIT") or
            indexOfIgnoreCase(key_name, "COUNT") or
            indexOfIgnoreCase(key_name, "SIZE"))
        {
            return .{ .type = .integer, .confidence = .medium };
        }

        // Booleans
        if (indexOfIgnoreCase(key_name, "DEBUG") or
            indexOfIgnoreCase(key_name, "ENABLED") or
            indexOfIgnoreCase(key_name, "DISABLED") or
            indexOfIgnoreCase(key_name, "ENABLE") or
            indexOfIgnoreCase(key_name, "FLAG") or
            startsWithIgnoreCase(key_name, "IS_"))
        {
            return .{ .type = .boolean, .confidence = .medium };
        }

        // Default to string (low confidence)
        _ = node;
        return .{ .type = .string, .confidence = .low };
    }
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "JavaScriptParser init and deinit" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    // Pointers are non-nullable, so if init succeeded they're valid
}

test "JavaScriptParser discovers process.env.KEY" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const port = process.env.PORT;
        \\const host = process.env.HOST;
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);
    try expectEqual(@as(usize, 0), result.warnings.len);

    // Check first usage
    try expectEqualStrings("PORT", result.usages[0].name);
    try expectEqual(ConfigType.integer, result.usages[0].inferred_type);
    try expectEqual(Confidence.medium, result.usages[0].confidence);

    // Check second usage
    try expectEqualStrings("HOST", result.usages[1].name);
    try expectEqual(ConfigType.url, result.usages[1].inferred_type);
}

test "JavaScriptParser discovers process.env['KEY']" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const apiKey = process.env["API_KEY"];
        \\const secret = process.env['SECRET_TOKEN'];
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    try expectEqualStrings("API_KEY", result.usages[0].name);
    try expectEqual(ConfigType.secret, result.usages[0].inferred_type);

    try expectEqualStrings("SECRET_TOKEN", result.usages[1].name);
    try expectEqual(ConfigType.secret, result.usages[1].inferred_type);
}

test "JavaScriptParser infers types from parseInt" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const port = parseInt(process.env.PORT);
        \\const timeout = Number(process.env.TIMEOUT);
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    // Both should be integer with high confidence due to parseInt/Number
    try expectEqualStrings("PORT", result.usages[0].name);
    try expectEqual(ConfigType.integer, result.usages[0].inferred_type);
    try expectEqual(Confidence.high, result.usages[0].confidence);

    try expectEqualStrings("TIMEOUT", result.usages[1].name);
    try expectEqual(ConfigType.integer, result.usages[1].inferred_type);
    try expectEqual(Confidence.high, result.usages[1].confidence);
}

test "JavaScriptParser infers boolean from Boolean()" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const debug = Boolean(process.env.DEBUG);
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 1), result.usages.len);

    try expectEqualStrings("DEBUG", result.usages[0].name);
    try expectEqual(ConfigType.boolean, result.usages[0].inferred_type);
    try expectEqual(Confidence.high, result.usages[0].confidence);
}

test "JavaScriptParser infers boolean from comparison" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const isProduction = process.env.NODE_ENV === 'production';
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 1), result.usages.len);

    try expectEqualStrings("NODE_ENV", result.usages[0].name);
    // NODE_ENV doesn't match any heuristic, so it should be string
    try expectEqual(ConfigType.string, result.usages[0].inferred_type);
}

test "JavaScriptParser warns on dynamic access" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const key = 'API_KEY';
        \\const value = process.env[key];
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 0), result.usages.len);
    try expectEqual(@as(usize, 1), result.warnings.len);

    try expectEqual(Warning.WarningType.dynamic_access, result.warnings[0].warning_type);
    try expectEqualStrings("test.js", result.warnings[0].file_path);
}

test "JavaScriptParser warns on computed keys" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const value = process.env[`${prefix}_KEY`];
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 0), result.usages.len);
    try expectEqual(@as(usize, 1), result.warnings.len);

    try expectEqual(Warning.WarningType.computed_key, result.warnings[0].warning_type);
}

test "JavaScriptParser infers URL type" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const apiUrl = process.env.API_URL;
        \\const endpoint = process.env.SERVICE_ENDPOINT;
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    try expectEqual(ConfigType.url, result.usages[0].inferred_type);
    try expectEqual(ConfigType.url, result.usages[1].inferred_type);
}

test "JavaScriptParser infers connection_string type" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const db = process.env.DATABASE_URL;
        \\const redis = process.env.REDIS_URL;
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    try expectEqual(ConfigType.connection_string, result.usages[0].inferred_type);
    try expectEqual(ConfigType.connection_string, result.usages[1].inferred_type);
}

test "JavaScriptParser handles complex real-world example" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const express = require('express');
        \\const app = express();
        \\
        \\const port = parseInt(process.env.PORT) || 3000;
        \\const host = process.env.HOST || 'localhost';
        \\const debug = process.env.DEBUG === 'true';
        \\const apiKey = process.env.API_KEY;
        \\const dbUrl = process.env.DATABASE_URL;
        \\
        \\app.listen(port, host);
    ;

    var result = try js_parser.parser().discover(allocator, "server.js", source);
    defer result.deinit();

    // Should find 5 env vars
    try expectEqual(@as(usize, 5), result.usages.len);
    try expectEqual(@as(usize, 0), result.warnings.len);

    // Verify some key inferences
    var found_port = false;
    var found_api_key = false;
    var found_db = false;

    for (result.usages) |usage| {
        if (std.mem.eql(u8, usage.name, "PORT")) {
            found_port = true;
            try expectEqual(ConfigType.integer, usage.inferred_type);
            try expectEqual(Confidence.high, usage.confidence); // parseInt
        } else if (std.mem.eql(u8, usage.name, "API_KEY")) {
            found_api_key = true;
            try expectEqual(ConfigType.secret, usage.inferred_type);
        } else if (std.mem.eql(u8, usage.name, "DATABASE_URL")) {
            found_db = true;
            try expectEqual(ConfigType.connection_string, usage.inferred_type);
        }
    }

    try expect(found_port);
    try expect(found_api_key);
    try expect(found_db);
}

test "JavaScriptParser filters out false matches" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\// Real process.env access - should match
        \\const port = process.env.PORT;
        \\
        \\// False matches - should NOT match
        \\const obj = { env: { PORT: "3000" } };
        \\const fake1 = obj.env.PORT;
        \\const fake2 = myEnv.PORT;
        \\const str = "process.env.PORT";
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    // Should only find the real process.env.PORT, not the false matches
    try expectEqual(@as(usize, 1), result.usages.len);
    try expectEqualStrings("PORT", result.usages[0].name);
}

test "JavaScriptParser recognizes URI patterns for connection strings" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const mongo = process.env.MONGODB_URI;
        \\const db = process.env.DATABASE_URI;
        \\const redis = process.env.REDIS_URI;
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 3), result.usages.len);

    // All should be inferred as connection_string
    for (result.usages) |usage| {
        try expectEqual(ConfigType.connection_string, usage.inferred_type);
        try expectEqual(Confidence.medium, usage.confidence);
    }
}

test "JavaScriptParser detects default values with || operator" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const port = process.env.PORT || '3000';
        \\const host = process.env.HOST || 'localhost';
        \\const timeout = process.env.TIMEOUT || 5000;
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 3), result.usages.len);

    // Check PORT with default
    try expectEqualStrings("PORT", result.usages[0].name);
    try expect(result.usages[0].default_value != null);
    try expectEqualStrings("3000", result.usages[0].default_value.?);

    // Check HOST with default
    try expectEqualStrings("HOST", result.usages[1].name);
    try expect(result.usages[1].default_value != null);
    try expectEqualStrings("localhost", result.usages[1].default_value.?);

    // Check TIMEOUT with numeric default
    try expectEqualStrings("TIMEOUT", result.usages[2].name);
    try expect(result.usages[2].default_value != null);
    try expectEqualStrings("5000", result.usages[2].default_value.?);
}

test "JavaScriptParser detects default values with ?? operator" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const port = process.env.PORT ?? '8080';
        \\const debug = process.env.DEBUG ?? 'false';
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    // Check PORT with nullish coalescing default
    try expectEqualStrings("PORT", result.usages[0].name);
    try expect(result.usages[0].default_value != null);
    try expectEqualStrings("8080", result.usages[0].default_value.?);

    // Check DEBUG with default
    try expectEqualStrings("DEBUG", result.usages[1].name);
    try expect(result.usages[1].default_value != null);
    try expectEqualStrings("false", result.usages[1].default_value.?);
}

test "JavaScriptParser detects default values with ternary operator" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const port = process.env.PORT ? process.env.PORT : '3000';
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    // This pattern has process.env.PORT twice (condition and true branch), so we detect both
    try expectEqual(@as(usize, 2), result.usages.len);

    // The first occurrence (condition) should have the default value
    try expectEqualStrings("PORT", result.usages[0].name);
    try expect(result.usages[0].default_value != null);
    try expectEqualStrings("3000", result.usages[0].default_value.?);

    // The second occurrence (true branch) won't have a default
    try expectEqualStrings("PORT", result.usages[1].name);
    try expect(result.usages[1].default_value == null);
}

test "JavaScriptParser handles env vars without defaults" {
    const allocator = std.testing.allocator;
    const js_parser = try JavaScriptParser.init(allocator);
    defer js_parser.parser().deinit();

    const source =
        \\const apiKey = process.env.API_KEY;
        \\const dbUrl = process.env.DATABASE_URL;
    ;

    var result = try js_parser.parser().discover(allocator, "test.js", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    // Both should have no default values
    try expect(result.usages[0].default_value == null);
    try expect(result.usages[1].default_value == null);
}
