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

/// External declaration for the Ruby parser
extern fn tree_sitter_ruby() *const ts.Language;

/// Ruby parser for discovering environment variable usage
pub const RubyParser = struct {
    allocator: std.mem.Allocator,
    ts_parser: *ts.Parser,
    query: *ts.Query,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*RubyParser {
        const ts_parser = ts.Parser.create();
        errdefer ts_parser.destroy();

        const language = tree_sitter_ruby();
        try ts_parser.setLanguage(language);

        // Query to find ENV accesses in Ruby
        // Matches:
        // - ENV['KEY'] or ENV["KEY"] (element_reference with string)
        // - ENV[variable] (element_reference with identifier - dynamic)
        // - ENV.fetch('KEY') or ENV.fetch('KEY', default) (call with ENV as receiver)
        const query_source =
            \\; Match ENV['KEY'] or ENV["KEY"]
            \\(element_reference
            \\  object: (constant) @env (#eq? @env "ENV")
            \\  (string
            \\    (string_content) @key_content)) @access
            \\
            \\; Match ENV[variable] - dynamic access
            \\(element_reference
            \\  object: (constant) @env (#eq? @env "ENV")
            \\  (identifier) @dynamic_key) @dynamic_access
            \\
            \\; Match ENV.fetch('KEY') or ENV.fetch('KEY', default)
            \\(call
            \\  receiver: (constant) @env (#eq? @env "ENV")
            \\  method: (identifier) @fetch (#eq? @fetch "fetch")
            \\  arguments: (argument_list
            \\    (string
            \\      (string_content) @key_content)
            \\    (_)? @default_arg)) @access
        ;

        var error_offset: u32 = 0;
        const query = ts.Query.create(language, query_source, &error_offset) catch |err| {
            ts_parser.destroy();
            return err;
        };

        const self = try allocator.create(RubyParser);
        self.* = .{
            .allocator = allocator,
            .ts_parser = ts_parser,
            .query = query,
        };

        return self;
    }

    pub fn parser(self: *RubyParser) Parser {
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
        const self: *RubyParser = @ptrCast(@alignCast(ctx));

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

        // Track interpolated strings we've already warned about (by line number)
        var warned_lines = std.AutoHashMap(usize, void).init(allocator);
        defer warned_lines.deinit();

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
                &warned_lines,
            );
        }

        return ParseResult{
            .usages = try usages.toOwnedSlice(allocator),
            .warnings = try warnings.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *RubyParser = @ptrCast(@alignCast(ctx));
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
        warned_lines: *std.AutoHashMap(usize, void),
    ) !void {
        var key_node: ?ts.Node = null;
        var access_node: ?ts.Node = null;
        var default_arg_node: ?ts.Node = null;
        var is_dynamic = false;

        // Extract captures from match
        for (match.captures) |capture| {
            const capture_name = query.captureNameForId(capture.index) orelse continue;

            if (std.mem.eql(u8, capture_name, "key_content")) {
                key_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "access")) {
                access_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "default_arg")) {
                default_arg_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "dynamic_key")) {
                is_dynamic = true;
                key_node = capture.node; // Store the identifier for potential future use
            } else if (std.mem.eql(u8, capture_name, "dynamic_access")) {
                access_node = capture.node; // The full element_reference expression
            }
        }

        if (access_node == null) return;

        // Validate that this is actually an ENV access
        // Tree-sitter query predicates don't always filter correctly, so we do additional validation
        const access_start = access_node.?.startByte();
        const access_end = access_node.?.endByte();
        const access_text = source_code[access_start..access_end];

        // Check if the access starts with "ENV" (not just any constant)
        // This filters out false matches like MY_HASH['key'] or CONFIG.fetch('value')
        if (!std.mem.startsWith(u8, access_text, "ENV")) {
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

        // Extract key name from string_content node
        if (key_node) |node| {
            // Check if the string contains interpolation
            // If the string has multiple children (string_content + interpolation), it's dynamic
            const parent_node = node.parent();
            if (parent_node) |parent| {
                // Check if parent is a string node
                const node_type = parent.kind();
                if (std.mem.eql(u8, node_type, "string")) {
                    // Count the children - if > 1, there's interpolation
                    var child_count: u32 = 0;
                    var has_interpolation = false;

                    var cursor = parent.walk();
                    defer cursor.destroy();

                    if (cursor.gotoFirstChild()) {
                        child_count += 1;
                        const first_child_type = cursor.node().kind();
                        if (std.mem.eql(u8, first_child_type, "interpolation")) {
                            has_interpolation = true;
                        }

                        while (cursor.gotoNextSibling()) {
                            child_count += 1;
                            const child_type = cursor.node().kind();
                            if (std.mem.eql(u8, child_type, "interpolation")) {
                                has_interpolation = true;
                            }
                        }
                    }

                    // If string has interpolation, treat as dynamic access
                    if (has_interpolation) {
                        // Only warn once per line (avoid duplicate warnings for multiple string_content fragments)
                        const result = try warned_lines.getOrPut(line_number);
                        if (!result.found_existing) {
                            const warning = Warning{
                                .file_path = try allocator.dupe(u8, file_path),
                                .line_number = line_number,
                                .message = try allocator.dupe(u8, "Dynamic environment variable access detected (string interpolation)"),
                                .warning_type = .dynamic_access,
                                .allocator = allocator,
                            };
                            try warnings.append(allocator, warning);
                        }
                        return;
                    }
                }
            }

            const start_byte = node.startByte();
            const end_byte = node.endByte();
            const key_text = source_code[start_byte..end_byte];

            // Get context (the full line)
            const context = try extractContext(allocator, source_code, access_node.?);

            // Detect default value (from function argument or '||' operator)
            var default_value: ?[]const u8 = null;

            // First check for default value in function argument (ENV.fetch("KEY", "default"))
            if (default_arg_node) |def_node| {
                const def_start = def_node.startByte();
                const def_end = def_node.endByte();
                var def_text = source_code[def_start..def_end];

                // Remove quotes from string literals
                def_text = std.mem.trim(u8, def_text, " \t");
                if (def_text.len >= 2) {
                    if ((def_text[0] == '"' or def_text[0] == '\'') and
                        def_text[def_text.len - 1] == def_text[0])
                    {
                        def_text = def_text[1 .. def_text.len - 1];
                    }
                }

                default_value = try allocator.dupe(u8, def_text);
            }

            // Also check for '||' operator pattern (ENV['KEY'] || "default")
            if (default_value == null) {
                default_value = try detectOrOperatorDefault(allocator, source_code, access_node.?);
            }

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

    /// Detect default value from '||' operator pattern
    /// Handles: ENV['KEY'] || "default"
    fn detectOrOperatorDefault(
        allocator: std.mem.Allocator,
        source_code: []const u8,
        access_node: ts.Node,
    ) !?[]const u8 {
        // Walk up the tree to find a binary node with '||' operator
        var current = access_node.parent();

        while (current) |node| {
            const node_type = node.kind();

            // In Ruby's tree-sitter grammar, '||' is a binary node
            if (std.mem.eql(u8, node_type, "binary")) {
                // Check if this is an '||' operator
                const op_start = node.startByte();
                const op_end = node.endByte();
                const op_text = source_code[op_start..op_end];

                if (std.mem.indexOf(u8, op_text, "||") == null) {
                    current = node.parent();
                    continue;
                }

                // Get the left and right children using field names
                const left_child = node.childByFieldName("left");
                const right_child = node.childByFieldName("right");

                // Check if our access_node is the left child
                if (left_child) |left| {
                    if (left.startByte() == access_node.startByte() and
                        left.endByte() == access_node.endByte())
                    {
                        // Extract default value from right child
                        if (right_child) |right| {
                            const right_start = right.startByte();
                            const right_end = right.endByte();
                            var default_text = source_code[right_start..right_end];

                            // Remove quotes from string literals
                            default_text = std.mem.trim(u8, default_text, " \t");
                            if (default_text.len >= 2) {
                                if ((default_text[0] == '"' or default_text[0] == '\'') and
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

            current = node.parent();
        }

        return null;
    }

    /// Extract context (surrounding code) for an env var access
    fn extractContext(
        allocator: std.mem.Allocator,
        source_code: []const u8,
        node: ts.Node,
    ) ![]const u8 {
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

        // Extract and trim the line
        const line = source_code[line_start..line_end];
        return try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r"));
    }

    /// Case-insensitive indexOf helper
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

    /// Case-insensitive startsWith helper
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
            // .to_i -> integer
            if (std.mem.indexOf(u8, ctx, ".to_i") != null) {
                return .{ .type = .integer, .confidence = .high };
            }

            // == 'true', == 'false' -> boolean
            if (std.mem.indexOf(u8, ctx, "== 'true'") != null or
                std.mem.indexOf(u8, ctx, "== 'false'") != null or
                std.mem.indexOf(u8, ctx, "== true") != null or
                std.mem.indexOf(u8, ctx, "== false") != null)
            {
                return .{ .type = .boolean, .confidence = .medium };
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

test "RubyParser init and deinit" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    // Pointers are non-nullable, so if init succeeded they're valid
}

test "RubyParser discovers ENV['KEY']" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\port = ENV['PORT']
        \\api_key = ENV["API_KEY"]
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    try expectEqualStrings("PORT", result.usages[0].name);
    try expectEqualStrings("API_KEY", result.usages[1].name);
}

test "RubyParser discovers ENV.fetch()" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\db_url = ENV.fetch('DATABASE_URL')
        \\host = ENV.fetch("HOST")
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    try expectEqualStrings("DATABASE_URL", result.usages[0].name);
    try expectEqualStrings("HOST", result.usages[1].name);
}

test "RubyParser infers types from .to_i" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\port = ENV['PORT'].to_i
        \\timeout = ENV.fetch('TIMEOUT').to_i
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    try expectEqual(ConfigType.integer, result.usages[0].inferred_type);
    try expectEqual(Confidence.high, result.usages[0].confidence);

    try expectEqual(ConfigType.integer, result.usages[1].inferred_type);
    try expectEqual(Confidence.high, result.usages[1].confidence);
}

test "RubyParser infers boolean from comparison" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\debug = ENV['DEBUG'] == 'true'
        \\enabled = ENV.fetch('ENABLED') == true
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    try expectEqual(ConfigType.boolean, result.usages[0].inferred_type);
    try expectEqual(ConfigType.boolean, result.usages[1].inferred_type);
}

test "RubyParser warns on dynamic access" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\key = 'API_KEY'
        \\value = ENV[key]
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    try expectEqual(@as(usize, 0), result.usages.len);
    try expectEqual(@as(usize, 1), result.warnings.len);

    try expectEqual(Warning.WarningType.dynamic_access, result.warnings[0].warning_type);
}

test "RubyParser infers URL type" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\api_url = ENV['API_URL']
        \\endpoint = ENV['ENDPOINT']
        \\host = ENV['HOST']
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    try expectEqual(@as(usize, 3), result.usages.len);

    for (result.usages) |usage| {
        try expectEqual(ConfigType.url, usage.inferred_type);
        try expectEqual(Confidence.medium, usage.confidence);
    }
}

test "RubyParser filters out false matches" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\# Real ENV access - should match
        \\port = ENV['PORT']
        \\
        \\# False matches - should NOT match
        \\my_hash = { 'PORT' => '3000' }
        \\fake1 = my_hash['PORT']
        \\config = CONFIG.fetch('VALUE')
        \\str = "ENV['PORT']"
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    // Should only find the real ENV['PORT'], not the false matches
    try expectEqual(@as(usize, 1), result.usages.len);
    try expectEqualStrings("PORT", result.usages[0].name);
}

test "RubyParser recognizes URI patterns for connection strings" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\mongo = ENV['MONGODB_URI']
        \\db = ENV.fetch('DATABASE_URI')
        \\redis = ENV["REDIS_URI"]
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    try expectEqual(@as(usize, 3), result.usages.len);

    // All should be inferred as connection_string
    for (result.usages) |usage| {
        try expectEqual(ConfigType.connection_string, usage.inferred_type);
        try expectEqual(Confidence.medium, usage.confidence);
    }
}

test "RubyParser detects string interpolation as dynamic access" {
    const allocator = std.testing.allocator;
    const ruby_parser = try RubyParser.init(allocator);
    defer ruby_parser.parser().deinit();

    const source =
        \\queue_name = "default"
        \\# String interpolation should be treated as dynamic
        \\hostname = ENV["UNICORN_SIDEKIQ_#{queue_name.upcase}_QUEUE_HOSTNAME"]
        \\prefix = ENV["#{prefix}_API_KEY"]
        \\
        \\# Static strings should still work
        \\port = ENV['PORT']
    ;

    var result = try ruby_parser.parser().discover(allocator, "test.rb", source);
    defer result.deinit();

    // Should find only the static PORT access
    try expectEqual(@as(usize, 1), result.usages.len);
    try expectEqualStrings("PORT", result.usages[0].name);

    // Should have warnings for the interpolated strings
    try expectEqual(@as(usize, 2), result.warnings.len);
    for (result.warnings) |warning| {
        try expectEqual(Warning.WarningType.dynamic_access, warning.warning_type);
    }
}
