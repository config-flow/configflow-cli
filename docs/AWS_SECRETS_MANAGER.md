# AWS Secrets Manager Source

ConfigFlow supports fetching configuration from AWS Secrets Manager in two modes: **individual** and **json**.

## Authentication

ConfigFlow resolves AWS credentials in the following priority order:

1. **Environment variables**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` (optional)
2. **AWS credentials file**: `~/.aws/credentials` (default profile)
3. **IAM roles**: (Future enhancement - not yet implemented)

## Region Configuration

The AWS region is resolved with the following precedence:

1. **AWS_REGION environment variable** (highest priority)
2. **region in configflow.yml**

If both are set but different, ConfigFlow will print a warning and use the environment variable.

## Mode: Individual

In **individual** mode, each configuration key corresponds to a separate AWS secret.

### Configuration Example

```yaml
sources:
  aws_prod:
    type: aws_secrets_manager
    region: us-east-1
    mode: individual
    prefix: myapp/prod/  # optional prefix for all secrets
```

### Behavior

With the above configuration:
- Looking up `DATABASE_URL` → fetches AWS secret `myapp/prod/DATABASE_URL`
- Looking up `API_KEY` → fetches AWS secret `myapp/prod/API_KEY`

### AWS Setup

Create individual secrets in AWS Secrets Manager:

```bash
aws secretsmanager create-secret \
    --name myapp/prod/DATABASE_URL \
    --secret-string "postgresql://prod-db:5432/myapp"

aws secretsmanager create-secret \
    --name myapp/prod/API_KEY \
    --secret-string "sk_live_abc123"
```

### Benefits

- ✅ Fine-grained IAM permissions per secret
- ✅ Separate rotation schedules per secret
- ✅ Clear audit trail per secret

### Limitations

- ⚠️ `fetchAll()` not supported (cannot list all secrets efficiently)
- ⚠️ More expensive (billed per secret)

## Mode: JSON

In **json** mode, one AWS secret contains a JSON object with multiple key-value pairs.

### Configuration Example

```yaml
sources:
  aws_prod:
    type: aws_secrets_manager
    region: us-east-1
    mode: json
    secret_name: myapp/prod/config
```

### Behavior

With the above configuration, ConfigFlow fetches the single secret `myapp/prod/config` and parses it as JSON.

### AWS Setup

Create one JSON secret in AWS Secrets Manager:

```bash
aws secretsmanager create-secret \
    --name myapp/prod/config \
    --secret-string '{
      "DATABASE_URL": "postgresql://prod-db:5432/myapp",
      "API_KEY": "sk_live_abc123",
      "REDIS_URL": "redis://prod-redis:6379"
    }'
```

### Benefits

- ✅ `fetchAll()` supported (returns all keys in JSON)
- ✅ Cost-effective (one secret, one API call)
- ✅ Easier to manage related secrets together

### Limitations

- ⚠️ All-or-nothing IAM permissions
- ⚠️ All secrets rotate together
- ⚠️ JSON values are converted to strings

## Complete Configuration Example

```yaml
sources:
  # Individual mode for production secrets
  aws_prod_secrets:
    type: aws_secrets_manager
    region: us-east-1
    mode: individual
    prefix: myapp/prod/secrets/

  # JSON mode for production config
  aws_prod_config:
    type: aws_secrets_manager
    region: us-west-2
    mode: json
    secret_name: myapp/prod/config

  # Environment variables as fallback
  env:
    type: env

config:
  DATABASE_URL:
    type: connection_string
    required: true

  API_KEY:
    type: secret
    required: [prod]

  DEBUG:
    type: boolean
    default: false
```

## Environment Variable Override

You can override the region at runtime:

```bash
# Override configured region
AWS_REGION=eu-west-1 configflow get DATABASE_URL

# ConfigFlow will warn if different from configflow.yml
# Warning: AWS_REGION env var 'eu-west-1' is overriding configflow.yml region 'us-east-1'
```

## Error Handling

### No Credentials

```
Error: No AWS credentials found (env vars or ~/.aws/credentials)
```

**Solution**: Set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` or configure `~/.aws/credentials`

### No Region

```
Error: AWS region not configured (set AWS_REGION env var or region in configflow.yml)
```

**Solution**: Set `AWS_REGION` environment variable or `region` in configflow.yml

### Secret Not Found

When fetching an individual secret that doesn't exist, ConfigFlow returns `null` (treated as not configured).

### Invalid JSON

In JSON mode, if the secret value is not valid JSON, ConfigFlow will return an error.

## IAM Policy Requirements

### Individual Mode

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:myapp/prod/*"
    }
  ]
}
```

### JSON Mode

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:myapp/prod/config*"
    }
  ]
}
```

## Best Practices

1. **Use individual mode for sensitive secrets** (API keys, database passwords) to enable fine-grained access control
2. **Use json mode for application config** (feature flags, URLs, non-sensitive settings) for cost efficiency
3. **Set AWS_REGION in your deployment environment** for flexibility across environments
4. **Use consistent prefixes** (e.g., `myapp/prod/`, `myapp/staging/`) to organize secrets
5. **Enable secret rotation** in AWS Secrets Manager for sensitive credentials

## Pricing Considerations

- **Individual mode**: $0.40/month per secret + $0.05 per 10,000 API calls
- **JSON mode**: $0.40/month for one secret + $0.05 per 10,000 API calls

For 10 configuration values:
- Individual mode: ~$4.00/month
- JSON mode: ~$0.40/month

## Comparison with Other Sources

| Feature | Individual | JSON | Vault | Env |
|---------|-----------|------|-------|-----|
| Fine-grained IAM | ✅ | ❌ | ✅ | ❌ |
| Cost efficient | ❌ | ✅ | ✅ | ✅ |
| fetchAll() support | ❌ | ✅ | ✅ | ✅ |
| Managed service | ✅ | ✅ | ❌ | N/A |
| Automatic rotation | ✅ | ✅ | ✅ | ❌ |
