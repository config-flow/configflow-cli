# Contributing to ConfigFlow

Thank you for your interest in contributing to ConfigFlow! This document provides guidelines and instructions for contributing.

## Code of Conduct

Be respectful, inclusive, and constructive. We're building a tool to help developers, and we want the community to reflect that spirit.

## Getting Started

### Prerequisites

- [Zig 0.15.1](https://ziglang.org/download/) installed
- Git for version control
- Familiarity with command-line tools

### Setting Up Development Environment

1. **Fork and clone the repository:**
   ```bash
   git clone https://github.com/YOUR_USERNAME/configflow.git
   cd configflow
   ```

2. **Build the project:**
   ```bash
   zig build
   ```

3. **Run tests:**
   ```bash
   zig build test
   ```

4. **Try it out:**
   ```bash
   ./zig-out/bin/configflow --help
   ```

## Development Workflow

### 1. Create a Branch

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/bug-description
```

Use prefixes:
- `feature/` - New features
- `fix/` - Bug fixes
- `docs/` - Documentation changes
- `refactor/` - Code refactoring
- `test/` - Test additions or changes

### 2. Make Your Changes

**Code Style:**
- Run `zig fmt` before committing:
  ```bash
  zig fmt src/
  ```
- Follow existing code patterns in the codebase
- Keep functions focused and well-named
- Add comments for complex logic

**Testing:**
- Add tests for new features in the appropriate test file
- Ensure all tests pass: `zig build test`
- Test manually with real .env files

**Memory Management:**
- ConfigFlow uses Zig's allocator pattern
- Always free allocated memory (use `defer` for cleanup)
- Run with leak detection to ensure no memory leaks

### 3. Write Good Commit Messages

Format:
```
<type>: <short description>

<optional longer description>
<optional body>

Fixes #123
```

Types:
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `test:` - Test changes
- `refactor:` - Code refactoring
- `chore:` - Build/tooling changes

Examples:
```
feat: add pattern validation for secret fields

Implements regex pattern matching for fields with the 'pattern'
attribute. Validates API keys, tokens, and other secrets against
common patterns.

Fixes #42
```

```
fix: correct resolution precedence for env vars

Environment variables were not properly overriding file sources
in all cases. Updated resolution order to always check env vars first.
```

### 4. Push and Create Pull Request

```bash
git push origin feature/your-feature-name
```

Then create a Pull Request on GitHub with:
- Clear title describing the change
- Description explaining what and why
- Reference to any related issues
- Screenshots/examples if relevant

## Project Structure

```
configflow/
├── src/
│   ├── main.zig              # Entry point
│   ├── sources.zig           # Source backend orchestration
│   ├── validation.zig        # Validation system
│   ├── commands/             # CLI commands
│   │   ├── init.zig
│   │   ├── get.zig
│   │   ├── set.zig
│   │   ├── validate.zig
│   │   ├── diff.zig
│   │   ├── explain.zig
│   │   └── preview.zig
│   ├── sources/              # Source backends
│   │   ├── file_source.zig
│   │   ├── env_source.zig
│   │   └── vault_source.zig
│   └── validation/           # Validation types
│       ├── field.zig
│       ├── types.zig
│       └── schema_parser.zig
├── build.zig                 # Build configuration
└── tests/                    # Test files
```

## Adding New Features

### Adding a New Command

1. Create `src/commands/yourcommand.zig`
2. Follow the zcli command pattern:
   ```zig
   const std = @import("std");
   const zcli = @import("zcli");

   pub const meta = .{
       .description = "Your command description",
       .examples = &.{
           "configflow yourcommand example",
       },
       .options = .{
           .flag = .{ .description = "Flag description", .short = 'f' },
       },
   };

   pub const Args = struct {
       // Required args
   };

   pub const Options = struct {
       flag: bool = false,
   };

   pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
       // Implementation
   }
   ```
3. The command will be automatically discovered by the build system
4. Add tests
5. Update README.md with the new command

### Adding a New Validator Type

1. Add the type to `src/validation/types.zig`:
   ```zig
   pub const FieldType = enum {
       // ... existing types ...
       your_type,

       pub fn toString(self: FieldType) []const u8 {
           return switch (self) {
               // ... existing cases ...
               .your_type => "your_type",
           };
       }

       pub fn fromString(s: []const u8) ?FieldType {
           // ... existing cases ...
           if (std.mem.eql(u8, s, "your_type")) return .your_type;
           return null;
       }
   };
   ```

2. Add validation logic to `src/validation/field.zig` in `validateType()`

3. Add tests in `src/validation/test_types.zig`

4. Update README.md type table

### Adding a New Source Backend

1. Create `src/sources/your_source.zig`
2. Implement the `SourceBackend` interface
3. Register in `src/sources.zig`
4. Add tests
5. Update documentation

## Testing

### Running Tests

```bash
# All tests
zig build test

# Specific test file (run directly)
zig test src/validation/test_types.zig
```

### Writing Tests

```zig
const std = @import("std");
const testing = std.testing;

test "descriptive test name" {
    const allocator = testing.allocator;

    // Your test code
    const result = someFunction(allocator);

    try testing.expectEqual(expected, result);
}
```

### Test Categories

- **Unit tests**: Test individual functions (in same file as code)
- **Integration tests**: Test command workflows (in `tests/` directory)
- **Source backend tests**: Test .env parsing, Vault connection, etc.

## Documentation

- Update README.md for user-facing changes
- Add inline comments for complex code
- Update CHANGELOG.md following [Keep a Changelog](https://keepachangelog.com/)

## Release Process

Releases are automated via GitHub Actions:

1. Update version in `build.zig`
2. Update `CHANGELOG.md` with version and date
3. Commit: `git commit -m "chore: bump version to X.Y.Z"`
4. Tag: `git tag vX.Y.Z`
5. Push: `git push && git push --tags`
6. GitHub Actions will build and create the release automatically

## Getting Help

- **Questions?** Open a [Discussion](https://github.com/ryanhair/configflow/discussions)
- **Bug?** Open an [Issue](https://github.com/ryanhair/configflow/issues)
- **Feature idea?** Open a [Discussion](https://github.com/ryanhair/configflow/discussions) first

## Recognition

Contributors will be recognized in release notes and the README. Thank you for making ConfigFlow better!

## License

By contributing to ConfigFlow, you agree that your contributions will be licensed under the MIT License.
