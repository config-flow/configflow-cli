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

/// External declaration for the Go parser
extern fn tree_sitter_go() *const ts.Language;

/// Go parser for discovering environment variable usage with strong type inference
pub const GoParser = struct {
    allocator: std.mem.Allocator,
    ts_parser: *ts.Parser,
    query: *ts.Query,

    const Self = @This();
    const TypeInference = struct { config_type: ConfigType, confidence: Confidence };

    pub fn init(allocator: std.mem.Allocator) !*GoParser {
        const ts_parser = ts.Parser.create();

        const language = tree_sitter_go();
        ts_parser.setLanguage(language) catch |err| {
            // Don't call destroy() here - setLanguage failure leaves parser in bad state
            return err;
        };

        // Query to find os.Getenv(), os.LookupEnv(), and viper patterns
        // Matches:
        // - os.Getenv("KEY") - standard library
        // - os.LookupEnv("KEY") - returns (value, exists bool)
        // - os.Getenv(variable) - dynamic access
        // - viper.GetString("KEY"), viper.GetInt("KEY"), etc. - viper config library
        const query_source =
            \\; Match os.Getenv("KEY")
            \\(call_expression
            \\  function: (selector_expression
            \\    operand: (identifier) @os (#eq? @os "os")
            \\    field: (field_identifier) @getenv (#eq? @getenv "Getenv"))
            \\  arguments: (argument_list
            \\    . (interpreted_string_literal) @key_string .)) @access
            \\
            \\; Match os.LookupEnv("KEY")
            \\(call_expression
            \\  function: (selector_expression
            \\    operand: (identifier) @os_lookup (#eq? @os_lookup "os")
            \\    field: (field_identifier) @lookup (#eq? @lookup "LookupEnv"))
            \\  arguments: (argument_list
            \\    . (interpreted_string_literal) @key_string_lookup .)) @access_lookup
            \\
            \\; Match os.Getenv(variable) - dynamic access
            \\(call_expression
            \\  function: (selector_expression
            \\    operand: (identifier) @os_dyn (#eq? @os_dyn "os")
            \\    field: (field_identifier) @getenv_dyn (#eq? @getenv_dyn "Getenv"))
            \\  arguments: (argument_list
            \\    . (identifier) @dynamic_key .)) @dynamic_access
            \\
            \\; Match viper.GetString("KEY"), viper.GetInt("KEY"), etc.
            \\(call_expression
            \\  function: (selector_expression
            \\    operand: (identifier) @viper (#eq? @viper "viper")
            \\    field: (field_identifier) @viper_method)
            \\  arguments: (argument_list
            \\    . (interpreted_string_literal) @viper_key .)) @viper_access
        ;

        var error_offset: u32 = 0;
        const query = ts.Query.create(language, query_source, &error_offset) catch |err| {
            ts_parser.destroy();
            return err;
        };

        const self = try allocator.create(GoParser);
        self.* = .{
            .allocator = allocator,
            .ts_parser = ts_parser,
            .query = query,
        };

        return self;
    }

    pub fn parser(self: *GoParser) Parser {
        return .{
            .ctx = self,
            .discoverFn = discover,
            .deinitFn = deinit,
        };
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *GoParser = @ptrCast(@alignCast(ctx));
        self.query.destroy();
        self.ts_parser.destroy();
        self.allocator.destroy(self);
    }

    fn discover(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        source_code: []const u8,
    ) anyerror!ParseResult {
        const self: *GoParser = @ptrCast(@alignCast(ctx));

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

    fn processMatch(
        allocator: std.mem.Allocator,
        query: *const ts.Query,
        match: ts.Query.Match,
        source_code: []const u8,
        file_path: []const u8,
        usages: *std.ArrayList(EnvVarUsage),
        warnings: *std.ArrayList(Warning),
    ) !void {
        var key_string_node: ?ts.Node = null;
        var access_node: ?ts.Node = null;
        var is_dynamic = false;
        var viper_method: ?[]const u8 = null;

        // Extract captures from match
        var os_text: ?[]const u8 = null;
        var getenv_text: ?[]const u8 = null;
        var lookup_text: ?[]const u8 = null;
        var viper_text: ?[]const u8 = null;

        for (match.captures) |capture| {
            const capture_name = query.captureNameForId(capture.index) orelse continue;

            const start = capture.node.startByte();
            const end = capture.node.endByte();
            const text = source_code[start..end];

            if (std.mem.eql(u8, capture_name, "os") or
                std.mem.eql(u8, capture_name, "os_lookup") or
                std.mem.eql(u8, capture_name, "os_dyn"))
            {
                os_text = text;
            } else if (std.mem.eql(u8, capture_name, "getenv") or
                std.mem.eql(u8, capture_name, "getenv_dyn"))
            {
                getenv_text = text;
            } else if (std.mem.eql(u8, capture_name, "lookup")) {
                lookup_text = text;
            } else if (std.mem.eql(u8, capture_name, "viper")) {
                viper_text = text;
            } else if (std.mem.eql(u8, capture_name, "viper_method")) {
                viper_method = text;
            } else if (std.mem.eql(u8, capture_name, "key_string") or
                std.mem.eql(u8, capture_name, "key_string_lookup") or
                std.mem.eql(u8, capture_name, "viper_key"))
            {
                key_string_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "access") or
                std.mem.eql(u8, capture_name, "access_lookup") or
                std.mem.eql(u8, capture_name, "viper_access"))
            {
                access_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "dynamic_key")) {
                is_dynamic = true;
            } else if (std.mem.eql(u8, capture_name, "dynamic_access")) {
                access_node = capture.node;
                is_dynamic = true;
            }
        }

        // Manual predicate checking - filter out matches that don't satisfy predicates
        if (os_text != null and getenv_text != null) {
            if (!std.mem.eql(u8, os_text.?, "os")) {
                return; // Not os.Getenv
            }
            if (!std.mem.eql(u8, getenv_text.?, "Getenv")) {
                return; // Not os.Getenv
            }
        }

        if (os_text != null and lookup_text != null) {
            if (!std.mem.eql(u8, os_text.?, "os")) {
                return; // Not os.LookupEnv
            }
            if (!std.mem.eql(u8, lookup_text.?, "LookupEnv")) {
                return; // Not os.LookupEnv
            }
        }

        if (viper_text != null) {
            if (!std.mem.eql(u8, viper_text.?, "viper")) {
                return; // Not viper
            }
        }

        const line_number = if (access_node) |node| node.startPoint().row + 1 else 1;

        // Handle dynamic access - create warning
        if (is_dynamic) {
            const warning = Warning{
                .file_path = try allocator.dupe(u8, file_path),
                .line_number = line_number,
                .message = try allocator.dupe(u8, "Dynamic environment variable access detected (variable key)"),
                .warning_type = .dynamic_access,
                .allocator = allocator,
            };
            try warnings.append(allocator, warning);
            return;
        }

        // Extract key name from string literal
        if (key_string_node) |node| {
            const start_byte = node.startByte();
            const end_byte = node.endByte();
            const key_with_quotes = source_code[start_byte..end_byte];

            // Strip quotes from Go string literal
            const key_text = if (key_with_quotes.len >= 2 and
                key_with_quotes[0] == '"' and
                key_with_quotes[key_with_quotes.len - 1] == '"')
                key_with_quotes[1 .. key_with_quotes.len - 1]
            else
                key_with_quotes;

            // Get context (the full line)
            const context = try extractContext(allocator, source_code, access_node.?);

            // Detect default value from conditional patterns
            const default_value = try detectDefaultValue(allocator, source_code, access_node.?);

            // Infer type from context
            const type_inference = if (viper_method) |method|
                inferTypeFromViperMethod(method, context)
            else
                inferTypeFromContext(context, file_path, source_code, access_node.?);

            const usage = EnvVarUsage{
                .name = try allocator.dupe(u8, key_text),
                .inferred_type = type_inference.config_type,
                .file_path = try allocator.dupe(u8, file_path),
                .line_number = line_number,
                .confidence = type_inference.confidence,
                .context = context,
                .default_value = default_value,
                .allocator = allocator,
            };

            try usages.append(allocator, usage);
        }
    }

    /// Detect default value from Go conditional patterns
    /// Handles: if val := os.Getenv("KEY"); val == "" { val = "default" }
    /// and similar patterns
    fn detectDefaultValue(
        allocator: std.mem.Allocator,
        source_code: []const u8,
        access_node: ts.Node,
    ) !?[]const u8 {
        // Walk up the tree to find an if_statement
        var current = access_node.parent();

        while (current) |node| {
            const node_type = node.kind();

            // Check for if statement
            if (std.mem.eql(u8, node_type, "if_statement")) {
                // Look for block statement (the body of the if)
                var child_cursor = node.walk();
                defer child_cursor.destroy();

                if (child_cursor.gotoFirstChild()) {
                    while (true) {
                        const child = child_cursor.node();
                        const child_type = child.kind();

                        if (std.mem.eql(u8, child_type, "block")) {
                            // Search for assignment statements in the block
                            var block_cursor = child.walk();
                            defer block_cursor.destroy();

                            if (block_cursor.gotoFirstChild()) {
                                while (true) {
                                    const block_child = block_cursor.node();
                                    const block_child_type = block_child.kind();

                                    if (std.mem.eql(u8, block_child_type, "assignment_statement") or
                                        std.mem.eql(u8, block_child_type, "short_var_declaration"))
                                    {
                                        // Extract the value being assigned
                                        const assign_start = block_child.startByte();
                                        const assign_end = block_child.endByte();
                                        const assign_text = source_code[assign_start..assign_end];

                                        // Look for string literal in assignment
                                        if (std.mem.indexOf(u8, assign_text, "\"")) |quote_pos| {
                                            const after_quote = assign_text[quote_pos..];
                                            if (std.mem.indexOf(u8, after_quote[1..], "\"")) |end_quote| {
                                                const default_text = after_quote[1 .. end_quote + 1];
                                                return try allocator.dupe(u8, default_text);
                                            }
                                        }
                                    }

                                    if (!block_cursor.gotoNextSibling()) break;
                                }
                            }
                        }

                        if (!child_cursor.gotoNextSibling()) break;
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

    /// Infer type from viper method name
    fn inferTypeFromViperMethod(
        method: []const u8,
        context: []const u8,
    ) TypeInference {
        // Viper provides strongly-typed getters
        if (std.mem.eql(u8, method, "GetInt") or
            std.mem.eql(u8, method, "GetInt32") or
            std.mem.eql(u8, method, "GetInt64") or
            std.mem.eql(u8, method, "GetUint") or
            std.mem.eql(u8, method, "GetUint32") or
            std.mem.eql(u8, method, "GetUint64"))
        {
            return .{ .config_type = .integer, .confidence = .high };
        }

        if (std.mem.eql(u8, method, "GetBool")) {
            return .{ .config_type = .boolean, .confidence = .high };
        }

        if (std.mem.eql(u8, method, "GetString")) {
            // Check context for URL/connection string patterns
            return inferTypeFromContext(context, "", "", null);
        }

        // Default for GetString, Get, etc.
        return .{ .config_type = .string, .confidence = .medium };
    }

    /// Infer type from context and Go variable declaration
    fn inferTypeFromContext(
        context: []const u8,
        file_path: []const u8,
        source_code: []const u8,
        access_node: ?ts.Node,
    ) TypeInference {
        _ = file_path;
        _ = source_code;
        _ = access_node;

        // Check for conversion functions - high confidence (case-sensitive for Go function names)
        if (std.mem.indexOf(u8, context, "strconv.Atoi") != null or
            std.mem.indexOf(u8, context, "strconv.ParseInt") != null or
            std.mem.indexOf(u8, context, "strconv.ParseUint") != null)
        {
            return .{ .config_type = .integer, .confidence = .high };
        }

        if (std.mem.indexOf(u8, context, "strconv.ParseBool") != null) {
            return .{ .config_type = .boolean, .confidence = .high };
        }

        // Check for variable type declarations - high confidence
        // var port int = os.Getenv("PORT")
        // port := os.Getenv("PORT")  (would need AST analysis for type inference)

        // Database/connection string patterns (check BEFORE generic URL patterns!)
        // This ensures DATABASE_URL, MONGO_URI, etc. are classified as connection_string
        if (indexOfIgnoreCase(context, "database") or
            indexOfIgnoreCase(context, "db") or
            indexOfIgnoreCase(context, "connection") or
            indexOfIgnoreCase(context, "dsn") or
            indexOfIgnoreCase(context, "mongo") or
            indexOfIgnoreCase(context, "redis") or
            indexOfIgnoreCase(context, "postgres") or
            indexOfIgnoreCase(context, "mysql"))
        {
            return .{ .config_type = .connection_string, .confidence = .medium };
        }

        // Check for URL/URI/endpoint patterns (generic, after connection strings)
        if (indexOfIgnoreCase(context, "url") or
            indexOfIgnoreCase(context, "uri") or
            indexOfIgnoreCase(context, "endpoint"))
        {
            return .{ .config_type = .url, .confidence = .medium };
        }

        // Secret patterns
        if (indexOfIgnoreCase(context, "secret") or
            indexOfIgnoreCase(context, "key") or
            indexOfIgnoreCase(context, "token") or
            indexOfIgnoreCase(context, "password") or
            indexOfIgnoreCase(context, "credential"))
        {
            return .{ .config_type = .secret, .confidence = .medium };
        }

        // Email patterns
        if (indexOfIgnoreCase(context, "email") or
            indexOfIgnoreCase(context, "mail"))
        {
            return .{ .config_type = .email, .confidence = .medium };
        }

        // Boolean patterns (comparison with string literals)
        if (std.mem.indexOf(u8, context, "== \"true\"") != null or
            std.mem.indexOf(u8, context, "== \"false\"") != null or
            std.mem.indexOf(u8, context, "!= \"true\"") != null or
            std.mem.indexOf(u8, context, "!= \"false\"") != null)
        {
            return .{ .config_type = .boolean, .confidence = .medium };
        }

        // Default to string with low confidence
        return .{ .config_type = .string, .confidence = .low };
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
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "GoParser init and deinit" {
    const allocator = std.testing.allocator;
    const go_parser = try GoParser.init(allocator);
    defer go_parser.parser().deinit();

    // Pointers are non-nullable, so if init succeeded they're valid
}

test "GoParser discovers os.Getenv" {
    const allocator = std.testing.allocator;
    const go_parser = try GoParser.init(allocator);
    defer go_parser.parser().deinit();

    const source =
        \\package main
        \\
        \\import "os"
        \\
        \\func main() {
        \\    apiKey := os.Getenv("API_KEY")
        \\}
    ;

    var result = try go_parser.parser().discover(allocator, "main.go", source);
    defer result.deinit();

    try expectEqual(@as(usize, 1), result.usages.len);
    try expectEqualStrings("API_KEY", result.usages[0].name);
    try expectEqual(ConfigType.secret, result.usages[0].inferred_type);
}

test "GoParser discovers os.LookupEnv" {
    const allocator = std.testing.allocator;
    const go_parser = try GoParser.init(allocator);
    defer go_parser.parser().deinit();

    const source =
        \\package main
        \\
        \\import "os"
        \\
        \\func main() {
        \\    port, exists := os.LookupEnv("PORT")
        \\    _ = exists
        \\    _ = port
        \\}
    ;

    var result = try go_parser.parser().discover(allocator, "main.go", source);
    defer result.deinit();

    try expectEqual(@as(usize, 1), result.usages.len);
    try expectEqualStrings("PORT", result.usages[0].name);
}

test "GoParser infers integer from strconv" {
    const allocator = std.testing.allocator;
    const go_parser = try GoParser.init(allocator);
    defer go_parser.parser().deinit();

    const source =
        \\package main
        \\
        \\import (
        \\    "os"
        \\    "strconv"
        \\)
        \\
        \\func main() {
        \\    port, _ := strconv.Atoi(os.Getenv("PORT"))
        \\    _ = port
        \\}
    ;

    var result = try go_parser.parser().discover(allocator, "main.go", source);
    defer result.deinit();

    try expectEqual(@as(usize, 1), result.usages.len);
    try expectEqualStrings("PORT", result.usages[0].name);
    try expectEqual(ConfigType.integer, result.usages[0].inferred_type);
    try expectEqual(Confidence.high, result.usages[0].confidence);
}

test "GoParser discovers viper patterns" {
    const allocator = std.testing.allocator;
    const go_parser = try GoParser.init(allocator);
    defer go_parser.parser().deinit();

    const source =
        \\package main
        \\
        \\import "github.com/spf13/viper"
        \\
        \\func main() {
        \\    port := viper.GetInt("PORT")
        \\    debug := viper.GetBool("DEBUG")
        \\    dbUrl := viper.GetString("DATABASE_URL")
        \\    _ = port
        \\    _ = debug
        \\    _ = dbUrl
        \\}
    ;

    var result = try go_parser.parser().discover(allocator, "main.go", source);
    defer result.deinit();

    try expectEqual(@as(usize, 3), result.usages.len);

    // Check PORT
    try expectEqualStrings("PORT", result.usages[0].name);
    try expectEqual(ConfigType.integer, result.usages[0].inferred_type);
    try expectEqual(Confidence.high, result.usages[0].confidence);

    // Check DEBUG
    try expectEqualStrings("DEBUG", result.usages[1].name);
    try expectEqual(ConfigType.boolean, result.usages[1].inferred_type);
    try expectEqual(Confidence.high, result.usages[1].confidence);

    // Check DATABASE_URL
    try expectEqualStrings("DATABASE_URL", result.usages[2].name);
    try expectEqual(ConfigType.connection_string, result.usages[2].inferred_type);
}

test "GoParser detects dynamic access" {
    const allocator = std.testing.allocator;
    const go_parser = try GoParser.init(allocator);
    defer go_parser.parser().deinit();

    const source =
        \\package main
        \\
        \\import "os"
        \\
        \\func main() {
        \\    key := "DYNAMIC_KEY"
        \\    value := os.Getenv(key)
        \\    _ = value
        \\}
    ;

    var result = try go_parser.parser().discover(allocator, "main.go", source);
    defer result.deinit();

    try expectEqual(@as(usize, 0), result.usages.len);
    try expectEqual(@as(usize, 1), result.warnings.len);
    try expectEqual(Warning.WarningType.dynamic_access, result.warnings[0].warning_type);
}

test "GoParser infers URL from context" {
    const allocator = std.testing.allocator;
    const go_parser = try GoParser.init(allocator);
    defer go_parser.parser().deinit();

    const source =
        \\package main
        \\
        \\import "os"
        \\
        \\func main() {
        \\    apiUrl := os.Getenv("API_URL")
        \\    endpoint := os.Getenv("ENDPOINT")
        \\    _ = apiUrl
        \\    _ = endpoint
        \\}
    ;

    var result = try go_parser.parser().discover(allocator, "main.go", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);

    for (result.usages) |usage| {
        try expectEqual(ConfigType.url, usage.inferred_type);
        try expectEqual(Confidence.medium, usage.confidence);
    }
}

test "GoParser infers connection string from context" {
    const allocator = std.testing.allocator;
    const go_parser = try GoParser.init(allocator);
    defer go_parser.parser().deinit();

    const source =
        \\package main
        \\
        \\import "os"
        \\
        \\func main() {
        \\    databaseUrl := os.Getenv("DATABASE_URL")
        \\    mongoUri := os.Getenv("MONGO_URI")
        \\    redisAddr := os.Getenv("REDIS_ADDR")
        \\    _ = databaseUrl
        \\    _ = mongoUri
        \\    _ = redisAddr
        \\}
    ;

    var result = try go_parser.parser().discover(allocator, "main.go", source);
    defer result.deinit();

    try expectEqual(@as(usize, 3), result.usages.len);

    for (result.usages) |usage| {
        try expectEqual(ConfigType.connection_string, usage.inferred_type);
    }
}
