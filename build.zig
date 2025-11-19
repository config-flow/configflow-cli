const std = @import("std");
const zcli = @import("zcli");

/// Tree-sitter grammar configuration
const Grammar = struct {
    dep: *std.Build.Dependency,
    src_path: std.Build.LazyPath,
    has_scanner: bool,

    fn addToCompile(self: Grammar, compile: *std.Build.Step.Compile) void {
        compile.addIncludePath(self.src_path);
        compile.linkLibC();

        if (self.has_scanner) {
            compile.addCSourceFiles(.{
                .root = self.src_path,
                .files = &.{ "parser.c", "scanner.c" },
                .flags = &.{"-std=c11"},
            });
        } else {
            compile.addCSourceFiles(.{
                .root = self.src_path,
                .files = &.{"parser.c"},
                .flags = &.{"-std=c11"},
            });
        }
    }
};

/// Get a tree-sitter grammar dependency
fn getGrammar(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep_name: []const u8,
    has_scanner: bool,
) Grammar {
    const dep = b.dependency(dep_name, .{
        .target = target,
        .optimize = optimize,
    });

    return .{
        .dep = dep,
        .src_path = dep.path("src"),
        .has_scanner = has_scanner,
    };
}

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

    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter_module = tree_sitter_dep.module("tree_sitter");

    // Create clients module
    const clients_module = b.createModule(.{
        .root_source_file = b.path("src/clients.zig"),
    });

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

    // Create discovery module (uses zig-tree-sitter bindings and yaml for framework configs)
    const discovery_module = b.createModule(.{
        .root_source_file = b.path("src/discovery.zig"),
        .imports = &.{
            .{ .name = "tree_sitter", .module = tree_sitter_module },
            .{ .name = "yaml", .module = yaml_module },
        },
    });

    // Get tree-sitter grammar dependencies
    const js_grammar = getGrammar(b, target, optimize, "tree_sitter_javascript", true);
    const py_grammar = getGrammar(b, target, optimize, "tree_sitter_python", true);
    const rb_grammar = getGrammar(b, target, optimize, "tree_sitter_ruby", true);
    const java_grammar = getGrammar(b, target, optimize, "tree_sitter_java", false);
    const go_grammar = getGrammar(b, target, optimize, "tree_sitter_go", false);

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

    // Add tree-sitter grammars to executable
    js_grammar.addToCompile(exe);
    py_grammar.addToCompile(exe);
    rb_grammar.addToCompile(exe);
    java_grammar.addToCompile(exe);
    go_grammar.addToCompile(exe);

    // Generate command registry
    const cmd_registry = zcli.generate(b, exe, zcli_dep, zcli_module, .{
        .commands_dir = "src/commands",
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "yaml", .module = yaml_module },
            .{ .name = "sources", .module = sources_module },
            .{ .name = "validation", .module = validation_module },
            .{ .name = "discovery", .module = discovery_module },
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

    // Add AWS client tests
    const test_aws_client = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/aws_secrets_manager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add AWS source tests
    const test_aws_source = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sources/aws_source.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clients", .module = clients_module },
            },
        }),
    });

    // Add parser base tests
    const test_parser = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/parsers/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add scanner tests
    const test_scanner = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/scanner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add JavaScript parser tests
    const test_js_parser = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/parsers/javascript_parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree_sitter", .module = tree_sitter_module },
            },
        }),
    });
    js_grammar.addToCompile(test_js_parser);

    // Add Python parser tests
    const test_py_parser = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/parsers/python_parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree_sitter", .module = tree_sitter_module },
            },
        }),
    });
    py_grammar.addToCompile(test_py_parser);

    // Add Ruby parser tests
    const test_rb_parser = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/parsers/ruby_parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree_sitter", .module = tree_sitter_module },
            },
        }),
    });
    rb_grammar.addToCompile(test_rb_parser);

    // Add Java parser tests
    const test_java_parser = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/parsers/java_parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree_sitter", .module = tree_sitter_module },
            },
        }),
    });
    java_grammar.addToCompile(test_java_parser);

    // Add Go parser tests
    const test_go_parser = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/parsers/go_parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree_sitter", .module = tree_sitter_module },
            },
        }),
    });
    go_grammar.addToCompile(test_go_parser);

    // Add discovery coordinator tests
    const test_coordinator = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/coordinator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree_sitter", .module = tree_sitter_module },
                .{ .name = "yaml", .module = yaml_module },
            },
        }),
    });
    js_grammar.addToCompile(test_coordinator);
    py_grammar.addToCompile(test_coordinator);
    rb_grammar.addToCompile(test_coordinator);
    java_grammar.addToCompile(test_coordinator);
    go_grammar.addToCompile(test_coordinator);

    // Add framework config tests
    const test_framework_config = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/framework_config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaml", .module = yaml_module },
            },
        }),
    });

    // Add framework detector tests
    const test_framework_detector = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/framework_detector.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add framework parser tests
    const test_framework_parser = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/discovery/framework_parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree_sitter", .module = tree_sitter_module },
                .{ .name = "yaml", .module = yaml_module },
            },
        }),
    });
    js_grammar.addToCompile(test_framework_parser);

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
    const run_test_aws_client = b.addRunArtifact(test_aws_client);
    const run_test_aws_source = b.addRunArtifact(test_aws_source);
    const run_test_parser = b.addRunArtifact(test_parser);
    const run_test_scanner = b.addRunArtifact(test_scanner);
    const run_test_js_parser = b.addRunArtifact(test_js_parser);
    const run_test_py_parser = b.addRunArtifact(test_py_parser);
    const run_test_rb_parser = b.addRunArtifact(test_rb_parser);
    const run_test_java_parser = b.addRunArtifact(test_java_parser);
    const run_test_go_parser = b.addRunArtifact(test_go_parser);
    const run_test_coordinator = b.addRunArtifact(test_coordinator);
    const run_test_framework_config = b.addRunArtifact(test_framework_config);
    const run_test_framework_detector = b.addRunArtifact(test_framework_detector);
    const run_test_framework_parser = b.addRunArtifact(test_framework_parser);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_test_validation_types.step);
    test_step.dependOn(&run_test_validation_field.step);
    test_step.dependOn(&run_test_validation_schema_parser.step);
    test_step.dependOn(&run_test_file_source.step);
    test_step.dependOn(&run_test_env_source.step);
    test_step.dependOn(&run_test_aws_client.step);
    test_step.dependOn(&run_test_aws_source.step);
    test_step.dependOn(&run_test_parser.step);
    test_step.dependOn(&run_test_scanner.step);
    test_step.dependOn(&run_test_js_parser.step);
    test_step.dependOn(&run_test_py_parser.step);
    test_step.dependOn(&run_test_rb_parser.step);
    test_step.dependOn(&run_test_java_parser.step);
    test_step.dependOn(&run_test_go_parser.step);
    test_step.dependOn(&run_test_coordinator.step);
    test_step.dependOn(&run_test_framework_config.step);
    test_step.dependOn(&run_test_framework_detector.step);
    test_step.dependOn(&run_test_framework_parser.step);
}
