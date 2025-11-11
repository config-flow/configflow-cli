# ConfigFlow

**Stop guessing. Start knowing.**

---

## The Problem You've Stopped Noticing

You just spent 45 minutes debugging why your service works in staging but crashes in production.

The error message is useless. The logs show nothing. You check CloudWatch, grep through config files, compare environment variables across terminals. Finally, you discover: `DATABASE_URL` is still pointing to `localhost` in production.

**How did this happen?** You have no idea. You don't know where that value came from, why it overrode the correct one, or how to prevent it next time.

You've trained yourself to accept this. "Configuration is just messy," you think. "This is normal."

**It's not normal. And it doesn't have to be this way.**

---

## The Invisible Chaos

Every developer has experienced these:

- ✋ **"Why is staging broken?"** → Spent 2 hours finding a single wrong config value
- ✋ **"Did I push the right secrets?"** → No way to verify before deployment
- ✋ **"Which API key am I using?"** → `echo $API_KEY` doesn't tell you where it came from
- ✋ **"Why are dev and prod the same?"** → Accidentally using test credentials in production
- ✋ **"What changed?"** → Can't compare configurations across environments

You've accepted these as facts of life. They're not. They're symptoms of a problem that **can** be solved.

---

## ConfigFlow: Configuration You Can Understand

ConfigFlow brings **type safety** and **clarity** to configuration management. It's a CLI tool that makes you actually understand how your application is configured in any environment.

```bash
# Instead of this nightmare:
echo $DATABASE_URL                    # Where did this come from?
cat .env .env.local .env.prod         # Which one is loaded?
env | grep DATABASE                   # Is it overridden?

# Do this:
configflow explain DATABASE_URL       # Get the complete answer
```

---

## See It In Action

### 1. Know Exactly What Changed

```bash
$ configflow diff local prod

DATABASE_URL:
  local:  postgresql://localhost:5432/dev
  prod:   postgresql://prod-db.acme.com/users
  ✓ Different (expected)

API_KEY:
  local:  sk_test_***
  prod:   sk_test_***
  ⚠️  WARNING: Same value in both environments!

DEBUG:
  local:  true
  prod:   false
  ✓ Different (expected)
```

**No more guessing.** You can see exactly what will change when you deploy.

### 2. Debug Configuration Problems Instantly

```bash
$ configflow explain API_KEY --context prod

Explaining API_KEY in context 'prod':

✓ Current value: sk_t***c123
  Source: source 'prod'
  Type: secret
  Valid: ✓

Warnings:
  ⚠️  Secret contains 'test' in 'prod' context
```

**No more mystery.** You know where the value came from, whether it's valid, and what's wrong.

### 3. Preview Before You Deploy

```bash
$ configflow preview staging

Configuration preview for context 'staging':

DATABASE_URL:
  Value: postgresql://localhost/mydb
  Source: staging
  Type: connection_string
  Status: ✓ valid
  ⚠️  Warning: contains localhost in 'staging' context

[... 12 more fields ...]

Summary:
  Total fields: 15
  Valid: 15
  Warnings: 1

⚠️  Configuration is valid but has warnings
```

**No more surprises.** You see exactly what configuration will be used before anything runs.

---

## How It Works

### 1. Initialize from your existing setup

```bash
$ configflow init

✓ Found .env with 7 variables
✓ Generated schema at .configflow/schema.yml
✓ ConfigFlow initialized!

Next: Run 'configflow validate' to check your configuration
```

ConfigFlow generates a schema from your `.env` files and starts validating immediately.

### 2. Your schema gives you type safety

```yaml
# .configflow/schema.yml
version: "1"

config:
  DATABASE_URL:
    type: connection_string
    required: true
    description: "PostgreSQL connection"

  PORT:
    type: integer
    default: 3000
    description: "HTTP server port"

  API_KEY:
    type: secret
    required: [prod, staging]  # Required in these contexts
    description: "External API key"
```

### 3. ConfigFlow validates everything

```bash
$ configflow validate

Validating configuration for context 'local'...

✓ DATABASE_URL: postgresql://localhost:5432/dev
✓ PORT: 3000 (default)
✓ DEBUG: true
❌ API_KEY: required in context 'local' but not set

  How to fix:
    - Set as environment variable: export API_KEY=value
    - Add to .env file: echo 'API_KEY=value' >> .env

1 error found. Fix errors before running in production.
```

---

## Multi-Source Support

ConfigFlow works with your existing setup:

```yaml
sources:
  local:
    type: file
    path: .env

  staging:
    type: vault
    addr: http://127.0.0.1:8200
    mount: secret
    path: staging/myapp

  prod:
    type: vault
    mount: secret
    path: prod/myapp

contexts:
  local:
    default_source: local
  staging:
    default_source: staging
  prod:
    default_source: prod
```

**Supported sources:**
- `.env` files
- Environment variables
- HashiCorp Vault (KV v1 and v2)

---

## Installation

### macOS/Linux

```bash
# Download the latest release
curl -L https://github.com/ryanhair/configflow/releases/latest/download/configflow-$(uname -s)-$(uname -m) -o configflow

# Make it executable
chmod +x configflow

# Move to your PATH
sudo mv configflow /usr/local/bin/
```

### From source (Zig required)

```bash
git clone https://github.com/ryanhair/configflow.git
cd configflow
zig build -Doptimize=ReleaseFast
# Binary at zig-out/bin/configflow
```

---

## Quick Start

```bash
# 1. Initialize in your project
cd your-project
configflow init

# 2. Validate your configuration
configflow validate

# 3. See all your config
configflow ls

# 4. Check what's different between environments
configflow diff local staging

# 5. Debug a specific value
configflow explain DATABASE_URL --verbose

# 6. Preview what will run in production
configflow preview prod
```

---

## All Commands

**Configuration Management:**
```bash
configflow init              # Generate schema from .env
configflow get KEY           # Fetch a single value
configflow set KEY=VALUE     # Set a value
configflow ls                # List all configuration
configflow validate          # Validate against schema
```

**Configuration Clarity:**
```bash
configflow diff ENV1 ENV2    # Compare environments
configflow explain KEY       # Debug a value
configflow preview ENV       # Preview environment config
```

---

## Type System

ConfigFlow validates 7 configuration types:

| Type | Validates | Example |
|------|-----------|---------|
| `string` | Any text | `"hello"`, `"user@example.com"` |
| `integer` | Whole numbers | `3000`, `42` |
| `boolean` | true/false | `true`, `false` |
| `url` | Valid URLs | `https://api.example.com` |
| `connection_string` | Database URLs | `postgresql://host/db` |
| `secret` | Sensitive values (auto-redacted) | `sk_live_xyz123` |
| `email` | Email addresses | `admin@example.com` |

---

## Smart Warnings

ConfigFlow catches common mistakes automatically:

- ⚠️  Localhost URLs in production
- ⚠️  Test API keys in staging/prod
- ⚠️  Same secrets across environments
- ⚠️  Missing required fields
- ⚠️  Type mismatches

---

## Why ConfigFlow?

### The problem with existing tools:

**dotenv, direnv, etc.**
- ✗ No validation
- ✗ No visibility across environments
- ✗ Can't debug why values are wrong
- ✗ No type safety

**AWS Secrets Manager, GCP Secret Manager**
- ✗ Cloud-specific (vendor lock-in)
- ✗ No local development story
- ✗ Expensive for small teams
- ✗ No configuration clarity features

**Vault, etcd, Consul**
- ✗ Complex setup and maintenance
- ✗ No validation or type checking
- ✗ Steep learning curve
- ✗ Overkill for most teams

### ConfigFlow is different:

- ✓ **Type-safe:** Catch errors before they reach production
- ✓ **Clear:** Know exactly where values come from
- ✓ **Fast:** CLI tool, no servers to maintain
- ✓ **Universal:** Works with files, env vars, Vault
- ✓ **Simple:** 5 minute setup, no infrastructure

---

## Examples

### Catch bugs before deployment

```bash
$ configflow validate --context prod

Validating configuration for context 'prod'...

❌ DATABASE_URL: invalid connection_string
   postgresql://localhost/db contains localhost in 'prod' context

❌ STRIPE_KEY: invalid secret pattern
   sk_test_xxx123 appears to be a test key in 'prod' context

2 errors found. Fix errors before deploying to production.
```

### Understand configuration precedence

```bash
$ configflow explain DATABASE_URL --verbose

Resolution path (checked in order):
  → 1. environment variable: found
    2. source 'local': not found
    3. default value: not found

Current value from environment variable.
This overrides all other sources.
```

### Compare configurations

```bash
$ configflow diff staging prod --show-secrets

STRIPE_KEY:
  staging: sk_test_abc123
  prod:    sk_live_xyz789
  ✓ Different (expected)

DATABASE_URL:
  staging: postgresql://staging-db.internal/db
  prod:    postgresql://prod-db.internal/db
  ✓ Different (expected)
```

---

## Roadmap

**V1 (Current):**
- ✓ CLI with 8 commands
- ✓ 7 type validators
- ✓ File, environment, and Vault sources
- ✓ Configuration clarity (diff, explain, preview)

**V2 (Planned):**
- Static code analysis (discover config usage automatically)
- AWS Secrets Manager / GCP Secret Manager support
- Team collaboration features
- Configuration history and rollback

---

## Contributing

ConfigFlow is open source and contributions are welcome!

```bash
# Run tests
zig build test

# Build
zig build

# Try it out
./zig-out/bin/configflow init
```

---

## Philosophy

**Configuration should be:**
1. **Type-safe** → Catch errors at validation time, not runtime
2. **Traceable** → Know exactly where every value comes from
3. **Comparable** → See differences between environments clearly
4. **Simple** → No servers, no complexity, just a CLI

ConfigFlow believes that configuration chaos isn't inevitable. With the right tools, configuration can be as reliable as your code.

---

## License

MIT License - see [LICENSE](LICENSE) file for details

---

## Community

- 🐛 [Report issues](https://github.com/ryanhair/configflow/issues)
- 💡 [Request features](https://github.com/ryanhair/configflow/discussions)
- 💬 [Join discussions](https://github.com/ryanhair/configflow/discussions)

---

**Stop guessing. Start knowing.**

Try ConfigFlow in your project today:
```bash
configflow init
```
