const std = @import("std");

/// Embedded framework configuration files
/// These are compiled into the binary at build time using @embedFile
pub const EmbeddedFrameworks = struct {
    // JavaScript frameworks
    pub const nestjs = @embedFile("parsers/frameworks/javascript/nestjs.yml");
    pub const nextjs = @embedFile("parsers/frameworks/javascript/nextjs.yml");
    pub const vite = @embedFile("parsers/frameworks/javascript/vite.yml");

    // Python frameworks
    pub const django = @embedFile("parsers/frameworks/python/django.yml");
    pub const pydantic = @embedFile("parsers/frameworks/python/pydantic.yml");

    // Java frameworks
    pub const spring = @embedFile("parsers/frameworks/java/spring.yml");

    // Ruby frameworks
    pub const rails = @embedFile("parsers/frameworks/ruby/rails.yml");

    /// Get embedded framework config by path
    pub fn get(path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "javascript/nestjs.yml")) return nestjs;
        if (std.mem.eql(u8, path, "javascript/nextjs.yml")) return nextjs;
        if (std.mem.eql(u8, path, "javascript/vite.yml")) return vite;
        if (std.mem.eql(u8, path, "python/django.yml")) return django;
        if (std.mem.eql(u8, path, "python/pydantic.yml")) return pydantic;
        if (std.mem.eql(u8, path, "java/spring.yml")) return spring;
        if (std.mem.eql(u8, path, "ruby/rails.yml")) return rails;
        return null;
    }
};
