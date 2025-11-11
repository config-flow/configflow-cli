const std = @import("std");
const types = @import("types.zig");

/// Supported configuration field types (V1)
pub const FieldType = enum {
    string,
    integer,
    boolean,
    url,
    connection_string,
    secret,
    email,

    /// Parse field type from string
    pub fn fromString(s: []const u8) !FieldType {
        if (std.mem.eql(u8, s, "string")) return .string;
        if (std.mem.eql(u8, s, "integer")) return .integer;
        if (std.mem.eql(u8, s, "boolean")) return .boolean;
        if (std.mem.eql(u8, s, "url")) return .url;
        if (std.mem.eql(u8, s, "connection_string")) return .connection_string;
        if (std.mem.eql(u8, s, "secret")) return .secret;
        if (std.mem.eql(u8, s, "email")) return .email;
        return error.InvalidType;
    }

    /// Convert field type to string
    pub fn toString(self: FieldType) []const u8 {
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

/// Required field specification
pub const RequiredSpec = union(enum) {
    /// Required in all contexts
    always: bool,
    /// Required in specific contexts
    contexts: []const []const u8,

    pub fn deinit(self: RequiredSpec, allocator: std.mem.Allocator) void {
        switch (self) {
            .contexts => |ctx| {
                for (ctx) |c| {
                    allocator.free(c);
                }
                allocator.free(ctx);
            },
            else => {},
        }
    }
};

/// Configuration field definition
pub const Field = struct {
    name: []const u8,
    field_type: FieldType,
    required: RequiredSpec,
    description: ?[]const u8 = null,
    default: ?[]const u8 = null,
    pattern: ?[]const u8 = null,

    pub fn deinit(self: Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.required.deinit(allocator);
        if (self.description) |desc| allocator.free(desc);
        if (self.default) |def| allocator.free(def);
        if (self.pattern) |pat| allocator.free(pat);
    }
};

/// Field validation errors
pub const FieldValidationError = error{
    MissingRequiredField,
    InvalidType,
    PatternMismatch,
} || types.ValidationError;

/// Validation result for a single field
pub const FieldValidationResult = struct {
    field: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: FieldValidationResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Check if a field is required in the given context
pub fn isRequired(field: Field, context: []const u8) bool {
    return switch (field.required) {
        .always => |required| required,
        .contexts => |contexts| {
            for (contexts) |ctx| {
                if (std.mem.eql(u8, ctx, context)) {
                    return true;
                }
            }
            return false;
        },
    };
}

/// Validate a single field value
pub fn validateField(
    allocator: std.mem.Allocator,
    field: Field,
    value: ?[]const u8,
    context: []const u8,
) !FieldValidationResult {
    // 1. Check if field is required
    if (isRequired(field, context)) {
        if (value == null) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Field '{s}' is required in context '{s}' but not provided",
                .{ field.name, context },
            );
            return FieldValidationResult{
                .field = field.name,
                .success = false,
                .error_message = msg,
            };
        }
    }

    // If value is null and not required, that's OK
    if (value == null) {
        return FieldValidationResult{
            .field = field.name,
            .success = true,
        };
    }

    const val = value.?;

    // 2. Type validation
    const type_result = validateType(field.field_type, val);
    if (type_result) |_| {
        // Type validation passed
    } else |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Field '{s}' has invalid {s}: '{s}' - {s}",
            .{ field.name, field.field_type.toString(), val, @errorName(err) },
        );
        return FieldValidationResult{
            .field = field.name,
            .success = false,
            .error_message = msg,
        };
    }

    // 3. Pattern validation (if specified)
    if (field.pattern) |pattern| {
        // For V1, we'll use simple pattern matching
        // TODO: Implement proper regex in future iteration
        _ = pattern;
        // For now, skip pattern validation
    }

    return FieldValidationResult{
        .field = field.name,
        .success = true,
    };
}

/// Validate a value against a specific type
fn validateType(field_type: FieldType, value: []const u8) !void {
    switch (field_type) {
        .string => try types.validateString(value),
        .integer => try types.validateInteger(value),
        .boolean => try types.validateBoolean(value),
        .url => try types.validateUrl(value),
        .connection_string => try types.validateConnectionString(value),
        .secret => try types.validateSecret(value),
        .email => try types.validateEmail(value),
    }
}

// ============================================================================
// FieldType Tests
// ============================================================================

test "FieldType fromString parses valid types" {
    try expect((try FieldType.fromString("string")) == .string);
    try expect((try FieldType.fromString("integer")) == .integer);
    try expect((try FieldType.fromString("boolean")) == .boolean);
    try expect((try FieldType.fromString("url")) == .url);
    try expect((try FieldType.fromString("connection_string")) == .connection_string);
    try expect((try FieldType.fromString("secret")) == .secret);
    try expect((try FieldType.fromString("email")) == .email);
}

test "FieldType fromString rejects invalid types" {
    try expectError(error.InvalidType, FieldType.fromString("json"));
    try expectError(error.InvalidType, FieldType.fromString("invalid"));
    try expectError(error.InvalidType, FieldType.fromString(""));
}

test "FieldType toString returns correct strings" {
    try expect(std.mem.eql(u8, FieldType.string.toString(), "string"));
    try expect(std.mem.eql(u8, FieldType.integer.toString(), "integer"));
    try expect(std.mem.eql(u8, FieldType.boolean.toString(), "boolean"));
    try expect(std.mem.eql(u8, FieldType.url.toString(), "url"));
    try expect(std.mem.eql(u8, FieldType.connection_string.toString(), "connection_string"));
    try expect(std.mem.eql(u8, FieldType.secret.toString(), "secret"));
    try expect(std.mem.eql(u8, FieldType.email.toString(), "email"));
}

// ============================================================================
// Required Field Tests
// ============================================================================

test "isRequired with always true" {
    const test_field = Field{
        .name = "TEST",
        .field_type = .string,
        .required = .{ .always = true },
    };

    try expect(isRequired(test_field, "local"));
    try expect(isRequired(test_field, "prod"));
    try expect(isRequired(test_field, "staging"));
}

test "isRequired with always false" {
    const test_field = Field{
        .name = "TEST",
        .field_type = .string,
        .required = .{ .always = false },
    };

    try expect(!isRequired(test_field, "local"));
    try expect(!isRequired(test_field, "prod"));
    try expect(!isRequired(test_field, "staging"));
}

test "isRequired with specific contexts" {
    const contexts = [_][]const u8{ "prod", "staging" };
    const test_field = Field{
        .name = "TEST",
        .field_type = .string,
        .required = .{ .contexts = &contexts },
    };

    try expect(isRequired(test_field, "prod"));
    try expect(isRequired(test_field, "staging"));
    try expect(!isRequired(test_field, "local"));
    try expect(!isRequired(test_field, "dev"));
}

// ============================================================================
// Field Validation Tests
// ============================================================================

test "validateField succeeds for valid required field" {
    const allocator = std.testing.allocator;

    const test_field = Field{
        .name = "PORT",
        .field_type = .integer,
        .required = .{ .always = true },
    };

    const result = try validateField(allocator, test_field, "3000", "local");
    defer result.deinit(allocator);

    try expect(result.success);
    try expect(result.error_message == null);
}

test "validateField fails for missing required field" {
    const allocator = std.testing.allocator;

    const test_field = Field{
        .name = "DATABASE_URL",
        .field_type = .connection_string,
        .required = .{ .always = true },
    };

    const result = try validateField(allocator, test_field, null, "prod");
    defer result.deinit(allocator);

    try expect(!result.success);
    try expect(result.error_message != null);
}

test "validateField succeeds for missing optional field" {
    const allocator = std.testing.allocator;

    const test_field = Field{
        .name = "DEBUG",
        .field_type = .boolean,
        .required = .{ .always = false },
    };

    const result = try validateField(allocator, test_field, null, "local");
    defer result.deinit(allocator);

    try expect(result.success);
    try expect(result.error_message == null);
}

test "validateField fails for invalid type" {
    const allocator = std.testing.allocator;

    const test_field = Field{
        .name = "PORT",
        .field_type = .integer,
        .required = .{ .always = false },
    };

    const result = try validateField(allocator, test_field, "not-a-number", "local");
    defer result.deinit(allocator);

    try expect(!result.success);
    try expect(result.error_message != null);
}

test "validateField context-specific required in prod" {
    const allocator = std.testing.allocator;

    const contexts = [_][]const u8{"prod"};
    const test_field = Field{
        .name = "API_KEY",
        .field_type = .secret,
        .required = .{ .contexts = &contexts },
    };

    // Should fail in prod
    const result_prod = try validateField(allocator, test_field, null, "prod");
    defer result_prod.deinit(allocator);
    try expect(!result_prod.success);

    // Should succeed in local
    const result_local = try validateField(allocator, test_field, null, "local");
    defer result_local.deinit(allocator);
    try expect(result_local.success);
}

test "validateField all 7 types" {
    const allocator = std.testing.allocator;

    const test_cases = [_]struct {
        field_type: FieldType,
        value: []const u8,
        should_succeed: bool,
    }{
        .{ .field_type = .string, .value = "any-string", .should_succeed = true },
        .{ .field_type = .integer, .value = "42", .should_succeed = true },
        .{ .field_type = .integer, .value = "not-int", .should_succeed = false },
        .{ .field_type = .boolean, .value = "true", .should_succeed = true },
        .{ .field_type = .boolean, .value = "yes", .should_succeed = false },
        .{ .field_type = .url, .value = "https://example.com", .should_succeed = true },
        .{ .field_type = .url, .value = "not-a-url", .should_succeed = false },
        .{ .field_type = .connection_string, .value = "postgresql://localhost/db", .should_succeed = true },
        .{ .field_type = .connection_string, .value = "invalid://", .should_succeed = false },
        .{ .field_type = .secret, .value = "sk_test_123", .should_succeed = true },
        .{ .field_type = .email, .value = "user@example.com", .should_succeed = true },
        .{ .field_type = .email, .value = "not-an-email", .should_succeed = false },
    };

    for (test_cases) |case| {
        const test_field = Field{
            .name = "TEST",
            .field_type = case.field_type,
            .required = .{ .always = false },
        };

        const result = try validateField(allocator, test_field, case.value, "local");
        defer result.deinit(allocator);

        if (case.should_succeed) {
            try expect(result.success);
        } else {
            try expect(!result.success);
        }
    }
}
