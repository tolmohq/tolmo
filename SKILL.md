---
name: tolmo
description: |
  Use the Tolmo CLI to query infrastructure graphs, run SQL/Cypher queries,
  proxy requests to connected services (AWS, GitHub, Linear, Sentry, Datadog),
  manage code repositories, and create/manage security findings.
---

# tolmo — Cloud Security Platform CLI

## Installation

```bash
# Homebrew (macOS / Linux)
brew tap tolmohq/tolmo https://github.com/tolmohq/tolmo
brew install tolmo

# Install script
curl -fsSL https://tolmo.com/install.sh | sh

# Debian / Ubuntu
sudo dpkg -i tolmo_<version>_<arch>.deb
```

## Authentication

```bash
tolmo auth login                 # Interactive login (opens browser)
tolmo auth status                # Check current session
tolmo auth logout                # Logout
```

### Environment variables (CI / automation)

| Variable | Description |
|----------|-------------|
| `TOLMO_API_URL` | Backend API base URL (defaults to production) |
| `TOLMO_API_TOKEN` | API token (skips interactive login) |
| `TOLMO_ORG_SLUG` | Organization slug (required with `TOLMO_API_TOKEN`) |

### Named profiles

```bash
tolmo auth login --profile staging --api-url https://api.staging.example.com
tolmo --profile staging sql "SELECT 1"
```

## Global flags

| Flag | Description |
|------|-------------|
| `--org <slug>` | Override the active organization for a single command |
| `--profile <name>` | Use a named profile (default: `TOLMO_PROFILE` env or `default`) |
| `--json` | Output raw JSON (available on most commands) |

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
tolmo code clone all --yes       # Clone all without confirmation prompt
```

`code clone` accepts multiple input forms (GitHub and GitLab):

```bash
tolmo code clone superset-sh/superset
tolmo code clone github.com/superset-sh/superset
tolmo code clone https://github.com/superset-sh/superset/tree/main/apps/relay
tolmo code clone https://github.com/superset-sh/superset ./relay
tolmo code clone https://gitlab.com/group/subgroup/repo
tolmo code clone group/subgroup/repo --provider gitlab
```

### Query connected services

Credentials are resolved server-side — they never leave the backend.
Use `tolmo query list` to discover available providers for an org.

```bash
tolmo query list                           # List available connected services
tolmo query list --org superset            # List for a different org
```

#### REST and GraphQL providers (direct proxy)

```bash
# GitHub REST (proxied through the backend)
tolmo query github /repos/owner/repo/pulls?state=all
tolmo query github /search/issues?q=type:pr+org:myorg

# Linear (GraphQL)
tolmo query linear '{ viewer { id name } }'
tolmo query linear --file query.graphql

# Sentry (REST)
tolmo query sentry /api/0/organizations/acme/issues/

# Datadog (REST)
tolmo query datadog /api/v1/monitors
```

When an org has multiple integrations for the same provider, pass
`--integration <id>` to disambiguate (IDs are shown by `query list`).

#### GitHub CLI passthrough (`tolmo query -- gh ...`)

Runs the local `gh` CLI with a short-lived token injected by the backend
via a Unix socket proxy. This gives you the full `gh` CLI feature set
(pagination, `--jq`, `--template`, etc.) using the org's GitHub App
credentials. The `--` separator is **required** so that `gh` flags pass
through unchanged.

```bash
# List repos
tolmo query -- gh repo list myorg --limit 50

# Search PRs (full gh api syntax)
tolmo query -- gh api search/issues -f "q=type:pr org:myorg created:2026-01-01..2026-03-01" -f per_page=100

# Issues with pagination
tolmo query -- gh issue list --repo myorg/myrepo --state open --json number,title

# Use a different org's credentials
tolmo query --org superset -- gh api /repos/superset-sh/superset/pulls?state=all&per_page=5

# Disambiguate when multiple GitHub integrations exist
tolmo query --integration <id> -- gh repo list
```

#### AWS CLI passthrough (`tolmo query -- aws ...`)

Uses the local AWS CLI with requests proxied through the backend for
credential injection. The `--` separator is **required**.

```bash
tolmo query -- aws ec2 describe-instances
tolmo query -- aws s3 ls
tolmo query -- aws iam list-roles --region us-east-1
tolmo query --org klarify -- aws ec2 describe-security-groups --region ca-central-1
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
(`open`|`in_review`|`closed`|`acknowledged`|`false-positive`).

Finding IDs support prefix matching — the short IDs shown by `list`
(first 8 chars) work in all commands.

```bash
# List findings (published only for non-super-admins)
tolmo findings list
tolmo findings list --status open --severity critical
tolmo findings list --visibility draft --json

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
tolmo findings update <findingId> --severity critical --visibility published
tolmo findings update <findingId> --description-file ./updated.md

# Transition status (dedicated endpoint — only changes status)
tolmo findings status <findingId> in_review
tolmo findings status <findingId> closed
tolmo findings status <findingId> acknowledged
tolmo findings status <findingId> false-positive

# View status change audit trail
tolmo findings history <findingId>

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
| `--status` | `open` `in_review` `closed` `acknowledged` `false-positive` | `open` | |

### Datadog monitors (managed by the platform)

The `monitor` subcommand manages Datadog monitors that the platform owns
on behalf of the org. The backend decrypts the org's Datadog credentials
from the CloudAccount + KMS envelope — the CLI never sees them. Every
monitor created here is stamped with the `managed-by:tolmo` tag, and
update/delete refuse with HTTP 403 on any monitor that does not carry
that tag.

```bash
# Discover what we already manage
tolmo monitor list --tag managed-by:tolmo --json
tolmo monitor get 12345 --json

# Create from a JSON spec (stdin or file). Backend always adds
# `managed-by:tolmo` to the tags before forwarding to Datadog.
tolmo monitor create -f /tmp/cpu-spec.json
cat spec.json | tolmo monitor create -f -

# Update / delete: refused unless the live monitor already carries
# `managed-by:tolmo`. The CLI surfaces the refusal with a clear message.
tolmo monitor update 12345 -f /tmp/patch.json
tolmo monitor delete 12345

# Disambiguate when the org has multiple Datadog integrations
tolmo monitor list --integration <integration-id>
```

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

### Setup (OTEL telemetry for Claude Code)

Configures Claude Code to emit OTEL telemetry (tool calls, assistant
messages) to the Tolmo ingest pipeline. Writes env vars and hooks to
`~/.claude/settings.json`.

```bash
tolmo setup claude-code                      # Enable telemetry for current org
tolmo setup claude-code --disable            # Remove OTEL configuration
tolmo setup claude-code --otel-endpoint URL  # Override default endpoint
```

### Skill management

The CLI embeds a SKILL.md file that can be installed to
`~/.claude/skills/tolmo/SKILL.md` and `~/.agents/skills/tolmo/SKILL.md`
so Claude Code and other agents can discover the CLI's capabilities.

```bash
tolmo skill install              # Install or update the skill
tolmo skill status               # Check installation state
```

## Rules for automation

- Always use `--json` for machine-readable output when parsing results
  programmatically.
- Use `--org <slug>` to override the active organization for a single command.
- Use environment variables (`TOLMO_API_TOKEN`, `TOLMO_ORG_SLUG`) in CI/CD
  pipelines instead of interactive login.
- All `query` subcommands proxy through the backend — providers are discovered
  dynamically, so new backend adapters work without a CLI update.
- For `query -- gh` and `query -- aws`, the `--` separator is mandatory.
  Without it, cobra strips unknown flags (like `--region`, `--repo`) before
  they reach the underlying CLI.
