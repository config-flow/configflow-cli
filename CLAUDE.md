# ConfigFlow CLI - Project Context

## Project Overview

ConfigFlow is a type-safe configuration management CLI tool written in Zig that automatically discovers environment variables in codebases, infers their types, and validates configuration against schemas.

**Key Value Proposition**: Eliminates configuration errors by providing compile-time/runtime validation, automatic type inference, and integration with multiple secret management backends (HashiCorp Vault, AWS Secrets Manager, etc.).

## Core Technologies

- **Language**: Zig 0.15.2
- **CLI Framework**: [zcli](https://github.com/ryanhair/zcli) - Custom Zig CLI framework with automatic command discovery
- **Parsing**: Tree-sitter for AST-based environment variable detection
- **Configuration**: YAML for schemas and framework definitions
- **Supported Languages**: JavaScript/TypeScript, Python, Ruby, Java, Go

## Architecture

### Main Components

```
src/
├── main.zig                 # Entry point, CLI setup
├── commands/                # CLI commands (discover, validate, get, set, etc.)
├── sources/                 # Configuration sources (env, file, vault, aws)
├── clients/                 # External service clients (Vault, AWS)
├── validation/              # Schema validation and type checking
└── discovery/              # Environment variable discovery system
    ├── coordinator.zig     # Orchestrates discovery across all parsers
    ├── scanner.zig         # File system scanning
    ├── parsers/            # Language-specific parsers
    │   ├── javascript_parser.zig
    │   ├── python_parser.zig
    │   ├── ruby_parser.zig
    │   ├── java_parser.zig
    │   ├── go_parser.zig
    │   └── frameworks/     # Framework-specific YAML configs
    ├── framework_detector.zig   # Auto-detects frameworks from dependencies
    ├── framework_config.zig     # Parses YAML framework configurations
    ├── framework_parser.zig     # Executes framework-specific tree-sitter queries
    └── embedded_frameworks.zig  # Embeds framework configs in binary
```

### Discovery Flow

1. **Scan**: Find all source files matching target extensions
2. **Framework Detection**: Scan dependency files (package.json, requirements.txt, etc.) to detect frameworks
3. **Parse**: For each file:
   - Run language-specific parser (JavaScript, Python, etc.)
   - Run applicable framework parsers (NestJS, Django, Rails, etc.)
   - Merge results
4. **Aggregate**: Combine usages by variable name, track locations and confidence
5. **Output**: Present discovered variables with inferred types

## Framework System (Major Feature)

The framework system provides framework-specific environment variable detection for higher accuracy.

### Why It Exists

Generic tree-sitter patterns can't capture all framework-specific patterns:
- **NestJS**: `this.configService.get('DATABASE_URL')`
- **Django**: `env('DATABASE_URL')`
- **Rails**: `ENV['DATABASE_URL']`
- **Spring Boot**: `@Value("${database.url}")`

### How It Works

1. **FrameworkDetector** ([framework_detector.zig](src/discovery/framework_detector.zig)): Scans dependency files to detect frameworks
2. **FrameworkConfig** ([framework_config.zig](src/discovery/framework_config.zig)): Parses YAML configurations defining detection and query patterns
3. **FrameworkParser** ([framework_parser.zig](src/discovery/framework_parser.zig)): Compiles and executes tree-sitter queries dynamically

### Supported Frameworks

- **JavaScript/TypeScript**: NestJS, Next.js, Vite
- **Python**: Django, Pydantic Settings
- **Java**: Spring Boot
- **Ruby**: Rails

### Framework Configuration Format

Each framework has a YAML config in `src/discovery/parsers/frameworks/<language>/<framework>.yml`:

```yaml
name: "NestJS"
language: "javascript"
version: "1.0.0"
description: "Detects NestJS ConfigService usage"

detection:
  files: ["package.json", "nest-cli.json"]
  patterns:
    package_json: "@nestjs/core"

queries:
  - name: "ConfigService.get() method calls"
    description: "Matches this.configService.get('KEY')"
    pattern: "(call_expression ...) @access"
    key_capture: "key_string"
    confidence: "high"

type_inference:
  by_js_type:
    string: string
    number: integer
  by_name_pattern:
    - pattern: "(?i)port$"
      type: "integer"
      confidence: "high"
```

**See [docs/framework_system.md](docs/framework_system.md) for complete documentation.**

## Important Patterns

### Memory Management

Zig requires explicit memory management. Key patterns:

```zig
// Always pair init/deinit
var parser = try Parser.init(allocator);
defer parser.deinit();

// Use errdefer for cleanup on error
var list = std.ArrayList(Item){};
errdefer {
    for (list.items) |*item| item.deinit();
    list.deinit(allocator);
}

// ArrayList API (Zig 0.15.2)
try list.append(allocator, item);  // Note: allocator parameter
const slice = try list.toOwnedSlice(allocator);
list.deinit(allocator);
```

### Error Handling

```zig
// Errors are values in Zig
const result = try functionThatMightFail();

// Catch and handle errors
const data = functionThatMightFail() catch |err| {
    std.debug.print("Error: {}\n", .{err});
    return err;
};

// Optional error handling
const content = std.fs.cwd().readFileAlloc(...) catch return; // Silent fail
```

### Tree-sitter Usage

```zig
// Parse source code
const parser = ts.Parser.create();
defer parser.destroy();
try parser.setLanguage(language);
const tree = parser.parseStringEncoding(source, null, .utf8) orelse return error.ParseFailed;
defer tree.destroy();

// Execute query
const query = ts.Query.create(language, pattern, &error_offset) catch |err| { ... };
defer query.destroy();
const cursor = ts.QueryCursor.create();
defer cursor.destroy();
cursor.exec(query, root_node);

while (cursor.nextMatch()) |match| {
    // Process captures
    for (match.captures) |capture| {
        const name = query.captureNameForId(capture.index);
        const node = capture.node;
        const text = source[node.startByte()..node.endByte()];
    }
}
```

## Building and Testing

### Build Commands

```bash
# Build the CLI
zig build

# Run tests
zig build test

# Run specific test
zig build test --test-filter "FrameworkDetector"

# Run the CLI
./zig-out/bin/configflow <command>
```

### Test Structure

Tests are colocated with source files using Zig's built-in testing:

```zig
test "description of what this tests" {
    const allocator = std.testing.allocator;
    // Test code here
    try std.testing.expectEqual(expected, actual);
}
```

Current test count: **335 tests** (all passing as of Nov 2024)

## CLI Commands

The CLI uses zcli's automatic command discovery from `src/commands/`:

- **discover**: Scan codebase for environment variables
- **validate**: Validate configuration against schema
- **get**: Get configuration value from sources
- **set**: Set configuration value in Vault
- **ls**: List all configuration keys
- **diff**: Compare configurations between sources
- **explain**: Explain a configuration key
- **preview**: Preview configuration loading
- **init**: Initialize configflow in a project

Each command is a separate file in `src/commands/` that implements the zcli Command interface.

## Configuration Sources

ConfigFlow supports multiple configuration sources with a priority system:

1. **Environment Variables** ([env_source.zig](src/sources/env_source.zig))
2. **Local Files** ([file_source.zig](src/sources/file_source.zig)): .env, .env.local, etc.
3. **HashiCorp Vault** ([vault_source.zig](src/sources/vault_source.zig))
4. **AWS Secrets Manager** ([aws_source.zig](src/sources/aws_source.zig))

## Validation System

The validation system uses YAML schemas to define expected configuration:

```yaml
# .configflow/schema.yml
version: 1
fields:
  - name: DATABASE_URL
    type: connection_string
    required: true
    description: "PostgreSQL connection string"

  - name: PORT
    type: integer
    required: false
    default: "3000"
```

**Supported Types**: string, integer, number, boolean, secret, url, connection_string, json, list

## Type Inference

The discovery system infers types through multiple strategies:

1. **Language Type Annotations**: Python type hints, TypeScript types, etc.
2. **Wrapping Functions**: `int(os.getenv())` → integer
3. **Framework-Specific Types**: Pydantic's `SecretStr` → secret
4. **Name Patterns**: Variables ending in `_URL` → url, containing `SECRET` → secret
5. **Value Patterns**: Connection strings, URLs, JSON detected from values

## Development Guidelines

### Adding a New Framework

1. Create YAML config in `src/discovery/parsers/frameworks/<language>/<framework>.yml`
2. Add to `embedded_frameworks.zig` with `@embedFile`
3. Add detection logic to `framework_detector.zig`
4. Write tests in the detector, config, and parser test files
5. Update documentation in `docs/framework_system.md`

### Adding a New Language Parser

1. Add tree-sitter grammar vendor files to `vendor/tree-sitter-<language>/`
2. Create parser in `src/discovery/parsers/<language>_parser.zig`
3. Add extern declaration for tree-sitter language function
4. Update coordinator to use new parser
5. Add C sources to `build.zig`
6. Write comprehensive tests

### Adding a New CLI Command

1. Create file in `src/commands/<command_name>.zig`
2. Implement zcli Command interface:
   ```zig
   pub const Command = struct {
       pub const name = "command-name";
       pub const description = "Command description";
       pub fn run(allocator: Allocator, args: Args) !void { ... }
   };
   ```
3. zcli automatically discovers and registers the command

## Common Pitfalls

### Memory Leaks

- Always pair `init()` with `defer deinit()`
- Use `errdefer` for cleanup on error paths
- Remember ArrayList methods take `allocator` parameter in Zig 0.15.2
- Free strings returned from functions: `defer allocator.free(str);`

### Tree-sitter Queries

- Test queries in [Tree-sitter Playground](https://tree-sitter.github.io/tree-sitter/playground)
- Use predicates to be specific: `(#eq? @capture "value")`
- Remember to destroy query objects: `defer query.destroy();`
- Error offset helps debug query compilation failures

### YAML Parsing

- Use `.asScalar()` not `.asString()` for string values
- Check for null before using: `map.get("key") orelse return error.MissingField`
- Remember to `defer parsed.deinit(allocator)`

## File Naming Conventions

- **Source files**: `snake_case.zig`
- **Test names**: `test "Description in quotes"`
- **CLI commands**: `kebab-case` (e.g., `discover-secrets.zig` → `discover-secrets` command)
- **YAML configs**: `lowercase.yml` (e.g., `nestjs.yml`)

## External Dependencies

Managed via `build.zig.zon`:

- **zcli**: CLI framework
- **zig-yaml**: YAML parsing
- **tree-sitter**: AST parsing (Zig bindings)
- Tree-sitter language grammars (vendored in `vendor/`)

## Performance Considerations

- Framework detection runs once per project (cached conceptually)
- File scanning uses parallel iteration where possible
- Tree-sitter parsing is fast but memory-intensive for large files
- Limit file size reads to 10MB to prevent OOM
- Use `std.Progress` for user feedback on long operations

## Key Metrics

- **Supported Languages**: 5 (JavaScript/TypeScript, Python, Ruby, Java, Go)
- **Supported Frameworks**: 7 (NestJS, Next.js, Vite, Django, Pydantic, Spring Boot, Rails)
- **Supported Sources**: 4 (Env, File, Vault, AWS Secrets Manager)
- **Test Coverage**: 335 tests across all components
- **Binary Size**: ~12MB (includes embedded tree-sitter grammars and framework configs)

## Resources

- **Main Documentation**: [README.md](README.md)
- **Framework System**: [docs/framework_system.md](docs/framework_system.md)
- **Tree-sitter Docs**: https://tree-sitter.github.io/tree-sitter/
- **Zig Language**: https://ziglang.org/documentation/master/
- **zcli Framework**: https://github.com/ryanhair/zcli

## Recent Major Changes (Nov 2024)

- Added complete framework detection and parsing system
- Implemented framework-specific type inference
- Added 7 framework configurations (NestJS, Next.js, Vite, Django, Pydantic, Spring, Rails)
- Increased test coverage to 335 tests (20 new framework tests)
- Created comprehensive framework documentation
- All tests passing, production-ready

## Future Roadmap Ideas

- User-defined framework configs in `.configflow/frameworks/`
- Framework version detection and version-specific patterns
- Multi-language framework support
- Community framework repository
- Type inference machine learning
- IDE integrations (VS Code extension)
- Automatic migration tools (env → Vault)
