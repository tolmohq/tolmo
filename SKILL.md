---
name: tolmo
description: |
  Install and use the Tolmo CLI to query infrastructure graphs, run SQL/Cypher
  queries, proxy requests to connected services (AWS, Linear, Sentry, Datadog),
  manage code repositories, and create/manage security findings.
---

# tolmo — Cloud Security Platform CLI

## Installation

### Homebrew (macOS / Linux)

```bash
brew tap tolmohq/tolmo https://github.com/tolmohq/tolmo
brew install tolmo

# Or nightly builds:
brew install tolmo@nightly
```

### Install script (macOS / Linux)

```bash
# Stable
curl -fsSL https://tolmo.com/install.sh | sh

# Nightly
curl -fsSL https://tolmo.com/install.sh | sh -s -- --nightly
```

### Debian / Ubuntu

Download the `.deb` package from the
[latest release](https://github.com/tolmohq/tolmo/releases/latest) and install:

```bash
sudo dpkg -i tolmo_<version>_<arch>.deb
```

## Authentication

```bash
# Interactive login (opens browser)
tolmo auth login

# Check current session
tolmo auth status

# Logout
tolmo auth logout
```

### Environment variables (CI / automation)

| Variable | Description |
|----------|-------------|
| `TOLMO_API_URL` | Backend API base URL (defaults to production) |
| `TOLMO_API_TOKEN` | API token (skips interactive login) |
| `TOLMO_ORG_SLUG` | Organization slug (required with `TOLMO_API_TOKEN`) |

### Named profiles

```bash
# Login to a specific profile
tolmo auth login --profile staging --api-url https://api.staging.example.com

# Use a profile for a single command
tolmo --profile staging sql "SELECT 1"
```

## Commands

### SQL queries

```bash
tolmo sql "SELECT id, name FROM organization"
tolmo sql --json "SELECT 1"
```

### Cypher (graph) queries

```bash
tolmo cypher "MATCH (n) RETURN labels(n), count(*)"
tolmo cypher --json "MATCH (n) RETURN n LIMIT 5"
```

#### Time machine (temporal queries)

Every node and edge has `firstSeenAt` and `lastSeenAt` (epoch ms)
tracking when resources were first discovered and last seen by crawlers.

```bash
# Resources added in the last 7 days
tolmo cypher "MATCH (n:GraphNode) WHERE n.firstSeenAt >= (timestamp() - 7*24*60*60*1000) RETURN n.resourceType, n.resourceKey ORDER BY n.firstSeenAt DESC"

# Stale resources not seen in 48 hours
tolmo cypher "MATCH (n:GraphNode) WHERE n.lastSeenAt < (timestamp() - 48*60*60*1000) RETURN n.resourceType, n.resourceKey LIMIT 50"

# New relationships in the last 24 hours
tolmo cypher "MATCH ()-[r:GRAPH_EDGE]->() WHERE r.firstSeenAt >= (timestamp() - 24*60*60*1000) RETURN r.type, count(r) AS cnt ORDER BY cnt DESC"
```

### Repository operations

```bash
tolmo code list                  # List repositories
tolmo code list --cloneable      # Only repos available for cloning
tolmo code clone org/repo        # Clone a repository
tolmo code clone all             # Clone all cloneable repositories
```

### Query connected services

Credentials are resolved server-side — they never leave the backend.

```bash
tolmo query list                 # List available connected services

# AWS
tolmo query aws ec2 describe-instances
tolmo query aws s3 ls
tolmo query aws iam list-roles

# Linear (GraphQL)
tolmo query linear '{ viewer { id name } }'
tolmo query linear --file query.graphql

# Sentry (REST)
tolmo query sentry /api/0/organizations/acme/issues/

# Datadog (REST)
tolmo query datadog /api/v1/monitors
```

### Threat model artifacts

```bash
tolmo threat-model list                    # List pipeline runs
tolmo threat-model get                     # Download latest run
tolmo threat-model get --run <scanId>      # Download specific run
tolmo threat-model get --step vuln-qualif  # Download single step
```

### Findings

Manage security findings for the current organization. Findings have a
severity (`critical`|`high`|`medium`|`low`|`info`), a visibility
(`draft`|`published` — org members only see published), and a status
(`open`|`in_review`|`closed`).

```bash
# List findings (published only for non-super-admins)
tolmo findings list
tolmo findings list --status open --severity critical
tolmo findings list --json

# Show a single finding (prints markdown description)
tolmo findings get <findingId>
tolmo findings get <findingId> --json

# Create a finding
tolmo findings create \
  --title "Exposed S3 bucket" \
  --severity high \
  --description "Markdown description here"

# Create with description from a file (or '-' for stdin)
tolmo findings create \
  --title "IAM role misconfiguration" \
  --severity critical \
  --description-file ./finding.md \
  --visibility published \
  --status open

# Update fields (only specified flags are changed)
tolmo findings update <findingId> --status in_review
tolmo findings update <findingId> --severity critical --visibility published
tolmo findings update <findingId> --description-file ./updated.md

# Delete (requires --yes)
tolmo findings delete <findingId> --yes
```

#### Findings field reference

| Flag | Values | Default | Notes |
|------|--------|---------|-------|
| `--title` | any string (max 512) | — | Required on create |
| `--severity` | `critical` `high` `medium` `low` `info` | — | Required on create |
| `--description` | markdown string | `""` | Mutually exclusive with `--description-file` |
| `--description-file` | file path or `-` for stdin | — | Mutually exclusive with `--description` |
| `--visibility` | `draft` `published` | `draft` | `draft` findings are hidden from org members |
| `--status` | `open` `in_review` `closed` | `open` | |

### Website data

```bash
tolmo website list               # List crawled domains
tolmo website scans              # List scan history
```

### Organization management

```bash
tolmo org list                   # List organizations
tolmo org switch <slug>          # Switch active organization
```

## Rules for automation

- Always use `--json` for machine-readable output when parsing results
  programmatically.
- Use `--org <slug>` to override the active organization for a single command.
- Use environment variables (`TOLMO_API_TOKEN`, `TOLMO_ORG_SLUG`) in CI/CD
  pipelines instead of interactive login.
- All `query` subcommands proxy through the backend — providers are discovered
  dynamically, so new backend adapters work without a CLI update.
