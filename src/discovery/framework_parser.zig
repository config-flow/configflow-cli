const std = @import("std");
const ts = @import("tree_sitter");
const framework_config = @import("framework_config.zig");
const parser = @import("parsers/parser.zig");

const FrameworkConfig = framework_config.FrameworkConfig;
const EnvVarUsage = parser.EnvVarUsage;
const ParseResult = parser.ParseResult;
const Confidence = framework_config.Confidence;

/// Framework-specific parser that uses dynamically loaded tree-sitter queries
pub const FrameworkParser = struct {
    config: FrameworkConfig,
    allocator: std.mem.Allocator,
    language: *const ts.Language,
    compiled_queries: []CompiledQuery,

    const CompiledQuery = struct {
        query: *ts.Query,
        name: []const u8,
        key_capture_name: []const u8,
        confidence: Confidence,
    };

    /// Initialize a framework parser with a loaded config and language
    pub fn init(
        allocator: std.mem.Allocator,
        config: FrameworkConfig,
        language: *const ts.Language,
    ) !FrameworkParser {
        var compiled_queries = std.ArrayList(CompiledQuery){};
        errdefer {
            for (compiled_queries.items) |cq| {
                cq.query.destroy();
            }
            compiled_queries.deinit(allocator);
        }

        // Compile all queries from the framework config
        for (config.queries) |query_config| {
            var error_offset: u32 = 0;
            const query = ts.Query.create(language, query_config.pattern, &error_offset) catch |err| {
                std.debug.print("Failed to compile query '{s}' at offset {d}: {}\n", .{ query_config.name, error_offset, err });
                return err;
            };
            errdefer query.destroy();

            try compiled_queries.append(allocator, .{
                .query = query,
                .name = query_config.name,
                .key_capture_name = query_config.key_capture,
                .confidence = query_config.confidence,
            });
        }

        return FrameworkParser{
            .config = config,
            .allocator = allocator,
            .language = language,
            .compiled_queries = try compiled_queries.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *FrameworkParser) void {
        for (self.compiled_queries) |cq| {
            cq.query.destroy();
        }
        self.allocator.free(self.compiled_queries);
    }

    /// Parse source code and detect environment variable usages
    pub fn parse(self: *FrameworkParser, source_code: []const u8) !ParseResult {
        // Create a tree-sitter parser
        const ts_parser = ts.Parser.create();
        defer ts_parser.destroy();

        try ts_parser.setLanguage(self.language);

        // Parse the source code
        const tree = ts_parser.parseStringEncoding(source_code, null, .utf8) orelse {
            return error.ParseFailed;
        };
        defer tree.destroy();

        const root_node = tree.rootNode();

        var usages = std.ArrayList(EnvVarUsage){};
        errdefer {
            for (usages.items) |*usage| {
                usage.deinit();
            }
            usages.deinit(self.allocator);
        }

        // Run each compiled query
        for (self.compiled_queries) |cq| {
            try self.executeQuery(source_code, root_node, cq, &usages);
        }

        return ParseResult{
            .usages = try usages.toOwnedSlice(self.allocator),
            .warnings = &.{}, // Framework parsers don't generate warnings currently
            .allocator = self.allocator,
        };
    }

    fn executeQuery(
        self: *FrameworkParser,
        source_code: []const u8,
        root_node: ts.Node,
        compiled_query: CompiledQuery,
        usages: *std.ArrayList(EnvVarUsage),
    ) !void {
        const qc = ts.QueryCursor.create();
        defer qc.destroy();

        qc.exec(compiled_query.query, root_node);

        while (qc.nextMatch()) |match| {
            var key_node: ?ts.Node = null;
            var access_node: ?ts.Node = null;

            // Find the key and access captures in this match
            for (match.captures) |capture| {
                const capture_name = compiled_query.query.captureNameForId(capture.index) orelse continue;

                if (std.mem.eql(u8, capture_name, compiled_query.key_capture_name)) {
                    key_node = capture.node;
                } else if (std.mem.eql(u8, capture_name, "access")) {
                    access_node = capture.node;
                }
            }

            if (key_node) |knode| {
                const start_byte = knode.startByte();
                const end_byte = knode.endByte();
                var key = source_code[start_byte..end_byte];

                // Strip quotes if present (handles "KEY" and 'KEY' patterns)
                if (key.len >= 2) {
                    if ((key[0] == '"' and key[key.len - 1] == '"') or
                        (key[0] == '\'' and key[key.len - 1] == '\''))
                    {
                        key = key[1 .. key.len - 1];
                    }
                }

                // Get location information
                const location = if (access_node) |anode|
                    anode.startPoint()
                else
                    knode.startPoint();

                // Determine confidence level
                const confidence_level: parser.Confidence = switch (compiled_query.confidence) {
                    .high => .high,
                    .medium => .medium,
                    .low => .low,
                };

                try usages.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, key),
                    .inferred_type = .string, // Default type, will be inferred later
                    .file_path = try self.allocator.dupe(u8, ""),
                    .line_number = location.row + 1,
                    .confidence = confidence_level,
                    .context = null,
                    .default_value = null,
                    .allocator = self.allocator,
                });
            }
        }
    }
};

// Tests
const testing = std.testing;

// External language parsers
extern fn tree_sitter_javascript() *const ts.Language;

test "FrameworkParser compiles and executes NestJS queries" {
    const allocator = testing.allocator;

    // Create a simple NestJS framework config
    const yaml_content =
        \\name: "NestJS"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test config"
        \\
        \\detection:
        \\  files:
        \\    - "package.json"
        \\  patterns:
        \\    package_json: "@nestjs/core"
        \\
        \\queries:
        \\  - name: "ConfigService.get() calls"
        \\    description: "Matches configService.get('KEY')"
        \\    pattern: "(call_expression function: (member_expression property: (property_identifier) @get (#eq? @get \"get\")) arguments: (arguments . (string) @key_string)) @access"
        \\    key_capture: "key_string"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern:
        \\    - pattern: "(?i)port"
        \\      type: "integer"
        \\      confidence: "high"
    ;

    var config = try framework_config.loadFromContent(allocator, yaml_content);
    defer config.deinit();

    // Initialize framework parser
    const language = tree_sitter_javascript();
    var fw_parser = try FrameworkParser.init(allocator, config, language);
    defer fw_parser.deinit();

    // Test source code
    const source =
        \\const port = this.configService.get('PORT');
        \\const dbUrl = configService.get('DATABASE_URL');
    ;

    // Parse
    var result = try fw_parser.parse(source);
    defer result.deinit();

    // Should find both env vars
    try testing.expectEqual(@as(usize, 2), result.usages.len);
    try testing.expectEqualStrings("PORT", result.usages[0].name);
    try testing.expectEqualStrings("DATABASE_URL", result.usages[1].name);
}

test "FrameworkParser handles empty source code" {
    const allocator = testing.allocator;

    const yaml_content =
        \\name: "Test"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test empty source"
        \\
        \\detection:
        \\  files:
        \\    - "test.js"
        \\  patterns:
        \\    test: "test"
        \\
        \\queries:
        \\  - name: "Test query"
        \\    description: "Test"
        \\    pattern: "(call_expression) @access"
        \\    key_capture: "access"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern: []
    ;

    var config = try framework_config.loadFromContent(allocator, yaml_content);
    defer config.deinit();

    const language = tree_sitter_javascript();
    var fw_parser = try FrameworkParser.init(allocator, config, language);
    defer fw_parser.deinit();

    const empty_source = "";
    var result = try fw_parser.parse(empty_source);
    defer result.deinit();

    // Should find no usages in empty source
    try testing.expectEqual(@as(usize, 0), result.usages.len);
}

test "FrameworkParser handles source with no matches" {
    const allocator = testing.allocator;

    const yaml_content =
        \\name: "Test"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test no matches"
        \\
        \\detection:
        \\  files:
        \\    - "test.js"
        \\  patterns:
        \\    test: "test"
        \\
        \\queries:
        \\  - name: "ConfigService.get() calls"
        \\    description: "Matches configService.get('KEY')"
        \\    pattern: "(call_expression function: (member_expression property: (property_identifier) @get (#eq? @get \"get\")) arguments: (arguments . (string) @key_string)) @access"
        \\    key_capture: "key_string"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern: []
    ;

    var config = try framework_config.loadFromContent(allocator, yaml_content);
    defer config.deinit();

    const language = tree_sitter_javascript();
    var fw_parser = try FrameworkParser.init(allocator, config, language);
    defer fw_parser.deinit();

    // Source that doesn't match the pattern (no .get() calls)
    const source =
        \\const x = 42;
        \\const y = "hello";
        \\const z = x + 1;
    ;

    var result = try fw_parser.parse(source);
    defer result.deinit();

    // Should find no usages
    try testing.expectEqual(@as(usize, 0), result.usages.len);
}

test "FrameworkParser respects confidence levels" {
    const allocator = testing.allocator;

    const yaml_content =
        \\name: "Test"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test confidence levels"
        \\
        \\detection:
        \\  files:
        \\    - "test.js"
        \\  patterns:
        \\    test: "test"
        \\
        \\queries:
        \\  - name: "High confidence"
        \\    description: "High"
        \\    pattern: "(string (string_fragment) @key1) @access1"
        \\    key_capture: "key1"
        \\    confidence: "high"
        \\  - name: "Medium confidence"
        \\    description: "Medium"
        \\    pattern: "(identifier) @key2 @access2"
        \\    key_capture: "key2"
        \\    confidence: "medium"
        \\  - name: "Low confidence"
        \\    description: "Low"
        \\    pattern: "(number) @key3 @access3"
        \\    key_capture: "key3"
        \\    confidence: "low"
        \\
        \\type_inference:
        \\  by_name_pattern: []
    ;

    var config = try framework_config.loadFromContent(allocator, yaml_content);
    defer config.deinit();

    const language = tree_sitter_javascript();
    var fw_parser = try FrameworkParser.init(allocator, config, language);
    defer fw_parser.deinit();

    const source =
        \\const x = "test";
        \\const y = foo;
        \\const z = 42;
    ;

    var result = try fw_parser.parse(source);
    defer result.deinit();

    // Should find matches with different confidence levels
    try testing.expect(result.usages.len > 0);

    // Verify at least one high confidence match exists
    var found_high = false;
    for (result.usages) |usage| {
        if (usage.confidence == parser.Confidence.high) {
            found_high = true;
            break;
        }
    }
    try testing.expect(found_high);
}

test "FrameworkParser handles multiple queries" {
    const allocator = testing.allocator;

    const yaml_content =
        \\name: "Test"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test multiple queries"
        \\
        \\detection:
        \\  files:
        \\    - "test.js"
        \\  patterns:
        \\    test: "test"
        \\
        \\queries:
        \\  - name: "First pattern"
        \\    description: "Matches strings"
        \\    pattern: "(call_expression function: (identifier) @func (#eq? @func \"getenv\") arguments: (arguments (string) @key_string)) @access"
        \\    key_capture: "key_string"
        \\    confidence: "high"
        \\  - name: "Second pattern"
        \\    description: "Matches member expressions"
        \\    pattern: "(call_expression function: (member_expression property: (property_identifier) @prop (#eq? @prop \"get\")) arguments: (arguments (string) @key_string)) @access"
        \\    key_capture: "key_string"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern: []
    ;

    var config = try framework_config.loadFromContent(allocator, yaml_content);
    defer config.deinit();

    const language = tree_sitter_javascript();
    var fw_parser = try FrameworkParser.init(allocator, config, language);
    defer fw_parser.deinit();

    const source =
        \\const a = getenv("VAR1");
        \\const b = config.get("VAR2");
    ;

    var result = try fw_parser.parse(source);
    defer result.deinit();

    // Should find matches from both queries
    try testing.expectEqual(@as(usize, 2), result.usages.len);
}

test "FrameworkParser strips quotes from keys" {
    const allocator = testing.allocator;

    const yaml_content =
        \\name: "Test"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test quote stripping"
        \\
        \\detection:
        \\  files:
        \\    - "test.js"
        \\  patterns:
        \\    test: "test"
        \\
        \\queries:
        \\  - name: "Test"
        \\    description: "Test"
        \\    pattern: "(string) @key_string @access"
        \\    key_capture: "key_string"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern: []
    ;

    var config = try framework_config.loadFromContent(allocator, yaml_content);
    defer config.deinit();

    const language = tree_sitter_javascript();
    var fw_parser = try FrameworkParser.init(allocator, config, language);
    defer fw_parser.deinit();

    const source =
        \\"DOUBLE_QUOTED"
        \\'SINGLE_QUOTED'
    ;

    var result = try fw_parser.parse(source);
    defer result.deinit();

    // Should find both strings with quotes stripped
    try testing.expectEqual(@as(usize, 2), result.usages.len);

    // Verify quotes are stripped
    for (result.usages) |usage| {
        try testing.expect(usage.name[0] != '"');
        try testing.expect(usage.name[0] != '\'');
        try testing.expect(usage.name[usage.name.len - 1] != '"');
        try testing.expect(usage.name[usage.name.len - 1] != '\'');
    }
}
