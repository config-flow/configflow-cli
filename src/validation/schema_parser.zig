const std = @import("std");
const yaml = @import("yaml");
const field = @import("field.zig");

/// Parse error types
pub const ParseError = error{
    InvalidSchema,
    MissingConfig,
    MissingType,
    InvalidType,
    InvalidRequired,
} || std.mem.Allocator.Error;

/// Parse a YAML schema into a list of Field objects
pub fn parseSchema(allocator: std.mem.Allocator, parsed: *yaml.Yaml) ![]field.Field {
    const docs = parsed.docs.items;
    if (docs.len == 0) {
        return ParseError.InvalidSchema;
    }

    const root = docs[0];
    const root_map = root.asMap() orelse return ParseError.InvalidSchema;

    // Get config section
    const config_value = root_map.get("config") orelse return ParseError.MissingConfig;
    const config_map = config_value.asMap() orelse return ParseError.InvalidSchema;

    // Count entries
    var count: usize = 0;
    var iter = config_map.iterator();
    while (iter.next()) |_| {
        count += 1;
    }

    // Allocate array for fields
    var fields = try std.ArrayList(field.Field).initCapacity(allocator, count);
    errdefer {
        for (fields.items) |f| {
            f.deinit(allocator);
        }
        fields.deinit(allocator);
    }

    // Parse each field
    iter = config_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        const parsed_field = try parseField(allocator, key, value);
        try fields.append(allocator, parsed_field);
    }

    return try fields.toOwnedSlice(allocator);
}

/// Parse a single field from YAML
fn parseField(allocator: std.mem.Allocator, name: []const u8, value: yaml.Yaml.Value) !field.Field {
    const entry_map = value.asMap() orelse return ParseError.InvalidSchema;

    // Parse type (required)
    const type_value = entry_map.get("type") orelse return ParseError.MissingType;
    const type_str = type_value.asScalar() orelse return ParseError.InvalidType;
    const field_type = field.FieldType.fromString(type_str) catch return ParseError.InvalidType;

    // Parse required (optional, defaults to false)
    const required = try parseRequired(allocator, entry_map);

    // Parse description (optional)
    const description = if (entry_map.get("description")) |desc_value|
        if (desc_value.asScalar()) |desc_str|
            try allocator.dupe(u8, desc_str)
        else
            null
    else
        null;

    // Parse default (optional)
    const default = if (entry_map.get("default")) |def_value|
        if (def_value.asScalar()) |def_str|
            try allocator.dupe(u8, def_str)
        else
            null
    else
        null;

    // Parse pattern (optional)
    const pattern = if (entry_map.get("pattern")) |pat_value|
        if (pat_value.asScalar()) |pat_str|
            try allocator.dupe(u8, pat_str)
        else
            null
    else
        null;

    return field.Field{
        .name = try allocator.dupe(u8, name),
        .field_type = field_type,
        .required = required,
        .description = description,
        .default = default,
        .pattern = pattern,
    };
}

/// Parse required field specification
fn parseRequired(allocator: std.mem.Allocator, entry_map: anytype) !field.RequiredSpec {
    const required_value = entry_map.get("required") orelse {
        // Default to false if not specified
        return field.RequiredSpec{ .always = false };
    };

    // Check if it's a boolean
    if (required_value.asScalar()) |scalar| {
        if (std.mem.eql(u8, scalar, "true")) {
            return field.RequiredSpec{ .always = true };
        }
        if (std.mem.eql(u8, scalar, "false")) {
            return field.RequiredSpec{ .always = false };
        }
        return ParseError.InvalidRequired;
    }

    // Check if it's a boolean value type
    switch (required_value) {
        .boolean => |b| {
            return field.RequiredSpec{ .always = b };
        },
        .list => |lst| {
            // It's an array of contexts
            var contexts = try std.ArrayList([]const u8).initCapacity(allocator, lst.len);
            errdefer {
                for (contexts.items) |ctx| {
                    allocator.free(ctx);
                }
                contexts.deinit(allocator);
            }

            for (lst) |item| {
                if (item.asScalar()) |ctx_str| {
                    try contexts.append(allocator, try allocator.dupe(u8, ctx_str));
                } else {
                    return ParseError.InvalidRequired;
                }
            }

            return field.RequiredSpec{ .contexts = try contexts.toOwnedSlice(allocator) };
        },
        else => return ParseError.InvalidRequired,
    }
}

/// Free a parsed schema
pub fn freeSchema(allocator: std.mem.Allocator, fields: []field.Field) void {
    for (fields) |f| {
        f.deinit(allocator);
    }
    allocator.free(fields);
}
const expect = std.testing.expect;
const expectError = std.testing.expectError;

// ============================================================================
// Schema Parser Tests
// ============================================================================

test "parseSchema with simple field" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\config:
        \\  PORT:
        \\    type: integer
        \\    required: true
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    const fields = try parseSchema(allocator, &parsed);
    defer freeSchema(allocator, fields);

    try expect(fields.len == 1);
    try expect(std.mem.eql(u8, fields[0].name, "PORT"));
    try expect(fields[0].field_type == .integer);
    try expect(fields[0].required.always == true);
}

test "parseSchema with all 7 types" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\config:
        \\  STR:
        \\    type: string
        \\  INT:
        \\    type: integer
        \\  BOOL:
        \\    type: boolean
        \\  URL:
        \\    type: url
        \\  CONN:
        \\    type: connection_string
        \\  SEC:
        \\    type: secret
        \\  EMAIL:
        \\    type: email
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    const fields = try parseSchema(allocator, &parsed);
    defer freeSchema(allocator, fields);

    try expect(fields.len == 7);

    // Check each type is correctly parsed
    const expected_types = [_]field.FieldType{
        .string,
        .integer,
        .boolean,
        .url,
        .connection_string,
        .secret,
        .email,
    };

    for (fields, 0..) |f, i| {
        try expect(f.field_type == expected_types[i]);
    }
}

test "parseSchema with required boolean" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\config:
        \\  FIELD1:
        \\    type: string
        \\    required: true
        \\  FIELD2:
        \\    type: string
        \\    required: false
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    const fields = try parseSchema(allocator, &parsed);
    defer freeSchema(allocator, fields);

    try expect(fields.len == 2);
    try expect(fields[0].required.always == true);
    try expect(fields[1].required.always == false);
}

test "parseSchema with required contexts array" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\config:
        \\  API_KEY:
        \\    type: secret
        \\    required: [prod, staging]
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    const fields = try parseSchema(allocator, &parsed);
    defer freeSchema(allocator, fields);

    try expect(fields.len == 1);
    try expect(fields[0].required == .contexts);
    try expect(fields[0].required.contexts.len == 2);
    try expect(std.mem.eql(u8, fields[0].required.contexts[0], "prod"));
    try expect(std.mem.eql(u8, fields[0].required.contexts[1], "staging"));
}

test "parseSchema with optional fields" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\config:
        \\  PORT:
        \\    type: integer
        \\    required: false
        \\    default: 3000
        \\    description: HTTP server port
        \\    pattern: "^[0-9]+$"
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    const fields = try parseSchema(allocator, &parsed);
    defer freeSchema(allocator, fields);

    try expect(fields.len == 1);
    try expect(fields[0].default != null);
    try expect(std.mem.eql(u8, fields[0].default.?, "3000"));
    try expect(fields[0].description != null);
    try expect(std.mem.eql(u8, fields[0].description.?, "HTTP server port"));
    try expect(fields[0].pattern != null);
    try expect(std.mem.eql(u8, fields[0].pattern.?, "^[0-9]+$"));
}

test "parseSchema missing config section" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\sources:
        \\  local:
        \\    type: file
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    try expectError(error.MissingConfig, parseSchema(allocator, &parsed));
}

test "parseSchema missing type field" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\config:
        \\  PORT:
        \\    required: true
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    try expectError(error.MissingType, parseSchema(allocator, &parsed));
}

test "parseSchema invalid type" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\config:
        \\  PORT:
        \\    type: invalid_type
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    try expectError(error.InvalidType, parseSchema(allocator, &parsed));
}

test "parseSchema defaults to required false" {
    const allocator = std.testing.allocator;

    const schema_yaml =
        \\config:
        \\  PORT:
        \\    type: integer
    ;

    var parsed = yaml.Yaml{ .source = schema_yaml };
    defer parsed.deinit(allocator);
    try parsed.load(allocator);

    const fields = try parseSchema(allocator, &parsed);
    defer freeSchema(allocator, fields);

    try expect(fields.len == 1);
    try expect(fields[0].required.always == false);
}
