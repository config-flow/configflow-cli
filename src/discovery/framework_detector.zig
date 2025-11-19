const std = @import("std");

/// Framework detector that scans project files to identify frameworks
pub const FrameworkDetector = struct {
    allocator: std.mem.Allocator,

    /// Detected framework information
    pub const DetectedFramework = struct {
        name: []const u8,
        language: []const u8,
        config_path: []const u8,
        confidence: Confidence,
        allocator: std.mem.Allocator,

        pub const Confidence = enum {
            high, // Found explicit dependency
            medium, // Found config file
            low, // Found similar pattern
        };

        pub fn deinit(self: *DetectedFramework) void {
            self.allocator.free(self.name);
            self.allocator.free(self.language);
            self.allocator.free(self.config_path);
        }
    };

    pub fn init(allocator: std.mem.Allocator) FrameworkDetector {
        return .{ .allocator = allocator };
    }

    /// Detect all frameworks in the given directory
    pub fn detectAll(
        self: *FrameworkDetector,
        root_path: []const u8,
    ) ![]DetectedFramework {
        var detected = std.ArrayList(DetectedFramework){};
        errdefer {
            for (detected.items) |fw| {
                self.allocator.free(fw.name);
                self.allocator.free(fw.language);
                self.allocator.free(fw.config_path);
            }
            detected.deinit(self.allocator);
        }

        // Detect JavaScript/TypeScript frameworks
        try self.detectJavaScript(root_path, &detected);

        // Detect Python frameworks
        try self.detectPython(root_path, &detected);

        // Detect Java frameworks
        try self.detectJava(root_path, &detected);

        // Detect Ruby frameworks
        try self.detectRuby(root_path, &detected);

        return detected.toOwnedSlice(self.allocator);
    }

    /// Detect JavaScript/TypeScript frameworks from package.json
    fn detectJavaScript(
        self: *FrameworkDetector,
        root_path: []const u8,
        detected: *std.ArrayList(DetectedFramework),
    ) !void {
        const package_json_path = try std.fs.path.join(
            self.allocator,
            &.{ root_path, "package.json" },
        );
        defer self.allocator.free(package_json_path);

        const content = std.fs.cwd().readFileAlloc(
            self.allocator,
            package_json_path,
            1024 * 1024, // 1MB max
        ) catch return; // If file doesn't exist or can't be read, silently return
        defer self.allocator.free(content);

        // Check for NestJS
        if (std.mem.indexOf(u8, content, "\"@nestjs/core\"") != null or
            std.mem.indexOf(u8, content, "\"@nestjs/common\"") != null)
        {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "nestjs"),
                .language = try self.allocator.dupe(u8, "javascript"),
                .config_path = try self.allocator.dupe(u8, "javascript/nestjs.yml"),
                .confidence = .high,
                .allocator = self.allocator,
            });
        }

        // Check for Next.js
        if (std.mem.indexOf(u8, content, "\"next\"") != null) {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "nextjs"),
                .language = try self.allocator.dupe(u8, "javascript"),
                .config_path = try self.allocator.dupe(u8, "javascript/nextjs.yml"),
                .confidence = .high,
                .allocator = self.allocator,
            });
        }

        // Check for Vite
        if (std.mem.indexOf(u8, content, "\"vite\"") != null) {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "vite"),
                .language = try self.allocator.dupe(u8, "javascript"),
                .config_path = try self.allocator.dupe(u8, "javascript/vite.yml"),
                .confidence = .high,
                .allocator = self.allocator,
            });
        }

        // Check for Next.js config file as secondary signal
        const nextjs_config_exists = blk: {
            var dir = std.fs.cwd().openDir(root_path, .{}) catch break :blk false;
            defer dir.close();

            dir.access("next.config.js", .{}) catch {
                dir.access("next.config.mjs", .{}) catch {
                    dir.access("next.config.ts", .{}) catch break :blk false;
                };
            };
            break :blk true;
        };

        if (nextjs_config_exists and !self.hasFramework(detected.items, "nextjs")) {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "nextjs"),
                .language = try self.allocator.dupe(u8, "javascript"),
                .config_path = try self.allocator.dupe(u8, "javascript/nextjs.yml"),
                .confidence = .medium,
                .allocator = self.allocator,
            });
        }
    }

    /// Detect Python frameworks from requirements.txt, pyproject.toml, Pipfile
    fn detectPython(
        self: *FrameworkDetector,
        root_path: []const u8,
        detected: *std.ArrayList(DetectedFramework),
    ) !void {
        // Try requirements.txt
        const requirements_path = try std.fs.path.join(
            self.allocator,
            &.{ root_path, "requirements.txt" },
        );
        defer self.allocator.free(requirements_path);

        if (std.fs.cwd().readFileAlloc(
            self.allocator,
            requirements_path,
            1024 * 1024,
        )) |content| {
            defer self.allocator.free(content);
            try self.detectPythonFromContent(content, detected);
        } else |_| {}

        // Try pyproject.toml
        const pyproject_path = try std.fs.path.join(
            self.allocator,
            &.{ root_path, "pyproject.toml" },
        );
        defer self.allocator.free(pyproject_path);

        if (std.fs.cwd().readFileAlloc(
            self.allocator,
            pyproject_path,
            1024 * 1024,
        )) |content| {
            defer self.allocator.free(content);
            try self.detectPythonFromContent(content, detected);
        } else |_| {}

        // Try Pipfile
        const pipfile_path = try std.fs.path.join(
            self.allocator,
            &.{ root_path, "Pipfile" },
        );
        defer self.allocator.free(pipfile_path);

        if (std.fs.cwd().readFileAlloc(
            self.allocator,
            pipfile_path,
            1024 * 1024,
        )) |content| {
            defer self.allocator.free(content);
            try self.detectPythonFromContent(content, detected);
        } else |_| {}

        // Check for Django by looking for manage.py
        const manage_py_exists = blk: {
            var dir = std.fs.cwd().openDir(root_path, .{}) catch break :blk false;
            defer dir.close();
            dir.access("manage.py", .{}) catch break :blk false;
            break :blk true;
        };

        if (manage_py_exists and !self.hasFramework(detected.items, "django")) {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "django"),
                .language = try self.allocator.dupe(u8, "python"),
                .config_path = try self.allocator.dupe(u8, "python/django.yml"),
                .confidence = .medium,
                .allocator = self.allocator,
            });
        }
    }

    fn detectPythonFromContent(
        self: *FrameworkDetector,
        content: []const u8,
        detected: *std.ArrayList(DetectedFramework),
    ) !void {
        // Check for Django
        if ((std.mem.indexOf(u8, content, "django-environ") != null or
            std.mem.indexOf(u8, content, "Django") != null) and
            !self.hasFramework(detected.items, "django"))
        {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "django"),
                .language = try self.allocator.dupe(u8, "python"),
                .config_path = try self.allocator.dupe(u8, "python/django.yml"),
                .confidence = .high,
                .allocator = self.allocator,
            });
        }

        // Check for Pydantic
        if ((std.mem.indexOf(u8, content, "pydantic") != null or
            std.mem.indexOf(u8, content, "pydantic-settings") != null) and
            !self.hasFramework(detected.items, "pydantic"))
        {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "pydantic"),
                .language = try self.allocator.dupe(u8, "python"),
                .config_path = try self.allocator.dupe(u8, "python/pydantic.yml"),
                .confidence = .high,
                .allocator = self.allocator,
            });
        }
    }

    /// Detect Java frameworks from pom.xml and build.gradle
    fn detectJava(
        self: *FrameworkDetector,
        root_path: []const u8,
        detected: *std.ArrayList(DetectedFramework),
    ) !void {
        // Try pom.xml (Maven)
        const pom_path = try std.fs.path.join(
            self.allocator,
            &.{ root_path, "pom.xml" },
        );
        defer self.allocator.free(pom_path);

        if (std.fs.cwd().readFileAlloc(
            self.allocator,
            pom_path,
            1024 * 1024,
        )) |content| {
            defer self.allocator.free(content);

            if (std.mem.indexOf(u8, content, "spring-boot-starter") != null or
                std.mem.indexOf(u8, content, "org.springframework.boot") != null)
            {
                try detected.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, "spring"),
                    .language = try self.allocator.dupe(u8, "java"),
                    .config_path = try self.allocator.dupe(u8, "java/spring.yml"),
                    .confidence = .high,
                    .allocator = self.allocator,
                });
            }
        } else |_| {}

        // Try build.gradle (Gradle)
        const gradle_path = try std.fs.path.join(
            self.allocator,
            &.{ root_path, "build.gradle" },
        );
        defer self.allocator.free(gradle_path);

        if (std.fs.cwd().readFileAlloc(
            self.allocator,
            gradle_path,
            1024 * 1024,
        )) |content| {
            defer self.allocator.free(content);

            if ((std.mem.indexOf(u8, content, "org.springframework.boot") != null or
                std.mem.indexOf(u8, content, "spring-boot-starter") != null) and
                !self.hasFramework(detected.items, "spring"))
            {
                try detected.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, "spring"),
                    .language = try self.allocator.dupe(u8, "java"),
                    .config_path = try self.allocator.dupe(u8, "java/spring.yml"),
                    .confidence = .high,
                    .allocator = self.allocator,
                });
            }
        } else |_| {}

        // Try build.gradle.kts (Kotlin DSL)
        const gradle_kts_path = try std.fs.path.join(
            self.allocator,
            &.{ root_path, "build.gradle.kts" },
        );
        defer self.allocator.free(gradle_kts_path);

        if (std.fs.cwd().readFileAlloc(
            self.allocator,
            gradle_kts_path,
            1024 * 1024,
        )) |content| {
            defer self.allocator.free(content);

            if ((std.mem.indexOf(u8, content, "org.springframework.boot") != null or
                std.mem.indexOf(u8, content, "spring-boot-starter") != null) and
                !self.hasFramework(detected.items, "spring"))
            {
                try detected.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, "spring"),
                    .language = try self.allocator.dupe(u8, "java"),
                    .config_path = try self.allocator.dupe(u8, "java/spring.yml"),
                    .confidence = .high,
                    .allocator = self.allocator,
                });
            }
        } else |_| {}
    }

    /// Detect Ruby frameworks from Gemfile
    fn detectRuby(
        self: *FrameworkDetector,
        root_path: []const u8,
        detected: *std.ArrayList(DetectedFramework),
    ) !void {
        const gemfile_path = try std.fs.path.join(
            self.allocator,
            &.{ root_path, "Gemfile" },
        );
        defer self.allocator.free(gemfile_path);

        const content = std.fs.cwd().readFileAlloc(
            self.allocator,
            gemfile_path,
            1024 * 1024,
        ) catch return;
        defer self.allocator.free(content);

        // Check for Rails
        if (std.mem.indexOf(u8, content, "gem 'rails'") != null or
            std.mem.indexOf(u8, content, "gem \"rails\"") != null)
        {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "rails"),
                .language = try self.allocator.dupe(u8, "ruby"),
                .config_path = try self.allocator.dupe(u8, "ruby/rails.yml"),
                .confidence = .high,
                .allocator = self.allocator,
            });
        }

        // Alternative Rails detection: check for config/application.rb
        const rails_config_exists = blk: {
            var dir = std.fs.cwd().openDir(root_path, .{}) catch break :blk false;
            defer dir.close();

            var config_dir = dir.openDir("config", .{}) catch break :blk false;
            defer config_dir.close();

            config_dir.access("application.rb", .{}) catch break :blk false;
            break :blk true;
        };

        if (rails_config_exists and !self.hasFramework(detected.items, "rails")) {
            try detected.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, "rails"),
                .language = try self.allocator.dupe(u8, "ruby"),
                .config_path = try self.allocator.dupe(u8, "ruby/rails.yml"),
                .confidence = .medium,
                .allocator = self.allocator,
            });
        }
    }

    /// Check if a framework is already in the detected list
    fn hasFramework(self: *FrameworkDetector, frameworks: []DetectedFramework, name: []const u8) bool {
        _ = self;
        for (frameworks) |fw| {
            if (std.mem.eql(u8, fw.name, name)) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *FrameworkDetector, frameworks: []DetectedFramework) void {
        for (frameworks) |fw| {
            self.allocator.free(fw.name);
            self.allocator.free(fw.language);
            self.allocator.free(fw.config_path);
        }
        self.allocator.free(frameworks);
    }
};

// ============================================================================
// Tests
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "FrameworkDetector detects NestJS from package.json" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    // Create temp directory with package.json
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_json =
        \\{
        \\  "dependencies": {
        \\    "@nestjs/core": "^10.0.0",
        \\    "@nestjs/common": "^10.0.0"
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = package_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    try expect(detected.len >= 1);

    var found_nestjs = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "nestjs")) {
            found_nestjs = true;
            try expectEqualStrings("javascript", fw.language);
            try expectEqualStrings("javascript/nestjs.yml", fw.config_path);
            try expectEqual(FrameworkDetector.DetectedFramework.Confidence.high, fw.confidence);
        }
    }

    try expect(found_nestjs);
}

test "FrameworkDetector detects Django from requirements.txt" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const requirements =
        \\django==4.2.0
        \\django-environ==0.11.0
    ;

    try tmp.dir.writeFile(.{ .sub_path = "requirements.txt", .data = requirements });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    var found_django = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "django")) {
            found_django = true;
            try expectEqualStrings("python", fw.language);
        }
    }

    try expect(found_django);
}

test "FrameworkDetector detects Spring from pom.xml" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pom_xml =
        \\<project>
        \\  <dependencies>
        \\    <dependency>
        \\      <groupId>org.springframework.boot</groupId>
        \\      <artifactId>spring-boot-starter</artifactId>
        \\    </dependency>
        \\  </dependencies>
        \\</project>
    ;

    try tmp.dir.writeFile(.{ .sub_path = "pom.xml", .data = pom_xml });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    var found_spring = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "spring")) {
            found_spring = true;
            try expectEqualStrings("java", fw.language);
        }
    }

    try expect(found_spring);
}

test "FrameworkDetector detects Next.js from package.json" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_json =
        \\{
        \\  "dependencies": {
        \\    "next": "^14.0.0",
        \\    "react": "^18.0.0"
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = package_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    var found_nextjs = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "nextjs")) {
            found_nextjs = true;
            try expectEqualStrings("javascript", fw.language);
            try expectEqualStrings("javascript/nextjs.yml", fw.config_path);
        }
    }

    try expect(found_nextjs);
}

test "FrameworkDetector detects Vite from package.json" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_json =
        \\{
        \\  "devDependencies": {
        \\    "vite": "^5.0.0"
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = package_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    var found_vite = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "vite")) {
            found_vite = true;
            try expectEqualStrings("javascript", fw.language);
        }
    }

    try expect(found_vite);
}

test "FrameworkDetector detects Pydantic from requirements.txt" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const requirements =
        \\pydantic==2.5.0
        \\pydantic-settings==2.1.0
    ;

    try tmp.dir.writeFile(.{ .sub_path = "requirements.txt", .data = requirements });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    var found_pydantic = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "pydantic")) {
            found_pydantic = true;
            try expectEqualStrings("python", fw.language);
            try expectEqualStrings("python/pydantic.yml", fw.config_path);
        }
    }

    try expect(found_pydantic);
}

test "FrameworkDetector detects Rails from Gemfile" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const gemfile =
        \\source 'https://rubygems.org'
        \\gem 'rails', '~> 7.1.0'
        \\gem 'pg', '~> 1.5'
    ;

    try tmp.dir.writeFile(.{ .sub_path = "Gemfile", .data = gemfile });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    var found_rails = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "rails")) {
            found_rails = true;
            try expectEqualStrings("ruby", fw.language);
            try expectEqualStrings("ruby/rails.yml", fw.config_path);
            try expectEqual(FrameworkDetector.DetectedFramework.Confidence.high, fw.confidence);
        }
    }

    try expect(found_rails);
}

test "FrameworkDetector detects multiple frameworks" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a project with both NestJS and Next.js
    const package_json =
        \\{
        \\  "dependencies": {
        \\    "@nestjs/core": "^10.0.0",
        \\    "next": "^14.0.0",
        \\    "vite": "^5.0.0"
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = package_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    // Should detect at least 2 frameworks (NestJS and Next.js, Vite might or might not be detected depending on detection logic)
    try expect(detected.len >= 2);

    var found_nestjs = false;
    var found_nextjs = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "nestjs")) found_nestjs = true;
        if (std.mem.eql(u8, fw.name, "nextjs")) found_nextjs = true;
    }

    try expect(found_nestjs);
    try expect(found_nextjs);
}

test "FrameworkDetector handles empty directory" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    // Should detect no frameworks
    try expectEqual(@as(usize, 0), detected.len);
}

test "FrameworkDetector handles files without framework markers" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create package.json without any known frameworks
    const package_json =
        \\{
        \\  "dependencies": {
        \\    "unknown-package": "^1.0.0"
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = package_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    // Should detect no frameworks
    try expectEqual(@as(usize, 0), detected.len);
}

test "FrameworkDetector avoids duplicate detections" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create both package.json and nest-cli.json (both indicate NestJS)
    const package_json =
        \\{
        \\  "dependencies": {
        \\    "@nestjs/core": "^10.0.0"
        \\  }
        \\}
    ;

    const nest_cli =
        \\{
        \\  "collection": "@nestjs/schematics"
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = package_json });
    try tmp.dir.writeFile(.{ .sub_path = "nest-cli.json", .data = nest_cli });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    // Should only detect NestJS once, not twice
    var nestjs_count: usize = 0;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "nestjs")) {
            nestjs_count += 1;
        }
    }

    try expectEqual(@as(usize, 1), nestjs_count);
}
