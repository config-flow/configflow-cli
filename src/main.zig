const std = @import("std");
const zcli = @import("zcli");
const cmd_registry = @import("command_registry");

// Configure logging - silence zig-yaml's verbose debug output
pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .tokenizer, .level = .err },
        .{ .scope = .parser, .level = .err },
        .{ .scope = .yaml, .level = .err },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var app = cmd_registry.init();
    try app.execute(allocator, args[1..]);
}
