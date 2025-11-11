// Re-export all validation-related types
pub const types = @import("validation/types.zig");
pub const field = @import("validation/field.zig");
pub const schema_parser = @import("validation/schema_parser.zig");

// Re-export commonly used types
pub const FieldType = field.FieldType;
pub const Field = field.Field;
pub const RequiredSpec = field.RequiredSpec;
pub const FieldValidationResult = field.FieldValidationResult;
pub const validateField = field.validateField;
pub const isRequired = field.isRequired;

// Schema parsing
pub const parseSchema = schema_parser.parseSchema;
pub const freeSchema = schema_parser.freeSchema;
