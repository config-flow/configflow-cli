# Framework Detection and Parsing System

## Overview

The framework detection and parsing system automatically detects popular frameworks used in a project and applies framework-specific environment variable extraction patterns. This dramatically improves detection accuracy by understanding how each framework accesses configuration.

## Why Framework-Specific Detection?

Different frameworks have their own patterns for accessing environment variables:

- **NestJS**: `this.configService.get('DATABASE_URL')`
- **Next.js**: `process.env.DATABASE_URL`
- **Spring Boot**: `@Value("${database.url}")`
- **Django**: `env('DATABASE_URL')`
- **Rails**: `ENV['DATABASE_URL']`

Generic tree-sitter patterns can't capture all these variations effectively. Framework-specific parsers provide:

1. **Higher Accuracy**: Patterns tailored to each framework's conventions
2. **Better Type Inference**: Framework-aware type mappings (e.g., Pydantic's `SecretStr` → secret)
3. **Confidence Levels**: Framework-specific patterns have higher confidence
4. **Extensibility**: Easy to add new frameworks via YAML configuration

## Architecture

The framework system consists of three main components:

### 1. FrameworkDetector

**Location**: [src/discovery/framework_detector.zig](../src/discovery/framework_detector.zig)

Scans dependency files to detect which frameworks are used in a project.

**Detection Strategy**:
- **JavaScript/TypeScript**: Scans `package.json` for framework dependencies
- **Python**: Scans `requirements.txt` and `pyproject.toml`
- **Java**: Scans `pom.xml` and `build.gradle`
- **Ruby**: Scans `Gemfile`

**Confidence Levels**:
- `high`: Found explicit dependency declaration
- `medium`: Found framework-specific config file
- `low`: Found similar patterns

**Example**:
```zig
var detector = FrameworkDetector.init(allocator);
const detected = try detector.detectAll("/path/to/project");
// Returns: [{ name: "nestjs", language: "javascript", config_path: "javascript/nestjs.yml", confidence: .high }]
```

### 2. FrameworkConfig

**Location**: [src/discovery/framework_config.zig](../src/discovery/framework_config.zig)

Parses YAML framework configuration files that define detection patterns and tree-sitter queries.

**Configuration Structure**:
```yaml
name: "NestJS"
language: "javascript"
version: "1.0.0"
description: "Detects NestJS ConfigService usage"

detection:
  files:
    - "package.json"
    - "nest-cli.json"
  patterns:
    package_json: "@nestjs/core"
    nest_cli: "schematics"

queries:
  - name: "ConfigService.get() method calls"
    description: "Matches this.configService.get('KEY')"
    pattern: |
      (call_expression
        function: (member_expression
          property: (property_identifier) @get (#eq? @get "get"))
        arguments: (arguments
          . (string) @key_string)) @access
    key_capture: "key_string"
    confidence: "high"

type_inference:
  by_js_type:
    string: string
    number: integer
    boolean: boolean
  by_name_pattern:
    - pattern: "(?i)port$"
      type: "integer"
      confidence: "high"
    - pattern: "(?i)secret"
      type: "secret"
      confidence: "high"
    - pattern: "(?i)url$"
      type: "url"
      confidence: "medium"
```

**Configuration Fields**:
- **detection**: How to detect if this framework is used
  - `files`: Filenames to look for
  - `patterns`: Content patterns to match in those files
- **queries**: Tree-sitter query patterns for extracting env vars
  - `pattern`: Tree-sitter S-expression query
  - `key_capture`: Which capture contains the env var name
  - `confidence`: Detection confidence level (high/medium/low)
- **type_inference**: Rules for inferring configuration types
  - `by_<language>_type`: Map language types to config types
  - `by_name_pattern`: Regex patterns for name-based inference

### 3. FrameworkParser

**Location**: [src/discovery/framework_parser.zig](../src/discovery/framework_parser.zig)

Executes tree-sitter queries from framework configurations to extract environment variable usages.

**Key Features**:
- **Dynamic Query Compilation**: Compiles tree-sitter queries at runtime from YAML
- **Language Agnostic**: Works with any tree-sitter language grammar
- **Multi-Query Support**: Executes multiple queries per framework
- **Quote Stripping**: Automatically removes quotes from string literals

**Example**:
```zig
var parser = try FrameworkParser.init(allocator, config, language);
defer parser.deinit();

const source = "const x = configService.get('PORT');";
var result = try parser.parse(source);
// Returns: [{ name: "PORT", inferred_type: .integer, confidence: .high, ... }]
```

## Integration in Discovery Flow

The framework system integrates into the main discovery coordinator:

1. **Framework Detection Phase** (runs once per project)
   ```
   Coordinator.discover()
   → FrameworkDetector.detectAll()
   → Detect frameworks from dependency files
   ```

2. **Framework Loading Phase**
   ```
   For each detected framework:
   → Load YAML config from embedded content
   → Create FrameworkConfig
   → Initialize FrameworkParser with tree-sitter language
   → Store in loaded_frameworks list
   ```

3. **File Parsing Phase** (runs for each source file)
   ```
   For each source file:
   → Run language parser (JavaScript/Python/etc)
   → Run applicable framework parsers
   → Merge results
   → Apply type inference
   ```

**Code Example** ([src/discovery/coordinator.zig](../src/discovery/coordinator.zig:193-225)):
```zig
// Detect frameworks
const detected_frameworks = try self.framework_detector.detectAll(root_path);

// Load framework configs and parsers
for (detected_frameworks) |detected| {
    const config_content = embedded_frameworks.EmbeddedFrameworks.get(detected.config_path);
    var config = try framework_config.loadFromContent(self.allocator, config_content);
    const language = try self.getLanguageForFramework(detected.language);
    var parser = try FrameworkParser.init(self.allocator, config, language);
    try self.loaded_frameworks.append(self.allocator, .{
        .name = detected.name,
        .language = detected.language,
        .config = config,
        .parser = parser,
    });
}

// During file parsing
for (self.loaded_frameworks.items) |*framework| {
    if (fileMatchesLanguage(file_path, framework.language)) {
        var result = try framework.parser.parse(source);
        try usages.appendSlice(result.usages);
    }
}
```

## Supported Frameworks

### JavaScript/TypeScript
- **NestJS**: ConfigService patterns (`@nestjs/core`, `@nestjs/config`)
- **Next.js**: Environment variable access patterns (`next`)
- **Vite**: Vite-specific env patterns (`vite`)

### Python
- **Django**: Settings and environ access (`django`, `django-environ`)
- **Pydantic**: Settings and Field patterns (`pydantic`, `pydantic-settings`)

### Java
- **Spring Boot**: @Value annotations and property access (`spring-boot-starter`)

### Ruby
- **Rails**: ENV access patterns (`rails`)

## Adding a New Framework

To add support for a new framework:

### 1. Create Framework Configuration

Create a YAML file in `src/discovery/parsers/frameworks/<language>/<framework>.yml`:

```yaml
name: "MyFramework"
language: "python"  # or javascript, java, ruby
version: "1.0.0"
description: "Detects MyFramework configuration patterns"

detection:
  files:
    - "requirements.txt"
    - "myframework.config"
  patterns:
    requirements_txt: "myframework"
    config: "MyFrameworkConfig"

queries:
  - name: "config.get() calls"
    description: "Matches config.get('KEY')"
    pattern: |
      (call
        function: (attribute
          object: (identifier) @obj (#eq? @obj "config")
          attribute: (identifier) @method (#eq? @method "get"))
        arguments: (argument_list
          . (string) @key_string)) @access
    key_capture: "key_string"
    confidence: "high"

type_inference:
  by_python_type:
    str: string
    int: integer
    bool: boolean
    SecretStr: secret
  by_name_pattern:
    - pattern: "(?i)api_key"
      type: "secret"
      confidence: "high"
    - pattern: "(?i)port$"
      type: "integer"
      confidence: "high"
```

### 2. Add to Embedded Frameworks

Add the framework to [src/discovery/embedded_frameworks.zig](../src/discovery/embedded_frameworks.zig):

```zig
pub const EmbeddedFrameworks = struct {
    // ... existing frameworks ...
    pub const myframework = @embedFile("parsers/frameworks/python/myframework.yml");

    pub fn get(path: []const u8) ?[]const u8 {
        // ... existing mappings ...
        if (std.mem.eql(u8, path, "python/myframework.yml")) return myframework;
        return null;
    }
};
```

### 3. Add Detection Logic

Add detection logic to [src/discovery/framework_detector.zig](../src/discovery/framework_detector.zig) in the appropriate `scan*` method:

```zig
fn scanPythonDependencies(
    self: *FrameworkDetector,
    root_path: []const u8,
    detected: *std.ArrayList(DetectedFramework),
) !void {
    // ... existing detection ...

    // Add MyFramework detection
    if (std.mem.indexOf(u8, content, "myframework") != null) {
        try self.addFramework(detected, "myframework", "python", "python/myframework.yml", .high);
    }
}
```

### 4. Write Tests

Add tests to verify your framework works:

```zig
test "FrameworkDetector detects MyFramework from requirements.txt" {
    const allocator = std.testing.allocator;
    var detector = FrameworkDetector.init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const requirements = "myframework==1.0.0\n";
    try tmp.dir.writeFile(.{ .sub_path = "requirements.txt", .data = requirements });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const detected = try detector.detectAll(tmp_path);
    defer detector.deinit(detected);

    var found = false;
    for (detected) |fw| {
        if (std.mem.eql(u8, fw.name, "myframework")) {
            found = true;
            try std.testing.expectEqualStrings("python", fw.language);
        }
    }
    try std.testing.expect(found);
}
```

### 5. Testing Tree-Sitter Queries

Use the [Tree-sitter Playground](https://tree-sitter.github.io/tree-sitter/playground) to test your queries:

1. Select your language grammar
2. Paste sample code
3. Write and test your query pattern
4. Verify captures match what you expect

Example query testing:
```
Code:
config.get('DATABASE_URL')

Query:
(call
  function: (attribute
    object: (identifier) @obj
    attribute: (identifier) @method)
  arguments: (argument_list
    (string) @key_string))

Captures:
@obj = "config"
@method = "get"
@key_string = "'DATABASE_URL'"
```

## Configuration Type Inference

The framework system supports sophisticated type inference:

### Language-Specific Types

Map language types to configuration types:

```yaml
type_inference:
  by_python_type:
    str: string
    int: integer
    float: number
    bool: boolean
    SecretStr: secret      # Pydantic special type
    HttpUrl: url           # Pydantic special type
    PostgresDsn: connection_string
```

### Name Pattern Matching

Use regex patterns to infer types from variable names:

```yaml
type_inference:
  by_name_pattern:
    - pattern: "(?i)port$"
      type: "integer"
      confidence: "high"
      note: "Port numbers are integers"

    - pattern: "(?i)(secret|token|key|password)"
      type: "secret"
      confidence: "high"
      note: "Sensitive credentials"

    - pattern: "(?i)(url|endpoint|uri)$"
      type: "url"
      confidence: "medium"

    - pattern: "(?i)(database_url|db_url|connection_string)"
      type: "connection_string"
      confidence: "high"
```

## Best Practices

### Query Writing

1. **Be Specific**: Use predicates like `(#eq? @capture "value")` to avoid false positives
2. **Use Anchors**: Anchor patterns to specific node types (e.g., `call_expression`)
3. **Test Thoroughly**: Test queries with various code samples
4. **Consider Edge Cases**: Handle both single and double quotes, optional parameters, etc.

### Type Inference

1. **Prefer Explicit Types**: Use language-specific type mappings when available
2. **Use Confidence Levels**: Set appropriate confidence for pattern-based inference
3. **Add Notes**: Document why a pattern matches a type
4. **Be Conservative**: Lower confidence for ambiguous patterns

### Performance

1. **Limit File Scans**: Only scan necessary dependency files
2. **Optimize Patterns**: Use specific patterns to reduce false positives
3. **Cache Results**: Framework detection runs once per project
4. **Share Queries**: Reuse query patterns across similar frameworks

## Troubleshooting

### Framework Not Detected

1. **Check dependency files exist**: Verify `package.json`, `requirements.txt`, etc. are present
2. **Check pattern matching**: Ensure the dependency name exactly matches the pattern
3. **Check file permissions**: Ensure the detector can read dependency files
4. **Enable debug logging**: Set environment variable `DEBUG=1` to see detection output

### Queries Not Matching

1. **Use Tree-sitter Playground**: Visualize the AST and test queries
2. **Check Language Grammar**: Ensure you're using the correct tree-sitter grammar version
3. **Verify Predicates**: Check that `(#eq? ...)` predicates match expected values
4. **Test Incrementally**: Start with simple patterns and add complexity

### Wrong Type Inference

1. **Check Type Mappings**: Verify language-specific types are correctly mapped
2. **Check Pattern Order**: Patterns are evaluated in order; more specific patterns should come first
3. **Adjust Confidence**: Lower confidence for ambiguous patterns
4. **Add Explicit Mappings**: Use language types over name patterns when possible

## Examples

### Example 1: NestJS Project

**Project Structure**:
```
my-app/
├── package.json       # Contains "@nestjs/core": "^10.0.0"
├── src/
│   └── config/
│       └── database.config.ts
```

**Code** (`database.config.ts`):
```typescript
export class DatabaseConfig {
  constructor(private configService: ConfigService) {}

  getDatabaseUrl(): string {
    return this.configService.get('DATABASE_URL');
  }

  getPort(): number {
    return this.configService.get('DATABASE_PORT');
  }
}
```

**Detection Flow**:
1. FrameworkDetector scans `package.json` → Detects NestJS
2. Loads `nestjs.yml` configuration
3. Parses `database.config.ts` with NestJS query patterns
4. Finds: `DATABASE_URL` (type: connection_string), `DATABASE_PORT` (type: integer)

### Example 2: Django Project

**Project Structure**:
```
my-project/
├── requirements.txt   # Contains "django==4.2.0"
├── settings.py
```

**Code** (`settings.py`):
```python
import environ

env = environ.Env()

DATABASES = {
    'default': env.db('DATABASE_URL')
}

SECRET_KEY = env.str('SECRET_KEY')
DEBUG = env.bool('DEBUG', default=False)
```

**Detection Flow**:
1. FrameworkDetector scans `requirements.txt` → Detects Django
2. Loads `django.yml` configuration
3. Parses `settings.py` with Django patterns
4. Finds: `DATABASE_URL`, `SECRET_KEY` (type: secret), `DEBUG` (type: boolean)

## Testing

The framework system has comprehensive test coverage:

- **Unit Tests**: Test each component independently
  - [framework_detector_test.zig](../src/discovery/framework_detector.zig#L421-L790): 10 tests
  - [framework_config_test.zig](../src/discovery/framework_config.zig#L406-L800): 10 tests
  - [framework_parser_test.zig](../src/discovery/framework_parser.zig#L182-L490): 6 tests

- **Integration Tests**: Test components working together
  - Coordinator tests verify framework detection and parsing integration

**Running Tests**:
```bash
# Run all tests
zig build test

# Run specific test
zig build test --test-filter "FrameworkDetector"
```

## Future Enhancements

Planned improvements to the framework system:

1. **User-Defined Frameworks**: Allow users to add custom framework configs in `.configflow/frameworks/`
2. **Framework Auto-Update**: Download updated framework configs from a central repository
3. **Framework Version Detection**: Detect framework version and use version-specific patterns
4. **Multi-Language Frameworks**: Support frameworks that span multiple languages
5. **Framework Plugins**: Load framework parsers as dynamic plugins
6. **Query Optimization**: Cache compiled queries across file scans
7. **Pattern Learning**: Automatically suggest new patterns based on usage

## Contributing

To contribute to the framework system:

1. **Add New Frameworks**: Follow the "Adding a New Framework" guide above
2. **Improve Existing Patterns**: Submit PRs with better query patterns
3. **Report Issues**: File bugs for frameworks that aren't detected correctly
4. **Improve Documentation**: Help expand this documentation with examples

See [CONTRIBUTING.md](../CONTRIBUTING.md) for general contribution guidelines.

## References

- [Tree-sitter Documentation](https://tree-sitter.github.io/tree-sitter/)
- [Tree-sitter Query Syntax](https://tree-sitter.github.io/tree-sitter/using-parsers#pattern-matching-with-queries)
- [Tree-sitter Playground](https://tree-sitter.github.io/tree-sitter/playground)
- [NestJS Configuration Documentation](https://docs.nestjs.com/techniques/configuration)
- [Django-environ Documentation](https://django-environ.readthedocs.io/)
- [Pydantic Settings Documentation](https://docs.pydantic.dev/latest/concepts/pydantic_settings/)
- [Spring Boot Externalized Configuration](https://docs.spring.io/spring-boot/reference/features/external-config.html)
