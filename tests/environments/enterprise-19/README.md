# Oracle Enterprise 19c Environment

Uses `container-registry.oracle.com/database/enterprise:19.3.0.0`.

## OCR Login Required

Oracle Enterprise images require authentication. Log in before pulling:

```bash
docker login container-registry.oracle.com
```

## Image Selection

Only two 19c tags exist on OCR:

| Tag | Architecture |
|-----|-------------|
| `19.3.0.0` | amd64 |
| `19.19.0.0` | arm64 only |

Picked `19.3.0.0` since `19.19.0.0` is arm64-only.

## First Boot

First boot runs DBCA and takes ~12 minutes. The named volume (`oradata`) persists the database for fast subsequent starts.
