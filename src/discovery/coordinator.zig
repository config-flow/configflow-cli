const std = @import("std");
const scanner = @import("scanner.zig");
const parser_base = @import("parsers/parser.zig");
const javascript_parser = @import("parsers/javascript_parser.zig");
const python_parser = @import("parsers/python_parser.zig");
const ruby_parser = @import("parsers/ruby_parser.zig");
const java_parser = @import("parsers/java_parser.zig");
const go_parser = @import("parsers/go_parser.zig");
const framework_detector = @import("framework_detector.zig");
const framework_config = @import("framework_config.zig");
const framework_parser = @import("framework_parser.zig");
const embedded_frameworks = @import("embedded_frameworks.zig");
const ts = @import("tree_sitter");

const Scanner = scanner.Scanner;
const EnvVarUsage = parser_base.EnvVarUsage;
const Warning = parser_base.Warning;
const Parser = parser_base.Parser;
const JavaScriptParser = javascript_parser.JavaScriptParser;
const PythonParser = python_parser.PythonParser;
const RubyParser = ruby_parser.RubyParser;
const JavaParser = java_parser.JavaParser;
const GoParser = go_parser.GoParser;
const FrameworkDetector = framework_detector.FrameworkDetector;
const FrameworkConfig = framework_config.FrameworkConfig;
const FrameworkParser = framework_parser.FrameworkParser;

// External tree-sitter language parsers
extern fn tree_sitter_javascript() *const ts.Language;
extern fn tree_sitter_python() *const ts.Language;
extern fn tree_sitter_ruby() *const ts.Language;
extern fn tree_sitter_java() *const ts.Language;

/// Aggregated environment variable with multiple locations
pub const AggregatedEnvVar = struct {
    name: []const u8,
    inferred_type: parser_base.ConfigType,
    confidence: parser_base.Confidence,
    locations: []Location,
    default_values: [][]const u8, // List of unique default values found across all usages
    allocator: std.mem.Allocator,

    pub const Location = struct {
        file_path: []const u8,
        line_number: usize,
        context: ?[]const u8,
        default_value: ?[]const u8,
    };

    pub fn deinit(self: *AggregatedEnvVar) void {
        self.allocator.free(self.name);
        for (self.locations) |loc| {
            self.allocator.free(loc.file_path);
            if (loc.context) |ctx| {
                self.allocator.free(ctx);
            }
            if (loc.default_value) |val| {
                self.allocator.free(val);
            }
        }
        self.allocator.free(self.locations);
        for (self.default_values) |val| {
            self.allocator.free(val);
        }
        self.allocator.free(self.default_values);
    }
};

/// Discovery results
pub const DiscoveryResult = struct {
    env_vars: []AggregatedEnvVar,
    warnings: []Warning,
    files_scanned: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DiscoveryResult) void {
        for (self.env_vars) |*env_var| {
            env_var.deinit();
        }
        self.allocator.free(self.env_vars);

        for (self.warnings) |*warning| {
            warning.deinit();
        }
        self.allocator.free(self.warnings);
    }
};

/// Loaded framework with config and parser
const LoadedFramework = struct {
    name: []const u8,
    language: []const u8,
    config: FrameworkConfig,
    parser: FrameworkParser,

    pub fn deinit(self: *LoadedFramework) void {
        self.config.deinit();
        self.parser.deinit();
    }
};

/// Discovery coordinator
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    scanner_instance: Scanner,
    js_parser: ?*JavaScriptParser,
    py_parser: ?*PythonParser,
    rb_parser: ?*RubyParser,
    java_parser: ?*JavaParser,
    go_parser: ?*GoParser,
    framework_detector: FrameworkDetector,
    loaded_frameworks: std.ArrayList(LoadedFramework),

    pub fn init(allocator: std.mem.Allocator) !Coordinator {
        return .{
            .allocator = allocator,
            .scanner_instance = Scanner.init(allocator),
            .js_parser = null,
            .py_parser = null,
            .rb_parser = null,
            .java_parser = null,
            .go_parser = null,
            .framework_detector = FrameworkDetector.init(allocator),
            .loaded_frameworks = std.ArrayList(LoadedFramework){},
        };
    }

    pub fn deinit(self: *Coordinator) void {
        if (self.js_parser) |p| {
            p.parser().deinit();
        }
        if (self.py_parser) |p| {
            p.parser().deinit();
        }
        if (self.rb_parser) |p| {
            p.parser().deinit();
        }
        if (self.java_parser) |p| {
            p.parser().deinit();
        }
        if (self.go_parser) |p| {
            p.parser().deinit();
        }
        for (self.loaded_frameworks.items) |*framework| {
            framework.deinit();
        }
        self.loaded_frameworks.deinit(self.allocator);
    }

    /// Discover environment variables in a directory
    pub fn discover(
        self: *Coordinator,
        root_path: []const u8,
        progress_node: std.Progress.Node,
    ) !DiscoveryResult {
        // Detect frameworks
        var detect_node = progress_node.start("Detecting frameworks", 0);
        const detected_frameworks = try self.framework_detector.detectAll(root_path);
        defer {
            for (detected_frameworks) |*framework| {
                framework.deinit();
            }
            self.allocator.free(detected_frameworks);
        }
        detect_node.end();

        // Load framework configs
        for (detected_frameworks) |detected| {
            // Get embedded framework config content
            const config_content = embedded_frameworks.EmbeddedFrameworks.get(detected.config_path) orelse {
                std.debug.print("No embedded config found for path: {s}\n", .{detected.config_path});
                continue;
            };

            // Load framework config from embedded content
            var config = framework_config.loadFromContent(self.allocator, config_content) catch |err| {
                std.debug.print("Failed to load framework config for {s}: {}\n", .{ detected.name, err });
                continue;
            };
            errdefer config.deinit();

            // Get tree-sitter language for the framework
            const language = self.getLanguageForFramework(detected.language) catch |err| {
                std.debug.print("Failed to get language for framework {s}: {}\n", .{ detected.name, err });
                var mut_config = config;
                mut_config.deinit();
                continue;
            };

            // Initialize framework parser
            const fw_parser = FrameworkParser.init(self.allocator, config, language) catch |err| {
                std.debug.print("Failed to initialize parser for framework {s}: {}\n", .{ detected.name, err });
                var mut_config = config;
                mut_config.deinit();
                continue;
            };

            try self.loaded_frameworks.append(self.allocator, .{
                .name = detected.name,
                .language = detected.language,
                .config = config,
                .parser = fw_parser,
            });
        }

        // Scan for source files
        const extensions = &.{ ".js", ".jsx", ".ts", ".tsx", ".mjs", ".py", ".rb", ".java", ".go" };
        const scan_options = scanner.ScanOptions{
            .extensions = extensions,
        };

        var scan_node = progress_node.start("Scanning", 0);
        const files = try self.scanner_instance.scan(root_path, scan_options, scan_node);
        scan_node.end();
        defer {
            for (files) |file| {
                self.allocator.free(file);
            }
            self.allocator.free(files);
        }

        // Parse each file
        var all_usages = std.ArrayList(EnvVarUsage){};
        defer {
            for (all_usages.items) |*usage| {
                usage.deinit();
            }
            all_usages.deinit(self.allocator);
        }

        var all_warnings = std.ArrayList(Warning){};
        errdefer {
            for (all_warnings.items) |*warning| {
                warning.deinit();
            }
            all_warnings.deinit(self.allocator);
        }

        var parse_node = progress_node.start("Parsing", files.len);
        defer parse_node.end();

        for (files) |file_path| {
            try self.parseFile(file_path, &all_usages, &all_warnings);
            parse_node.completeOne();
        }

        // Aggregate results by env var name
        const aggregated = try self.aggregateUsages(all_usages.items);

        // Transfer ownership of warnings to result
        const warnings = try all_warnings.toOwnedSlice(self.allocator);

        return DiscoveryResult{
            .env_vars = aggregated,
            .warnings = warnings,
            .files_scanned = files.len,
            .allocator = self.allocator,
        };
    }

    /// Get tree-sitter language for a framework
    fn getLanguageForFramework(self: *Coordinator, language: []const u8) !*const ts.Language {
        _ = self; // unused
        if (std.mem.eql(u8, language, "javascript")) {
            return tree_sitter_javascript();
        } else if (std.mem.eql(u8, language, "python")) {
            return tree_sitter_python();
        } else if (std.mem.eql(u8, language, "ruby")) {
            return tree_sitter_ruby();
        } else if (std.mem.eql(u8, language, "java")) {
            return tree_sitter_java();
        } else {
            return error.UnsupportedLanguage;
        }
    }

    /// Parse a single file and append results
    fn parseFile(
        self: *Coordinator,
        file_path: []const u8,
        usages: *std.ArrayList(EnvVarUsage),
        warnings: *std.ArrayList(Warning),
    ) !void {
        // Determine file type
        const ext = std.fs.path.extension(file_path);
        const is_js = std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".jsx") or
            std.mem.eql(u8, ext, ".ts") or
            std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".mjs");
        const is_py = std.mem.eql(u8, ext, ".py");
        const is_rb = std.mem.eql(u8, ext, ".rb");
        const is_java = std.mem.eql(u8, ext, ".java");
        const is_go = std.mem.eql(u8, ext, ".go");

        // Select parser
        var selected_parser: ?Parser = null;

        if (is_js) {
            if (self.js_parser == null) {
                self.js_parser = try JavaScriptParser.init(self.allocator);
            }
            selected_parser = self.js_parser.?.parser();
        } else if (is_py) {
            if (self.py_parser == null) {
                self.py_parser = try PythonParser.init(self.allocator);
            }
            selected_parser = self.py_parser.?.parser();
        } else if (is_rb) {
            if (self.rb_parser == null) {
                self.rb_parser = try RubyParser.init(self.allocator);
            }
            selected_parser = self.rb_parser.?.parser();
        } else if (is_java) {
            if (self.java_parser == null) {
                self.java_parser = try JavaParser.init(self.allocator);
            }
            selected_parser = self.java_parser.?.parser();
        } else if (is_go) {
            if (self.go_parser == null) {
                self.go_parser = try GoParser.init(self.allocator);
            }
            selected_parser = self.go_parser.?.parser();
        }

        // Read file once for all parsers
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            // Skip files we can't open
            if (err == error.AccessDenied or err == error.FileNotFound) {
                return;
            }
            return err;
        };
        defer file.close();

        const source = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            // Skip files we can't read
            if (err == error.FileTooBig) {
                return;
            }
            return err;
        };
        defer self.allocator.free(source);

        // Parse with language parser if available
        if (selected_parser) |p| {
            const result = try p.discover(self.allocator, file_path, source);
            // Transfer ownership - don't call result.deinit() since we're taking the usages/warnings
            defer {
                // Just free the slices, not the items (ownership transferred to usages/warnings)
                self.allocator.free(result.usages);
                self.allocator.free(result.warnings);
            }

            // Append results (transfers ownership of strings)
            try usages.appendSlice(self.allocator, result.usages);
            try warnings.appendSlice(self.allocator, result.warnings);
        }

        // Also parse with framework parsers
        for (self.loaded_frameworks.items) |*framework| {
            // Determine if this framework applies to this file's language
            const applies = if (is_js and std.mem.eql(u8, framework.language, "javascript"))
                true
            else if (is_py and std.mem.eql(u8, framework.language, "python"))
                true
            else if (is_rb and std.mem.eql(u8, framework.language, "ruby"))
                true
            else if (is_java and std.mem.eql(u8, framework.language, "java"))
                true
            else
                false;

            if (applies) {
                var result = framework.parser.parse(source) catch |err| {
                    // Skip framework parsing errors
                    std.debug.print("Framework {s} parse error in {s}: {}\n", .{ framework.name, file_path, err });
                    continue;
                };
                defer result.deinit();

                // Update file paths in usages
                for (result.usages) |*usage| {
                    self.allocator.free(usage.file_path);
                    usage.file_path = try self.allocator.dupe(u8, file_path);
                }

                // Transfer ownership
                try usages.appendSlice(self.allocator, result.usages);
                self.allocator.free(result.usages);
                result.usages = &.{}; // Prevent double-free
            }
        }
    }

    /// Aggregate usages by variable name
    fn aggregateUsages(
        self: *Coordinator,
        usages: []EnvVarUsage,
    ) ![]AggregatedEnvVar {
        var map = std.StringHashMap(AggregatedEnvVarBuilder).init(self.allocator);
        defer {
            var iter = map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.locations.deinit(self.allocator);
                // Free default value keys in the hash map
                var default_iter = entry.value_ptr.default_values_set.keyIterator();
                while (default_iter.next()) |key| {
                    self.allocator.free(key.*);
                }
                entry.value_ptr.default_values_set.deinit();
            }
            map.deinit();
        }

        // Group by name
        for (usages) |usage| {
            const entry = try map.getOrPut(usage.name);
            if (!entry.found_existing) {
                entry.key_ptr.* = try self.allocator.dupe(u8, usage.name);
                entry.value_ptr.* = .{
                    .inferred_type = usage.inferred_type,
                    .confidence = usage.confidence,
                    .locations = std.ArrayList(AggregatedEnvVar.Location){},
                    .default_values_set = std.StringHashMap(void).init(self.allocator),
                };
            }

            // Add location
            const loc = AggregatedEnvVar.Location{
                .file_path = try self.allocator.dupe(u8, usage.file_path),
                .line_number = usage.line_number,
                .context = if (usage.context) |ctx|
                    try self.allocator.dupe(u8, ctx)
                else
                    null,
                .default_value = if (usage.default_value) |val|
                    try self.allocator.dupe(u8, val)
                else
                    null,
            };
            try entry.value_ptr.locations.append(self.allocator, loc);

            // Track unique default values
            if (usage.default_value) |val| {
                const default_entry = try entry.value_ptr.default_values_set.getOrPut(val);
                if (!default_entry.found_existing) {
                    default_entry.key_ptr.* = try self.allocator.dupe(u8, val);
                }
            }

            // Update type/confidence if we find higher confidence
            // Lower enum values represent higher confidence (high=0, medium=1, low=2)
            if (@intFromEnum(usage.confidence) < @intFromEnum(entry.value_ptr.confidence)) {
                entry.value_ptr.inferred_type = usage.inferred_type;
                entry.value_ptr.confidence = usage.confidence;
            }
        }

        // Convert to array
        var result = std.ArrayList(AggregatedEnvVar){};
        errdefer {
            for (result.items) |*item| {
                item.deinit();
            }
            result.deinit(self.allocator);
        }

        var iter = map.iterator();
        while (iter.next()) |entry| {
            // Convert default values set to array
            var default_values_list = std.ArrayList([]const u8){};
            var default_iter = entry.value_ptr.default_values_set.keyIterator();
            while (default_iter.next()) |key| {
                try default_values_list.append(self.allocator, try self.allocator.dupe(u8, key.*));
            }

            const agg = AggregatedEnvVar{
                .name = try self.allocator.dupe(u8, entry.key_ptr.*),
                .inferred_type = entry.value_ptr.inferred_type,
                .confidence = entry.value_ptr.confidence,
                .locations = try entry.value_ptr.locations.toOwnedSlice(self.allocator),
                .default_values = try default_values_list.toOwnedSlice(self.allocator),
                .allocator = self.allocator,
            };
            try result.append(self.allocator, agg);
        }

        return result.toOwnedSlice(self.allocator);
    }
};

const AggregatedEnvVarBuilder = struct {
    inferred_type: parser_base.ConfigType,
    confidence: parser_base.Confidence,
    locations: std.ArrayList(AggregatedEnvVar.Location),
    default_values_set: std.StringHashMap(void), // Track unique default values
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "Coordinator init and deinit" {
    const allocator = std.testing.allocator;
    var coord = try Coordinator.init(allocator);
    defer coord.deinit();
}

test "Coordinator discovers JavaScript files" {
    const allocator = std.testing.allocator;
    var coord = try Coordinator.init(allocator);
    defer coord.deinit();

    // Create temporary test directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test JavaScript file
    try tmp_dir.dir.writeFile(.{
        .sub_path = "app.js",
        .data =
        \\const port = parseInt(process.env.PORT);
        \\const apiKey = process.env.API_KEY;
        ,
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Discover
    var result = try coord.discover(tmp_path, std.Progress.Node.none);
    defer result.deinit();

    // Should find 2 env vars
    try expectEqual(@as(usize, 2), result.env_vars.len);
    try expectEqual(@as(usize, 1), result.files_scanned);
}

test "Coordinator discovers Python files" {
    const allocator = std.testing.allocator;
    var coord = try Coordinator.init(allocator);
    defer coord.deinit();

    // Create temporary test directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test Python file
    try tmp_dir.dir.writeFile(.{
        .sub_path = "app.py",
        .data =
        \\import os
        \\port = int(os.environ["PORT"])
        \\db = os.getenv("DATABASE_URL")
        ,
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Discover
    var result = try coord.discover(tmp_path, std.Progress.Node.none);
    defer result.deinit();

    // Should find 2 env vars
    try expectEqual(@as(usize, 2), result.env_vars.len);
    try expectEqual(@as(usize, 1), result.files_scanned);
}

test "Coordinator aggregates duplicate env vars" {
    const allocator = std.testing.allocator;
    var coord = try Coordinator.init(allocator);
    defer coord.deinit();

    // Create temporary test directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create two files using the same env var
    try tmp_dir.dir.writeFile(.{
        .sub_path = "server.js",
        .data = "const port = process.env.PORT;",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "config.js",
        .data = "const port = parseInt(process.env.PORT);",
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Discover
    var result = try coord.discover(tmp_path, std.Progress.Node.none);
    defer result.deinit();

    // Should find 1 aggregated env var
    try expectEqual(@as(usize, 1), result.env_vars.len);
    try expectEqual(@as(usize, 2), result.files_scanned);

    // Should have 2 locations
    try expectEqual(@as(usize, 2), result.env_vars[0].locations.len);

    // Should pick highest confidence (high from parseInt)
    try expectEqualStrings("PORT", result.env_vars[0].name);
    try expectEqual(parser_base.Confidence.high, result.env_vars[0].confidence);
}

test "Coordinator discovers Ruby files" {
    const allocator = std.testing.allocator;
    var coord = try Coordinator.init(allocator);
    defer coord.deinit();

    // Create temporary test directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test Ruby file
    try tmp_dir.dir.writeFile(.{
        .sub_path = "config.rb",
        .data =
        \\port = ENV['PORT'].to_i
        \\db_url = ENV.fetch('DATABASE_URL')
        ,
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Discover
    var result = try coord.discover(tmp_path, std.Progress.Node.none);
    defer result.deinit();

    // Should find 2 env vars
    try expectEqual(@as(usize, 2), result.env_vars.len);
    try expectEqual(@as(usize, 1), result.files_scanned);
}

test "Coordinator handles mixed languages" {
    const allocator = std.testing.allocator;
    var coord = try Coordinator.init(allocator);
    defer coord.deinit();

    // Create temporary test directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create JavaScript, Python, and Ruby files
    try tmp_dir.dir.writeFile(.{
        .sub_path = "app.js",
        .data = "const port = process.env.PORT;",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "worker.py",
        .data = "import os\ndb = os.getenv('DATABASE_URL')",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "config.rb",
        .data = "api_key = ENV['API_KEY']",
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Discover
    var result = try coord.discover(tmp_path, std.Progress.Node.none);
    defer result.deinit();

    // Should find 3 env vars from different languages
    try expectEqual(@as(usize, 3), result.env_vars.len);
    try expectEqual(@as(usize, 3), result.files_scanned);
}
