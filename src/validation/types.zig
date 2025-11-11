const std = @import("std");

/// Type validation errors
pub const ValidationError = error{
    InvalidInteger,
    InvalidBoolean,
    InvalidUrl,
    InvalidConnectionString,
    InvalidEmail,
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Validates string type - any string is valid
pub fn validateString(value: []const u8) !void {
    _ = value;
    // Any string is valid
}

/// Validates integer type - must parse as valid integer
pub fn validateInteger(value: []const u8) !void {
    _ = std.fmt.parseInt(i64, value, 10) catch {
        return ValidationError.InvalidInteger;
    };
}

/// Validates boolean type - must be exactly "true" or "false" (lowercase)
pub fn validateBoolean(value: []const u8) !void {
    if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) {
        return ValidationError.InvalidBoolean;
    }
}

/// Validates URL type - must start with http:// or https://
pub fn validateUrl(value: []const u8) !void {
    if (value.len == 0) {
        return ValidationError.InvalidUrl;
    }

    // Must start with http:// or https://
    if (!std.mem.startsWith(u8, value, "http://") and
        !std.mem.startsWith(u8, value, "https://"))
    {
        return ValidationError.InvalidUrl;
    }

    // Basic validation: must have something after protocol
    const min_length = "https://x".len;
    if (value.len < min_length) {
        return ValidationError.InvalidUrl;
    }
}

/// Validates connection string - must match database protocol format
pub fn validateConnectionString(value: []const u8) !void {
    if (value.len == 0) {
        return ValidationError.InvalidConnectionString;
    }

    // Supported protocols
    const valid_protocols = [_][]const u8{
        "postgresql://",
        "mysql://",
        "mongodb://",
        "redis://",
    };

    for (valid_protocols) |protocol| {
        if (std.mem.startsWith(u8, value, protocol)) {
            // Basic check: must have something after protocol
            if (value.len > protocol.len) {
                return; // Valid
            }
        }
    }

    return ValidationError.InvalidConnectionString;
}

/// Validates secret type - same as string (special behavior is in display)
pub fn validateSecret(value: []const u8) !void {
    // Same validation as string - the difference is display behavior
    return validateString(value);
}

/// Validates email type - basic email format validation
pub fn validateEmail(value: []const u8) !void {
    if (value.len == 0) {
        return ValidationError.InvalidEmail;
    }

    // Must contain @ symbol
    const at_pos = std.mem.indexOf(u8, value, "@") orelse return ValidationError.InvalidEmail;

    // @ cannot be first or last character
    if (at_pos == 0 or at_pos >= value.len - 1) {
        return ValidationError.InvalidEmail;
    }

    // Must contain . after @
    const after_at = value[at_pos + 1 ..];
    const dot_pos = std.mem.indexOf(u8, after_at, ".") orelse return ValidationError.InvalidEmail;

    // . cannot be first or last character after @
    if (dot_pos == 0 or dot_pos >= after_at.len - 1) {
        return ValidationError.InvalidEmail;
    }
}
// ============================================================================
// String Type Tests
// ============================================================================

test "string type accepts any value" {
    try validateString("hello");
    try validateString("");
    try validateString("123");
    try validateString("special!@#$%^&*()");
    try validateString("unicode: 你好");
    try validateString("newlines\nand\ttabs");
}

// ============================================================================
// Integer Type Tests
// ============================================================================

test "integer type accepts valid integers" {
    try validateInteger("42");
    try validateInteger("-10");
    try validateInteger("0");
    try validateInteger("999999999");
    try validateInteger("-999999999");
}

test "integer type rejects invalid values" {
    try expectError(error.InvalidInteger, validateInteger("abc"));
    try expectError(error.InvalidInteger, validateInteger("3.14"));
    try expectError(error.InvalidInteger, validateInteger("12.0"));
    try expectError(error.InvalidInteger, validateInteger(""));
    try expectError(error.InvalidInteger, validateInteger("42a"));
    try expectError(error.InvalidInteger, validateInteger("a42"));
    try expectError(error.InvalidInteger, validateInteger("4 2"));
}

// ============================================================================
// Boolean Type Tests
// ============================================================================

test "boolean type accepts true and false" {
    try validateBoolean("true");
    try validateBoolean("false");
}

test "boolean type is strict about case" {
    try expectError(error.InvalidBoolean, validateBoolean("True"));
    try expectError(error.InvalidBoolean, validateBoolean("TRUE"));
    try expectError(error.InvalidBoolean, validateBoolean("False"));
    try expectError(error.InvalidBoolean, validateBoolean("FALSE"));
}

test "boolean type rejects non-boolean values" {
    try expectError(error.InvalidBoolean, validateBoolean("1"));
    try expectError(error.InvalidBoolean, validateBoolean("0"));
    try expectError(error.InvalidBoolean, validateBoolean("yes"));
    try expectError(error.InvalidBoolean, validateBoolean("no"));
    try expectError(error.InvalidBoolean, validateBoolean(""));
    try expectError(error.InvalidBoolean, validateBoolean("t"));
    try expectError(error.InvalidBoolean, validateBoolean("f"));
}

// ============================================================================
// URL Type Tests
// ============================================================================

test "url type accepts valid http and https URLs" {
    try validateUrl("http://example.com");
    try validateUrl("https://example.com");
    try validateUrl("http://example.com/path");
    try validateUrl("https://example.com/path?query=value");
    try validateUrl("http://subdomain.example.com");
    try validateUrl("https://example.com:8080");
    try validateUrl("http://localhost");
    try validateUrl("http://127.0.0.1");
}

test "url type requires http or https protocol" {
    try expectError(error.InvalidUrl, validateUrl("example.com"));
    try expectError(error.InvalidUrl, validateUrl("ftp://example.com"));
    try expectError(error.InvalidUrl, validateUrl("ws://example.com"));
    try expectError(error.InvalidUrl, validateUrl("//example.com"));
    try expectError(error.InvalidUrl, validateUrl("http://"));
    try expectError(error.InvalidUrl, validateUrl("https://"));
    try expectError(error.InvalidUrl, validateUrl(""));
}

// ============================================================================
// Connection String Type Tests
// ============================================================================

test "connection string accepts valid postgresql URLs" {
    try validateConnectionString("postgresql://localhost/mydb");
    try validateConnectionString("postgresql://user:pass@localhost/mydb");
    try validateConnectionString("postgresql://user:pass@localhost:5432/mydb");
    try validateConnectionString("postgresql://host/db?sslmode=require");
}

test "connection string accepts valid mysql URLs" {
    try validateConnectionString("mysql://localhost/mydb");
    try validateConnectionString("mysql://user:pass@localhost:3306/mydb");
}

test "connection string accepts valid mongodb URLs" {
    try validateConnectionString("mongodb://localhost/mydb");
    try validateConnectionString("mongodb://user:pass@localhost:27017/mydb");
}

test "connection string accepts valid redis URLs" {
    try validateConnectionString("redis://localhost");
    try validateConnectionString("redis://localhost:6379");
    try validateConnectionString("redis://:password@localhost:6379");
}

test "connection string rejects invalid protocols" {
    try expectError(error.InvalidConnectionString, validateConnectionString("http://localhost/db"));
    try expectError(error.InvalidConnectionString, validateConnectionString("sqlite://db.sqlite"));
    try expectError(error.InvalidConnectionString, validateConnectionString("localhost/mydb"));
    try expectError(error.InvalidConnectionString, validateConnectionString(""));
    try expectError(error.InvalidConnectionString, validateConnectionString("postgresql://"));
}

// ============================================================================
// Secret Type Tests
// ============================================================================

test "secret type accepts any string (same as string)" {
    try validateSecret("sk_test_abc123");
    try validateSecret("very-secret-key");
    try validateSecret("password123");
    try validateSecret("");
    try validateSecret("special!@#$%");
}

// ============================================================================
// Email Type Tests
// ============================================================================

test "email type accepts valid email addresses" {
    try validateEmail("user@example.com");
    try validateEmail("test.user@example.com");
    try validateEmail("user+tag@example.co.uk");
    try validateEmail("user_name@subdomain.example.com");
    try validateEmail("a@b.c");
}

test "email type requires @ symbol" {
    try expectError(error.InvalidEmail, validateEmail("userexample.com"));
    try expectError(error.InvalidEmail, validateEmail(""));
}

test "email type requires @ not at start or end" {
    try expectError(error.InvalidEmail, validateEmail("@example.com"));
    try expectError(error.InvalidEmail, validateEmail("user@"));
}

test "email type requires dot after @" {
    try expectError(error.InvalidEmail, validateEmail("user@example"));
    try expectError(error.InvalidEmail, validateEmail("user@com"));
}

test "email type requires valid domain structure" {
    try expectError(error.InvalidEmail, validateEmail("user@.com"));
    try expectError(error.InvalidEmail, validateEmail("user@example."));
}