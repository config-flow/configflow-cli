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

/// External declaration for the Java parser
extern fn tree_sitter_java() *const ts.Language;

/// Java parser for discovering environment variable usage with strong type inference
pub const JavaParser = struct {
    allocator: std.mem.Allocator,
    ts_parser: *ts.Parser,
    query: *ts.Query,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*JavaParser {
        const ts_parser = ts.Parser.create();

        const language = tree_sitter_java();
        ts_parser.setLanguage(language) catch |err| {
            // Don't call destroy() here - setLanguage failure leaves parser in bad state
            return err;
        };

        // Query to find System.getenv() calls and @Value annotations
        // Matches:
        // - System.getenv("KEY") - static method invocation
        // - System.getenv(variable) - dynamic access
        // - @Value("${KEY}") or @Value("${KEY:default}") - Spring annotation
        const query_source =
            \\; Match System.getenv("KEY")
            \\(method_invocation
            \\  object: (identifier) @system (#eq? @system "System")
            \\  name: (identifier) @getenv (#eq? @getenv "getenv")
            \\  arguments: (argument_list
            \\    . (string_literal) @key_string .)) @access
            \\
            \\; Match System.getenv(variable) - dynamic access
            \\(method_invocation
            \\  object: (identifier) @system (#eq? @system "System")
            \\  name: (identifier) @getenv (#eq? @getenv "getenv")
            \\  arguments: (argument_list
            \\    . (identifier) @dynamic_key .)) @dynamic_access
            \\
            \\; Match @Value("${ENV_VAR}") or @Value("${KEY:default}") - Spring annotation
            \\(annotation
            \\  name: (identifier) @value_annotation (#eq? @value_annotation "Value")
            \\  arguments: (annotation_argument_list
            \\    (string_literal) @value_string)) @annotation_access
        ;

        var error_offset: u32 = 0;
        const query = ts.Query.create(language, query_source, &error_offset) catch |err| {
            ts_parser.destroy();
            return err;
        };

        const self = try allocator.create(JavaParser);
        self.* = .{
            .allocator = allocator,
            .ts_parser = ts_parser,
            .query = query,
        };

        return self;
    }

    pub fn parser(self: *JavaParser) Parser {
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
        const self: *JavaParser = @ptrCast(@alignCast(ctx));

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
        const self: *JavaParser = @ptrCast(@alignCast(ctx));
        self.query.destroy();
        self.ts_parser.destroy();
        self.allocator.destroy(self);
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
        var value_string_node: ?ts.Node = null;
        var access_node: ?ts.Node = null;
        var is_dynamic = false;
        var is_annotation = false;

        // Extract captures from match
        var system_text: ?[]const u8 = null;
        var getenv_text: ?[]const u8 = null;
        var value_annotation_text: ?[]const u8 = null;

        for (match.captures) |capture| {
            const capture_name = query.captureNameForId(capture.index) orelse continue;

            const start = capture.node.startByte();
            const end = capture.node.endByte();
            const text = source_code[start..end];

            if (std.mem.eql(u8, capture_name, "system")) {
                system_text = text;
            } else if (std.mem.eql(u8, capture_name, "getenv")) {
                getenv_text = text;
            } else if (std.mem.eql(u8, capture_name, "value_annotation")) {
                value_annotation_text = text;
            } else if (std.mem.eql(u8, capture_name, "key_string")) {
                key_string_node = capture.node;
            } else if (std.mem.eql(u8, capture_name, "value_string")) {
                value_string_node = capture.node;
                is_annotation = true;
            } else if (std.mem.eql(u8, capture_name, "access") or
                std.mem.eql(u8, capture_name, "annotation_access"))
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
        if (system_text != null or getenv_text != null) {
            if (system_text == null or !std.mem.eql(u8, system_text.?, "System")) {
                return; // Not System.getenv
            }
            if (getenv_text == null or !std.mem.eql(u8, getenv_text.?, "getenv")) {
                return; // Not System.getenv
            }
        }

        if (value_annotation_text != null) {
            if (!std.mem.eql(u8, value_annotation_text.?, "Value")) {
                return; // Not @Value annotation
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

        // Handle Spring @Value annotation
        if (is_annotation and value_string_node != null) {
            const node = value_string_node.?;
            const start_byte = node.startByte();
            const end_byte = node.endByte();
            const value_text = source_code[start_byte..end_byte];

            // Extract environment variable from ${ENV_VAR} or ${ENV_VAR:default}
            const env_var = try extractSpringEnvVar(allocator, value_text) orelse return;
            defer {
                allocator.free(env_var.key);
                if (env_var.default_value) |dv| {
                    allocator.free(dv);
                }
            }

            // Get context
            const context = try extractContext(allocator, source_code, access_node.?);

            // For @Value annotations, try to get type from the annotated field
            const inferred = try inferTypeFromAnnotation(allocator, source_code, access_node.?, context);

            const usage = EnvVarUsage{
                .name = try allocator.dupe(u8, env_var.key),
                .inferred_type = inferred.config_type,
                .confidence = inferred.confidence,
                .file_path = try allocator.dupe(u8, file_path),
                .line_number = line_number,
                .context = context,
                .default_value = if (env_var.default_value) |dv| try allocator.dupe(u8, dv) else null,
                .allocator = allocator,
            };
            try usages.append(allocator, usage);
            return;
        }

        // Handle System.getenv() calls
        if (key_string_node) |node| {
            const start_byte = node.startByte();
            const end_byte = node.endByte();
            var key_text = source_code[start_byte..end_byte];

            // Remove quotes from string literal
            if (key_text.len >= 2 and key_text[0] == '"' and key_text[key_text.len - 1] == '"') {
                key_text = key_text[1 .. key_text.len - 1];
            }

            // Get context
            const context = try extractContext(allocator, source_code, access_node.?);

            // Detect default value from ternary operator pattern
            const default_value = try detectTernaryDefault(allocator, source_code, access_node.?);

            // Infer type from declaration (variable/field type) with high confidence
            const inferred = try inferTypeFromDeclaration(allocator, source_code, access_node.?, context);

            const usage = EnvVarUsage{
                .name = try allocator.dupe(u8, key_text),
                .inferred_type = inferred.config_type,
                .confidence = inferred.confidence,
                .file_path = try allocator.dupe(u8, file_path),
                .line_number = line_number,
                .context = context,
                .default_value = default_value,
                .allocator = allocator,
            };
            try usages.append(allocator, usage);
        }
    }

    /// Detect default value from ternary operator pattern
    /// Handles: System.getenv("KEY") != null ? System.getenv("KEY") : "default"
    fn detectTernaryDefault(
        allocator: std.mem.Allocator,
        source_code: []const u8,
        access_node: ts.Node,
    ) !?[]const u8 {
        // Walk up the tree to find a ternary_expression
        var current = access_node.parent();

        while (current) |node| {
            const node_type = node.kind();

            if (std.mem.eql(u8, node_type, "ternary_expression")) {
                // Get the alternative (false branch)
                const alternative_child = node.childByFieldName("alternative");
                if (alternative_child) |alternative| {
                    const alt_start = alternative.startByte();
                    const alt_end = alternative.endByte();
                    var default_text = source_code[alt_start..alt_end];

                    // Remove quotes from string literals
                    default_text = std.mem.trim(u8, default_text, " \t");
                    if (default_text.len >= 2 and default_text[0] == '"' and default_text[default_text.len - 1] == '"') {
                        default_text = default_text[1 .. default_text.len - 1];
                    }

                    return try allocator.dupe(u8, default_text);
                }
            }

            current = node.parent();
        }

        return null;
    }

    const SpringEnvVar = struct {
        key: []const u8,
        default_value: ?[]const u8,
    };

    /// Extract environment variable name and default value from Spring ${ENV_VAR} or ${ENV_VAR:default} pattern
    fn extractSpringEnvVar(allocator: std.mem.Allocator, value_text: []const u8) !?SpringEnvVar {
        // Remove surrounding quotes
        var text = value_text;
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            text = text[1 .. text.len - 1];
        }

        // Find ${...} pattern
        const start_idx = std.mem.indexOf(u8, text, "${") orelse return null;
        const end_idx = std.mem.indexOf(u8, text[start_idx..], "}") orelse return null;

        const content = text[start_idx + 2 .. start_idx + end_idx];

        // Check for default value separator ":"
        if (std.mem.indexOf(u8, content, ":")) |colon_idx| {
            const key = try allocator.dupe(u8, content[0..colon_idx]);
            const default_value = try allocator.dupe(u8, content[colon_idx + 1 ..]);
            return SpringEnvVar{
                .key = key,
                .default_value = default_value,
            };
        }

        return SpringEnvVar{
            .key = try allocator.dupe(u8, content),
            .default_value = null,
        };
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

    const TypeInference = struct {
        config_type: ConfigType,
        confidence: Confidence,
    };

    /// Infer type from variable/field declaration using static type information
    fn inferTypeFromDeclaration(
        allocator: std.mem.Allocator,
        source_code: []const u8,
        node: ts.Node,
        context: []const u8,
    ) !TypeInference {
        _ = allocator;

        // Walk up the AST to find the parent declaration
        var current = node.parent();
        while (current) |parent| : (current = parent.parent()) {
            const node_type = parent.kind();

            // Check for local_variable_declaration or field_declaration
            if (std.mem.eql(u8, node_type, "local_variable_declaration") or
                std.mem.eql(u8, node_type, "field_declaration"))
            {
                // Find the type node
                if (findChildByType(parent, "type_identifier")) |type_node| {
                    const type_name = getNodeText(source_code, type_node);
                    return inferFromJavaType(type_name);
                } else if (findChildByType(parent, "integral_type")) |type_node| {
                    const type_name = getNodeText(source_code, type_node);
                    return inferFromJavaType(type_name);
                } else if (findChildByType(parent, "floating_point_type")) |type_node| {
                    const type_name = getNodeText(source_code, type_node);
                    return inferFromJavaType(type_name);
                } else if (findChildByType(parent, "boolean_type")) |_| {
                    return .{ .config_type = .boolean, .confidence = .high };
                }
            }
        }

        // Fallback to context-based inference (lower confidence)
        return inferFromContext(context);
    }

    /// Infer type from Spring @Value annotation by finding the annotated field
    fn inferTypeFromAnnotation(
        allocator: std.mem.Allocator,
        source_code: []const u8,
        node: ts.Node,
        context: []const u8,
    ) !TypeInference {
        _ = allocator;

        // The annotation node should be a child of a field_declaration or method parameter
        var current = node.parent();
        while (current) |parent| : (current = parent.parent()) {
            const node_type = parent.kind();

            if (std.mem.eql(u8, node_type, "field_declaration")) {
                // Find the type of the field
                if (findChildByType(parent, "type_identifier")) |type_node| {
                    const type_name = getNodeText(source_code, type_node);
                    return inferFromJavaType(type_name);
                } else if (findChildByType(parent, "integral_type")) |type_node| {
                    const type_name = getNodeText(source_code, type_node);
                    return inferFromJavaType(type_name);
                } else if (findChildByType(parent, "floating_point_type")) |type_node| {
                    const type_name = getNodeText(source_code, type_node);
                    return inferFromJavaType(type_name);
                } else if (findChildByType(parent, "boolean_type")) |_| {
                    return .{ .config_type = .boolean, .confidence = .high };
                }
            }
        }

        // Fallback to context-based inference
        return inferFromContext(context);
    }

    /// Find a child node by its type
    fn findChildByType(parent: ts.Node, target_type: []const u8) ?ts.Node {
        var cursor = parent.walk();
        defer cursor.destroy();

        if (!cursor.gotoFirstChild()) return null;

        // Check first child
        if (std.mem.eql(u8, cursor.node().kind(), target_type)) {
            return cursor.node();
        }

        // Check siblings
        while (cursor.gotoNextSibling()) {
            if (std.mem.eql(u8, cursor.node().kind(), target_type)) {
                return cursor.node();
            }
        }

        return null;
    }

    /// Get the text content of a node
    fn getNodeText(source_code: []const u8, node: ts.Node) []const u8 {
        const start_byte = node.startByte();
        const end_byte = node.endByte();
        return source_code[start_byte..end_byte];
    }

    /// Map Java type names to ConfigType with high confidence
    fn inferFromJavaType(type_name: []const u8) TypeInference {
        // Primitive types - high confidence
        if (std.mem.eql(u8, type_name, "int") or
            std.mem.eql(u8, type_name, "Integer") or
            std.mem.eql(u8, type_name, "long") or
            std.mem.eql(u8, type_name, "Long") or
            std.mem.eql(u8, type_name, "short") or
            std.mem.eql(u8, type_name, "Short"))
        {
            return .{ .config_type = .integer, .confidence = .high };
        }

        if (std.mem.eql(u8, type_name, "boolean") or
            std.mem.eql(u8, type_name, "Boolean"))
        {
            return .{ .config_type = .boolean, .confidence = .high };
        }

        if (std.mem.eql(u8, type_name, "float") or
            std.mem.eql(u8, type_name, "Float") or
            std.mem.eql(u8, type_name, "double") or
            std.mem.eql(u8, type_name, "Double"))
        {
            // Environment variables are strings; floats/doubles would be parsed from string
            return .{ .config_type = .string, .confidence = .high };
        }

        // Object types - high confidence
        if (std.mem.eql(u8, type_name, "String")) {
            return .{ .config_type = .string, .confidence = .high };
        }

        if (std.mem.eql(u8, type_name, "URI") or
            std.mem.eql(u8, type_name, "URL"))
        {
            return .{ .config_type = .url, .confidence = .high };
        }

        // Default to string with medium confidence
        return .{ .config_type = .string, .confidence = .medium };
    }

    /// Fallback: Infer type from context when declaration type is not available
    fn inferFromContext(context: []const u8) TypeInference {
        // Check for parse/conversion functions
        if (std.mem.indexOf(u8, context, "Integer.parseInt") != null or
            std.mem.indexOf(u8, context, "Long.parseLong") != null)
        {
            return .{ .config_type = .integer, .confidence = .high };
        }

        if (std.mem.indexOf(u8, context, "Boolean.parseBoolean") != null) {
            return .{ .config_type = .boolean, .confidence = .high };
        }

        if (std.mem.indexOf(u8, context, "Double.parseDouble") != null or
            std.mem.indexOf(u8, context, "Float.parseFloat") != null)
        {
            // Environment variables are strings; floats/doubles would be parsed from string
            return .{ .config_type = .string, .confidence = .high };
        }

        // Check for URI/URL patterns
        if (std.mem.indexOf(u8, context, "new URI") != null or
            std.mem.indexOf(u8, context, "new URL") != null or
            std.mem.indexOf(u8, context, "URI.create") != null)
        {
            return .{ .config_type = .url, .confidence = .medium };
        }

        // Check for connection string patterns
        if (std.mem.indexOf(u8, context, "jdbc:") != null or
            std.mem.indexOf(u8, context, "DriverManager.getConnection") != null or
            std.mem.indexOf(u8, context, "DataSource") != null)
        {
            return .{ .config_type = .connection_string, .confidence = .medium };
        }

        // Default to string with low confidence
        return .{ .config_type = .string, .confidence = .low };
    }
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "JavaParser init and deinit" {
    const allocator = std.testing.allocator;
    const java_parser = try JavaParser.init(allocator);
    defer java_parser.parser().deinit();
}

test "JavaParser discovers System.getenv with String type" {
    const allocator = std.testing.allocator;
    const java_parser = try JavaParser.init(allocator);
    defer java_parser.parser().deinit();

    const source =
        \\public class Config {
        \\    public static void main(String[] args) {
        \\        String apiKey = System.getenv("API_KEY");
        \\        String dbUrl = System.getenv("DATABASE_URL");
        \\    }
        \\}
    ;

    var result = try java_parser.parser().discover(allocator, "Config.java", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);
    try expectEqualStrings("API_KEY", result.usages[0].name);
    try expectEqual(ConfigType.string, result.usages[0].inferred_type);
    try expectEqual(Confidence.high, result.usages[0].confidence);
}

test "JavaParser discovers System.getenv with int type" {
    const allocator = std.testing.allocator;
    const java_parser = try JavaParser.init(allocator);
    defer java_parser.parser().deinit();

    const source =
        \\public class Config {
        \\    private int port = Integer.parseInt(System.getenv("PORT"));
        \\    private Integer maxConnections = Integer.parseInt(System.getenv("MAX_CONNECTIONS"));
        \\}
    ;

    var result = try java_parser.parser().discover(allocator, "Config.java", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);
    for (result.usages) |usage| {
        try expectEqual(ConfigType.integer, usage.inferred_type);
        try expectEqual(Confidence.high, usage.confidence);
    }
}

test "JavaParser discovers System.getenv with boolean type" {
    const allocator = std.testing.allocator;
    const java_parser = try JavaParser.init(allocator);
    defer java_parser.parser().deinit();

    const source =
        \\public class Config {
        \\    private boolean debugMode = Boolean.parseBoolean(System.getenv("DEBUG"));
        \\}
    ;

    var result = try java_parser.parser().discover(allocator, "Config.java", source);
    defer result.deinit();

    try expectEqual(@as(usize, 1), result.usages.len);
    try expectEqual(ConfigType.boolean, result.usages[0].inferred_type);
    try expectEqual(Confidence.high, result.usages[0].confidence);
}

test "JavaParser discovers Spring @Value annotation" {
    const allocator = std.testing.allocator;
    const java_parser = try JavaParser.init(allocator);
    defer java_parser.parser().deinit();

    const source =
        \\import org.springframework.beans.factory.annotation.Value;
        \\
        \\public class Config {
        \\    @Value("${DATABASE_URL}")
        \\    private String databaseUrl;
        \\
        \\    @Value("${MAX_CONNECTIONS:10}")
        \\    private int maxConnections;
        \\}
    ;

    var result = try java_parser.parser().discover(allocator, "Config.java", source);
    defer result.deinit();

    try expectEqual(@as(usize, 2), result.usages.len);
    try expectEqualStrings("DATABASE_URL", result.usages[0].name);
    try expectEqual(ConfigType.string, result.usages[0].inferred_type);
    try expectEqual(Confidence.high, result.usages[0].confidence);

    try expectEqualStrings("MAX_CONNECTIONS", result.usages[1].name);
    try expectEqual(ConfigType.integer, result.usages[1].inferred_type);
    try expectEqual(Confidence.high, result.usages[1].confidence);
}

test "JavaParser detects dynamic access" {
    const allocator = std.testing.allocator;
    const java_parser = try JavaParser.init(allocator);
    defer java_parser.parser().deinit();

    const source =
        \\public class Config {
        \\    public String get(String key) {
        \\        return System.getenv(key);
        \\    }
        \\}
    ;

    var result = try java_parser.parser().discover(allocator, "Config.java", source);
    defer result.deinit();

    try expectEqual(@as(usize, 0), result.usages.len);
    try expectEqual(@as(usize, 1), result.warnings.len);
    try expectEqual(Warning.WarningType.dynamic_access, result.warnings[0].warning_type);
}
