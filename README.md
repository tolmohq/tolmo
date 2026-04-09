# tolmo

Command-line interface for the repo-1 platform.

## Installation

### Homebrew (macOS / Linux)

```bash
brew tap tolmohq/tolmo https://github.com/tolmohq/tolmo
brew install tolmo
```

Nightly builds:

```bash
brew install tolmo@nightly
```

### Install script (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/tolmohq/tolmo/main/install.sh | sh
```

For nightly builds:

```bash
curl -fsSL https://raw.githubusercontent.com/tolmohq/tolmo/main/install.sh | sh -s -- --nightly
```

### Debian / Ubuntu

Download the `.deb` package from the
[latest release](https://github.com/tolmohq/tolmo/releases/latest):

```bash
sudo dpkg -i tolmo_<version>_<arch>.deb
```

## Authentication

```bash
tolmo auth login
```

Opens a browser-based OAuth flow against the production API. Credentials
are stored in `~/.tolmo/` as a named profile.

### Override organization

Use `--org` to override the active organization for a single command:

```bash
tolmo --org other-org sql "SELECT 1"
```

### Check status

```bash
tolmo auth status
```

### Logout

```bash
tolmo auth logout
```

### Environment variable overrides (CI/CD)

For CI/CD or scripted usage, set these instead of using profiles:

| Variable | Description |
|----------|-------------|
| `TOLMO_API_URL` | Backend API base URL (defaults to production) |
| `TOLMO_API_TOKEN` | API token (skips profile lookup) |
| `TOLMO_ORG_SLUG` | Organization slug (required with `TOLMO_API_TOKEN`) |

## Commands

### `code list`

List repositories available in your organization.

```bash
tolmo code list                  # Table output
tolmo code list --cloneable      # Only repos available for cloning
tolmo code list --json           # JSON output
```

### `code clone`

Clone a repository from storage.

```bash
tolmo code clone org/repo
tolmo code clone github.com/org/repo
```

### `sql`

Execute a SQL query against the organization database.

```bash
tolmo sql "SELECT id, name FROM organization"
tolmo sql --json "SELECT 1"
```

### `cypher`

Execute a Cypher query against the graph database.

```bash
tolmo cypher "MATCH (n) RETURN labels(n), count(*)"
tolmo cypher --json "MATCH (n) RETURN n LIMIT 5"
```
