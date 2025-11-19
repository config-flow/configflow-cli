const std = @import("std");
const yaml = @import("yaml");

/// Confidence level for detections
pub const Confidence = enum {
    high,
    medium,
    low,

    pub fn fromString(str: []const u8) !Confidence {
        if (std.mem.eql(u8, str, "high")) return .high;
        if (std.mem.eql(u8, str, "medium")) return .medium;
        if (std.mem.eql(u8, str, "low")) return .low;
        return error.InvalidConfidence;
    }
};

/// Framework detection configuration
pub const Detection = struct {
    files: [][]const u8,
    patterns: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Detection) void {
        for (self.files) |file| {
            self.allocator.free(file);
        }
        self.allocator.free(self.files);

        var iter = self.patterns.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.patterns.deinit();
    }
};

/// Tree-sitter query configuration
pub const Query = struct {
    name: []const u8,
    description: []const u8,
    pattern: []const u8,
    key_capture: []const u8,
    confidence: Confidence,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Query) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.pattern);
        self.allocator.free(self.key_capture);
    }
};

/// Type inference by name pattern
pub const TypeInferencePattern = struct {
    pattern: []const u8,
    type: []const u8,
    confidence: Confidence,
    note: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TypeInferencePattern) void {
        self.allocator.free(self.pattern);
        self.allocator.free(self.type);
        if (self.note) |note| {
            self.allocator.free(note);
        }
    }
};

/// Type inference configuration
pub const TypeInference = struct {
    by_language_type: std.StringHashMap([]const u8),
    by_name_pattern: []TypeInferencePattern,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TypeInference) void {
        var iter = self.by_language_type.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.by_language_type.deinit();

        for (self.by_name_pattern) |*pattern| {
            pattern.deinit();
        }
        self.allocator.free(self.by_name_pattern);
    }
};

/// Framework configuration loaded from YAML
pub const FrameworkConfig = struct {
    name: []const u8,
    language: []const u8,
    version: []const u8,
    description: []const u8,
    detection: Detection,
    queries: []Query,
    type_inference: TypeInference,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FrameworkConfig) void {
        self.allocator.free(self.name);
        self.allocator.free(self.language);
        self.allocator.free(self.version);
        self.allocator.free(self.description);
        self.detection.deinit();
        for (self.queries) |*query| {
            query.deinit();
        }
        self.allocator.free(self.queries);
        self.type_inference.deinit();
    }
};

/// Parse errors
pub const ParseError = error{
    InvalidConfig,
    MissingField,
    InvalidType,
} || std.mem.Allocator.Error;

/// Parse a framework configuration from YAML
pub fn parseFrameworkConfig(allocator: std.mem.Allocator, parsed: *yaml.Yaml) !FrameworkConfig {
    const docs = parsed.docs.items;
    if (docs.len == 0) {
        return ParseError.InvalidConfig;
    }

    const root = docs[0];
    const root_map = root.asMap() orelse return ParseError.InvalidConfig;

    // Parse basic fields
    const name = try parseString(allocator, root_map, "name");
    errdefer allocator.free(name);

    const language = try parseString(allocator, root_map, "language");
    errdefer allocator.free(language);

    const version = try parseString(allocator, root_map, "version");
    errdefer allocator.free(version);

    const description = try parseString(allocator, root_map, "description");
    errdefer allocator.free(description);

    // Parse detection config
    var detection = try parseDetection(allocator, root_map);
    errdefer detection.deinit();

    // Parse queries
    const queries = try parseQueries(allocator, root_map);
    errdefer {
        for (queries) |*query| {
            query.deinit();
        }
        allocator.free(queries);
    }

    // Parse type inference
    var type_inference = try parseTypeInference(allocator, root_map, language);
    errdefer type_inference.deinit();

    return FrameworkConfig{
        .name = name,
        .language = language,
        .version = version,
        .description = description,
        .detection = detection,
        .queries = queries,
        .type_inference = type_inference,
        .allocator = allocator,
    };
}

/// Load framework config from a file path
pub fn loadFromFile(allocator: std.mem.Allocator, file_path: []const u8) !FrameworkConfig {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(content);

    var parsed = yaml.Yaml{
        .source = content,
    };
    defer parsed.deinit(allocator);

    try parsed.load(allocator);

    return try parseFrameworkConfig(allocator, &parsed);
}

/// Load framework config from embedded content
pub fn loadFromContent(allocator: std.mem.Allocator, content: []const u8) !FrameworkConfig {
    var parsed = yaml.Yaml{
        .source = content,
    };
    defer parsed.deinit(allocator);

    try parsed.load(allocator);

    return try parseFrameworkConfig(allocator, &parsed);
}

// Helper functions

fn parseString(allocator: std.mem.Allocator, map: anytype, key: []const u8) ![]const u8 {
    const value = map.get(key) orelse return ParseError.MissingField;
    const str = value.asScalar() orelse return ParseError.InvalidType;
    return try allocator.dupe(u8, str);
}

fn parseDetection(allocator: std.mem.Allocator, root_map: anytype) !Detection {
    const detection_value = root_map.get("detection") orelse return ParseError.MissingField;
    const detection_map = detection_value.asMap() orelse return ParseError.InvalidType;

    // Parse files array
    var files = std.ArrayList([]const u8){};
    errdefer {
        for (files.items) |file| {
            allocator.free(file);
        }
        files.deinit(allocator);
    }

    const files_value = detection_map.get("files") orelse return ParseError.MissingField;
    const files_list = files_value.asList() orelse return ParseError.InvalidType;

    for (files_list) |file_item| {
        const file_str = file_item.asScalar() orelse return ParseError.InvalidType;
        try files.append(allocator, try allocator.dupe(u8, file_str));
    }

    // Parse patterns map
    var patterns = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = patterns.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        patterns.deinit();
    }

    const patterns_value = detection_map.get("patterns") orelse return ParseError.MissingField;
    const patterns_map = patterns_value.asMap() orelse return ParseError.InvalidType;

    var patterns_iter = patterns_map.iterator();
    while (patterns_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const pattern_str = value.asScalar() orelse return ParseError.InvalidType;

        try patterns.put(
            try allocator.dupe(u8, key),
            try allocator.dupe(u8, pattern_str),
        );
    }

    return Detection{
        .files = try files.toOwnedSlice(allocator),
        .patterns = patterns,
        .allocator = allocator,
    };
}

fn parseQueries(allocator: std.mem.Allocator, root_map: anytype) ![]Query {
    const queries_value = root_map.get("queries") orelse return ParseError.MissingField;
    const queries_list = queries_value.asList() orelse return ParseError.InvalidType;

    var queries = std.ArrayList(Query){};
    errdefer {
        for (queries.items) |*query| {
            query.deinit();
        }
        queries.deinit(allocator);
    }

    for (queries_list) |query_item| {
        const query_map = query_item.asMap() orelse return ParseError.InvalidType;

        const name = try parseString(allocator, query_map, "name");
        errdefer allocator.free(name);

        const description = try parseString(allocator, query_map, "description");
        errdefer allocator.free(description);

        const pattern = try parseString(allocator, query_map, "pattern");
        errdefer allocator.free(pattern);

        const key_capture = try parseString(allocator, query_map, "key_capture");
        errdefer allocator.free(key_capture);

        const confidence_str = try parseString(allocator, query_map, "confidence");
        defer allocator.free(confidence_str);
        const confidence = try Confidence.fromString(confidence_str);

        try queries.append(allocator, Query{
            .name = name,
            .description = description,
            .pattern = pattern,
            .key_capture = key_capture,
            .confidence = confidence,
            .allocator = allocator,
        });
    }

    return try queries.toOwnedSlice(allocator);
}

fn parseTypeInference(allocator: std.mem.Allocator, root_map: anytype, language: []const u8) !TypeInference {
    const type_inference_value = root_map.get("type_inference") orelse return ParseError.MissingField;
    const type_inference_map = type_inference_value.asMap() orelse return ParseError.InvalidType;

    // Parse by_language_type (varies by language: by_python_type, by_java_type, etc.)
    var by_language_type = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = by_language_type.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        by_language_type.deinit();
    }

    // Determine the key name based on language
    const type_key: ?[]const u8 = if (std.mem.eql(u8, language, "python"))
        "by_python_type"
    else if (std.mem.eql(u8, language, "java"))
        "by_java_type"
    else if (std.mem.eql(u8, language, "javascript"))
        "by_js_type"
    else if (std.mem.eql(u8, language, "ruby"))
        "by_ruby_type"
    else
        null;

    if (type_key) |key| {
        if (type_inference_map.get(key)) |type_map_value| {
            const type_map = type_map_value.asMap() orelse return ParseError.InvalidType;

            var type_iter = type_map.iterator();
            while (type_iter.next()) |entry| {
                const k = entry.key_ptr.*;
                const v = entry.value_ptr.*;
                const type_str = v.asScalar() orelse return ParseError.InvalidType;

                try by_language_type.put(
                    try allocator.dupe(u8, k),
                    try allocator.dupe(u8, type_str),
                );
            }
        }
    }

    // Parse by_name_pattern
    var name_patterns = std.ArrayList(TypeInferencePattern){};
    errdefer {
        for (name_patterns.items) |*pattern| {
            pattern.deinit();
        }
        name_patterns.deinit(allocator);
    }

    if (type_inference_map.get("by_name_pattern")) |patterns_value| {
        const patterns_list = patterns_value.asList() orelse return ParseError.InvalidType;

        for (patterns_list) |pattern_item| {
            const pattern_map = pattern_item.asMap() orelse return ParseError.InvalidType;

            const pattern = try parseString(allocator, pattern_map, "pattern");
            errdefer allocator.free(pattern);

            const type_str = try parseString(allocator, pattern_map, "type");
            errdefer allocator.free(type_str);

            const confidence_str = try parseString(allocator, pattern_map, "confidence");
            defer allocator.free(confidence_str);
            const confidence = try Confidence.fromString(confidence_str);

            var note: ?[]const u8 = null;
            if (pattern_map.get("note")) |note_value| {
                if (note_value.asScalar()) |note_str| {
                    note = try allocator.dupe(u8, note_str);
                }
            }

            try name_patterns.append(allocator, TypeInferencePattern{
                .pattern = pattern,
                .type = type_str,
                .confidence = confidence,
                .note = note,
                .allocator = allocator,
            });
        }
    }

    return TypeInference{
        .by_language_type = by_language_type,
        .by_name_pattern = try name_patterns.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// Tests
test "FrameworkConfig parses NestJS YAML" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "NestJS"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Detects NestJS ConfigService usage"
        \\
        \\detection:
        \\  files:
        \\    - "package.json"
        \\    - "nest-cli.json"
        \\  patterns:
        \\    package_json: "@nestjs/core"
        \\
        \\queries:
        \\  - name: "ConfigService.get() method calls"
        \\    description: "Matches this.configService.get('KEY')"
        \\    pattern: "(call_expression)"
        \\    key_capture: "key_string"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern:
        \\    - pattern: "(?i)port$"
        \\      type: "integer"
        \\      confidence: "high"
    ;

    var parsed = yaml.Yaml{
        .source = yaml_content,
    };
    defer parsed.deinit(allocator);

    try parsed.load(allocator);

    var config = try parseFrameworkConfig(allocator, &parsed);
    defer config.deinit();

    try std.testing.expectEqualStrings("NestJS", config.name);
    try std.testing.expectEqualStrings("javascript", config.language);
    try std.testing.expectEqual(@as(usize, 2), config.detection.files.len);
    try std.testing.expectEqual(@as(usize, 1), config.queries.len);
    try std.testing.expectEqualStrings("ConfigService.get() method calls", config.queries[0].name);
    try std.testing.expectEqual(Confidence.high, config.queries[0].confidence);
}

test "FrameworkConfig parses Pydantic YAML with type mappings" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "Pydantic Settings"
        \\language: "python"
        \\version: "1.0.0"
        \\description: "Detects Pydantic Settings"
        \\
        \\detection:
        \\  files:
        \\    - "settings.py"
        \\  patterns:
        \\    requirements_txt: "pydantic"
        \\
        \\queries:
        \\  - name: "Pydantic Field"
        \\    description: "Field patterns"
        \\    pattern: "(call)"
        \\    key_capture: "key_string"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_python_type:
        \\    str: string
        \\    int: integer
        \\    SecretStr: secret
        \\  by_name_pattern:
        \\    - pattern: "(?i)secret"
        \\      type: "secret"
        \\      confidence: "high"
        \\      note: "Sensitive value"
    ;

    var parsed = yaml.Yaml{
        .source = yaml_content,
    };
    defer parsed.deinit(allocator);

    try parsed.load(allocator);

    var config = try parseFrameworkConfig(allocator, &parsed);
    defer config.deinit();

    try std.testing.expectEqualStrings("Pydantic Settings", config.name);
    try std.testing.expectEqual(@as(usize, 3), config.type_inference.by_language_type.count());
    try std.testing.expectEqual(@as(usize, 1), config.type_inference.by_name_pattern.len);

    const str_type = config.type_inference.by_language_type.get("str");
    try std.testing.expect(str_type != null);
    try std.testing.expectEqualStrings("string", str_type.?);
}

test "FrameworkConfig parses multiple queries" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "Test Framework"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test multiple queries"
        \\
        \\detection:
        \\  files:
        \\    - "test.json"
        \\  patterns:
        \\    test: "pattern"
        \\
        \\queries:
        \\  - name: "Query 1"
        \\    description: "First query"
        \\    pattern: "(identifier)"
        \\    key_capture: "id"
        \\    confidence: "high"
        \\  - name: "Query 2"
        \\    description: "Second query"
        \\    pattern: "(string)"
        \\    key_capture: "str"
        \\    confidence: "medium"
        \\  - name: "Query 3"
        \\    description: "Third query"
        \\    pattern: "(number)"
        \\    key_capture: "num"
        \\    confidence: "low"
        \\
        \\type_inference:
        \\  by_name_pattern: []
    ;

    var config = try loadFromContent(allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 3), config.queries.len);
    try std.testing.expectEqualStrings("Query 1", config.queries[0].name);
    try std.testing.expectEqual(Confidence.high, config.queries[0].confidence);
    try std.testing.expectEqualStrings("Query 2", config.queries[1].name);
    try std.testing.expectEqual(Confidence.medium, config.queries[1].confidence);
    try std.testing.expectEqualStrings("Query 3", config.queries[2].name);
    try std.testing.expectEqual(Confidence.low, config.queries[2].confidence);
}

test "FrameworkConfig parses Java type mappings" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "Spring Boot"
        \\language: "java"
        \\version: "1.0.0"
        \\description: "Test Java type mappings"
        \\
        \\detection:
        \\  files:
        \\    - "pom.xml"
        \\  patterns:
        \\    pom: "spring"
        \\
        \\queries:
        \\  - name: "Test"
        \\    description: "Test query"
        \\    pattern: "(identifier)"
        \\    key_capture: "id"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_java_type:
        \\    String: string
        \\    Integer: integer
        \\    Boolean: boolean
        \\  by_name_pattern: []
    ;

    var config = try loadFromContent(allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 3), config.type_inference.by_language_type.count());
    const string_type = config.type_inference.by_language_type.get("String");
    try std.testing.expect(string_type != null);
    try std.testing.expectEqualStrings("string", string_type.?);
}

test "FrameworkConfig parses Ruby type mappings" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "Rails"
        \\language: "ruby"
        \\version: "1.0.0"
        \\description: "Test Ruby type mappings"
        \\
        \\detection:
        \\  files:
        \\    - "Gemfile"
        \\  patterns:
        \\    gemfile: "rails"
        \\
        \\queries:
        \\  - name: "Test"
        \\    description: "Test query"
        \\    pattern: "(identifier)"
        \\    key_capture: "id"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_ruby_type:
        \\    String: string
        \\    Integer: integer
        \\    TrueClass: boolean
        \\    FalseClass: boolean
        \\  by_name_pattern: []
    ;

    var config = try loadFromContent(allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 4), config.type_inference.by_language_type.count());
}

test "FrameworkConfig parses JavaScript type mappings" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "NestJS"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test JS type mappings"
        \\
        \\detection:
        \\  files:
        \\    - "package.json"
        \\  patterns:
        \\    pkg: "nestjs"
        \\
        \\queries:
        \\  - name: "Test"
        \\    description: "Test query"
        \\    pattern: "(identifier)"
        \\    key_capture: "id"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_js_type:
        \\    string: string
        \\    number: integer
        \\  by_name_pattern: []
    ;

    var config = try loadFromContent(allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.type_inference.by_language_type.count());
}

test "FrameworkConfig handles empty type inference" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "Minimal"
        \\language: "python"
        \\version: "1.0.0"
        \\description: "Minimal config"
        \\
        \\detection:
        \\  files:
        \\    - "test.py"
        \\  patterns:
        \\    test: "python"
        \\
        \\queries:
        \\  - name: "Test"
        \\    description: "Test"
        \\    pattern: "(identifier)"
        \\    key_capture: "id"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern: []
    ;

    var config = try loadFromContent(allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.type_inference.by_language_type.count());
    try std.testing.expectEqual(@as(usize, 0), config.type_inference.by_name_pattern.len);
}

test "FrameworkConfig parses complex name patterns" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "Test"
        \\language: "python"
        \\version: "1.0.0"
        \\description: "Test name patterns"
        \\
        \\detection:
        \\  files:
        \\    - "test.py"
        \\  patterns:
        \\    test: "test"
        \\
        \\queries:
        \\  - name: "Test"
        \\    description: "Test"
        \\    pattern: "(identifier)"
        \\    key_capture: "id"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern:
        \\    - pattern: "(?i)port$"
        \\      type: "integer"
        \\      confidence: "high"
        \\      note: "Network port"
        \\    - pattern: "(?i)secret"
        \\      type: "secret"
        \\      confidence: "high"
        \\      note: "Sensitive value"
        \\    - pattern: "(?i)url$"
        \\      type: "url"
        \\      confidence: "medium"
    ;

    var config = try loadFromContent(allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 3), config.type_inference.by_name_pattern.len);

    // First pattern has a note
    try std.testing.expect(config.type_inference.by_name_pattern[0].note != null);
    try std.testing.expectEqualStrings("Network port", config.type_inference.by_name_pattern[0].note.?);

    // Third pattern has no note field in YAML, should be null
    // Note: Actually checking the YAML, it doesn't have a note field, so it will be null
    // Let me check the second one which has a note
    try std.testing.expect(config.type_inference.by_name_pattern[1].note != null);
}

test "FrameworkConfig validates required fields" {
    const allocator = std.testing.allocator;

    // Missing 'name' field
    const missing_name =
        \\language: "python"
        \\version: "1.0.0"
        \\description: "Test"
    ;

    const result = loadFromContent(allocator, missing_name);
    try std.testing.expectError(ParseError.MissingField, result);
}

test "FrameworkConfig handles multiple detection files" {
    const allocator = std.testing.allocator;

    const yaml_content =
        \\name: "Test"
        \\language: "javascript"
        \\version: "1.0.0"
        \\description: "Test multiple detection files"
        \\
        \\detection:
        \\  files:
        \\    - "package.json"
        \\    - "nest-cli.json"
        \\    - "tsconfig.json"
        \\    - ".env"
        \\  patterns:
        \\    package_json: "@nestjs"
        \\    nest_cli: "schematics"
        \\
        \\queries:
        \\  - name: "Test"
        \\    description: "Test"
        \\    pattern: "(identifier)"
        \\    key_capture: "id"
        \\    confidence: "high"
        \\
        \\type_inference:
        \\  by_name_pattern: []
    ;

    var config = try loadFromContent(allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 4), config.detection.files.len);
    try std.testing.expectEqual(@as(usize, 2), config.detection.patterns.count());
}
