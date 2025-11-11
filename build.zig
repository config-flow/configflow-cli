const std = @import("std");
const zcli = @import("zcli");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_module = zcli_dep.module("zcli");

    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const yaml_module = yaml_dep.module("yaml");

    // Create sources module
    const sources_module = b.createModule(.{
        .root_source_file = b.path("src/sources.zig"),
        .imports = &.{
            .{ .name = "yaml", .module = yaml_module },
        },
    });

    // Create validation module
    const validation_module = b.createModule(.{
        .root_source_file = b.path("src/validation.zig"),
        .imports = &.{
            .{ .name = "yaml", .module = yaml_module },
        },
    });

    // Create executable
    const exe = b.addExecutable(.{
        .name = "configflow",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcli", .module = zcli_module },
                .{ .name = "yaml", .module = yaml_module },
            },
        }),
    });

    // Generate command registry
    const cmd_registry = zcli.generate(b, exe, zcli_dep, zcli_module, .{
        .commands_dir = "src/commands",
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "yaml", .module = yaml_module },
            .{ .name = "sources", .module = sources_module },
            .{ .name = "validation", .module = validation_module },
        },
        .plugins = &.{ .{
            .name = "zcli_help",
            .path = "src/plugins/zcli_help",
        }, .{
            .name = "zcli_version",
            .path = "src/plugins/zcli_version",
        }, .{
            .name = "zcli_not_found",
            .path = "src/plugins/zcli_not_found",
        }, .{
            .name = "zcli_github_upgrade",
            .path = "src/plugins/zcli_github_upgrade",
            .config = .{
                .repo = "config-flow/configflow-cli",
                .command_name = "upgrade",
                .inform_out_of_date = false,
            },
        }, .{
            .name = "zcli_completions",
            .path = "src/plugins/zcli_completions",
        } },
        .app_name = "configflow",
        .app_description = "Type-safe configuration with clarity for developers",
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);

    // Add run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // Add validation type tests
    const test_validation_types = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/validation/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add validation field tests
    const test_validation_field = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/validation/field.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add validation schema parser tests
    const test_validation_schema_parser = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/validation/schema_parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaml", .module = yaml_module },
            },
        }),
    });

    // Add file source tests
    const test_file_source = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sources/file_source.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add env source tests
    const test_env_source = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sources/env_source.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add test step
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcli", .module = zcli_module },
                .{ .name = "yaml", .module = yaml_module },
                .{ .name = "command_registry", .module = cmd_registry },
            },
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_test_validation_types = b.addRunArtifact(test_validation_types);
    const run_test_validation_field = b.addRunArtifact(test_validation_field);
    const run_test_validation_schema_parser = b.addRunArtifact(test_validation_schema_parser);
    const run_test_file_source = b.addRunArtifact(test_file_source);
    const run_test_env_source = b.addRunArtifact(test_env_source);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_test_validation_types.step);
    test_step.dependOn(&run_test_validation_field.step);
    test_step.dependOn(&run_test_validation_schema_parser.step);
    test_step.dependOn(&run_test_file_source.step);
    test_step.dependOn(&run_test_env_source.step);
}
