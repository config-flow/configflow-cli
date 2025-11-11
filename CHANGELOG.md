# Changelog

All notable changes to ConfigFlow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2025-01-11

### Changed
- Reorganized unit tests to follow idiomatic Zig pattern (tests colocated with source code)
- Updated dependency management to use GitHub URLs instead of relative paths
- Added Windows build targets (x86_64 and aarch64) to release workflow

### Removed
- Standalone test files (tests now live in source files)
- Unused manual test executables (test_resolver, test_sources, test_vault_comprehensive)
- Unused root.zig template file

## [0.1.0] - 2025-01-10

### Added

**Core Commands:**
- `configflow init` - Initialize ConfigFlow from existing .env files
- `configflow get KEY` - Fetch a single configuration value
- `configflow set KEY=VALUE` - Set a configuration value
- `configflow ls` - List all configuration variables
- `configflow validate` - Validate configuration against schema

**Configuration Clarity Commands:**
- `configflow diff ENV1 ENV2` - Compare configurations across contexts
- `configflow explain KEY` - Debug configuration resolution with detailed source tracing
- `configflow preview ENV` - Preview configuration before deployment

**Type System:**
- 7 configuration types: `string`, `integer`, `boolean`, `url`, `connection_string`, `secret`, `email`
- Field-level validation with type checking
- Context-aware required fields (required in specific environments)
- Default value support
- Pattern validation (basic, regex support planned for V2)

**Source Backends:**
- File source (.env file support)
- Environment variable source (with optional prefix filtering)
- HashiCorp Vault source (KV v1 and v2 support)

**Smart Features:**
- Secret redaction by default (show first/last 4 characters)
- Context-aware warnings:
  - Localhost detection in non-local environments
  - Test credentials in staging/production
  - Same secrets across different environments
- Helpful error messages with "How to fix" suggestions
- Resolution precedence tracking (env vars → sources → defaults)

**Developer Experience:**
- Clean CLI with zcli framework
- Comprehensive help text for all commands
- Examples in help output
- Shell completions support (bash, zsh, fish)

**Testing:**
- 57 passing tests
- Unit tests for all validators
- Integration tests for source backends
- Command-level testing

### Technical

- Built with Zig 0.15.1
- Zero runtime dependencies
- Cross-platform support (macOS, Linux, Windows)
- Memory-safe with proper cleanup (no leaks)

[Unreleased]: https://github.com/ryanhair/configflow/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ryanhair/configflow/releases/tag/v0.1.0
