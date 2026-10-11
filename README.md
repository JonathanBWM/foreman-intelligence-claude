# Foreman Intelligence for Claude

One-shot installer that connects Claude (Desktop and/or Code) to your [Foreman Intelligence](https://intelligence.foreman.mn) instance via MCP. Downloads a pinned, checksum-verified [MCP Toolbox](https://github.com/googleapis/mcp-toolbox) binary, authenticates against your Looker API key, stores the secret in the OS secret store, and registers the connector with every Claude app it finds.

macOS and Windows. No Homebrew or package manager required.

## Install

macOS (Terminal):

```bash
curl -fsSL https://github.com/JonathanBWM/foreman-intelligence-claude/releases/latest/download/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://github.com/JonathanBWM/foreman-intelligence-claude/releases/latest/download/install.ps1 | iex
```

The script will:
1. Detect installed Claude apps (offers to install Claude Code if neither is present)
2. Download and verify the MCP Toolbox binary (SHA-256)
3. Open Foreman Intelligence in your browser for API key creation
4. Validate credentials against the Looker login endpoint
5. Store the Client Secret in the OS secret store (macOS Keychain; Windows DPAPI, per user)
6. Register the MCP server with your Claude apps
7. Run an MCP handshake to confirm the connection

You need a Foreman Intelligence account with API key permissions (**Account Settings → Authentication → Manage**). Claude Code requires a paid Claude plan.

## Usage

After install, open Claude and ask:

```
What Explores do I have access to in Foreman Intelligence?
```
```
Show uptime by site for the last 30 days, then make it a dashboard.
```

Claude authenticates as you — same models, same folder access.

## Options

macOS passes flags after `bash -s --`:

```bash
curl -fsSL ...install.sh | bash -s -- --reconfigure
```

Windows run through `irm | iex` takes no flags; set `FI_*` environment variables instead, or download the file and run it with the matching `-Flag`:

```powershell
$env:FI_RECONFIGURE=1; irm ...install.ps1 | iex
```

| macOS flag | Windows flag / env | Description |
|---|---|---|
| `--reconfigure` | `-Reconfigure` / `FI_RECONFIGURE=1` | Force new API key prompt |
| `--target code\|desktop` | `-Target code\|desktop` / `FI_TARGET=` | Connect only one Claude app |
| `--no-skill` | `-NoSkill` / `FI_NO_SKILL=1` | Skip the Claude Code skill |
| `--uninstall` | `-Uninstall` / `FI_UNINSTALL=1` | Remove everything |
| `--yes` | `-Yes` / `FI_YES=1` | Non-interactive (requires `FI_LOOKER_CLIENT_ID` and `FI_LOOKER_CLIENT_SECRET` in env) |

Re-running the installer without flags is the repair path. It checks each component and only fixes what's broken.

## File locations

| What | macOS | Windows |
|---|---|---|
| Connector + launcher | `~/.foreman-intelligence/bin/` | `%LOCALAPPDATA%\foreman-intelligence\bin\` |
| Config (base URL, client ID) | `~/.foreman-intelligence/config.env` | `%LOCALAPPDATA%\foreman-intelligence\config.json` |
| Client Secret | macOS Keychain (`foreman-intelligence-looker`) | DPAPI blob `…\foreman-intelligence\secret.dpapi` (decryptable only by your Windows user) |
| Claude Code MCP | `foreman-intelligence` at user scope | same |
| Claude Desktop MCP | `claude_desktop_config.json` | `%APPDATA%\Claude\claude_desktop_config.json` |
| Skill | `~/.claude/skills/foreman-intelligence/` | `%USERPROFILE%\.claude\skills\foreman-intelligence\` |
| Log | `~/.foreman-intelligence/install.log` | `%LOCALAPPDATA%\foreman-intelligence\install.log` |

## Known issues

- If you have a `looker-toolbox` connector from the older manual setup, remove it or Claude will register duplicate tools

---

## Development

### Tests

```bash
bash tests/run.sh
```

Runs against a throwaway `$HOME` with its own Keychain, mock Looker endpoint, and stub binaries. Does not touch your real Claude config. CI runs these on macOS alongside ShellCheck.

`install.ps1` has no automated CI test (the real integration path needs a live Looker and a Windows session). It was validated end-to-end on a throwaway Windows 10 VM: fresh install, repair re-run, and uninstall, including the Claude Desktop config merge and DPAPI round-trip. CI parse-checks and lints it with PSScriptAnalyzer.

### Releases

Bump `FI_VERSION` in `install.sh` **and `$FiVersion` in `install.ps1`** to the same value, commit, tag:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

CI validates the tag matches both versions, runs tests, and attaches `install.sh`, `install.ps1` and `SHA256SUMS` to the release. Pin a version with `releases/download/v0.1.0/install.sh` (or `.ps1`).

### Updating MCP Toolbox

Change `TOOLBOX_VERSION` and the `TOOLBOX_SHA256_*` values in **both** `install.sh` and `install.ps1`. macOS uses the `darwin/{arm64,amd64}` hashes; Windows uses `windows/{amd64,arm64}`. All are in Google's [release notes](https://github.com/googleapis/mcp-toolbox/releases).

### Domain migration

Host `install.sh` and `install.ps1` at `https://intelligence.foreman.mn/claude/` and update the URLs here and in each script header. Nothing else depends on GitHub.
