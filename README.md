# Foreman Intelligence for Claude

Connects Claude to [Foreman Intelligence](https://intelligence.foreman.mn) (Looker) through [MCP Toolbox](https://github.com/googleapis/mcp-toolbox). One command handles the binary, credentials, secret storage, and Claude app registration.

Supports macOS and Windows. No package manager needed.

## Install

**macOS:**
```bash
curl -fsSL https://github.com/JonathanBWM/foreman-intelligence-claude/releases/latest/download/install.sh | bash
```

**Windows:**
```powershell
irm https://github.com/JonathanBWM/foreman-intelligence-claude/releases/latest/download/install.ps1 | iex
```

The installer finds your Claude apps, downloads a SHA-256 verified Toolbox binary, walks you through API key creation in the browser, validates the key against Looker, stores the secret in the OS credential store (Keychain on macOS, DPAPI on Windows), registers the MCP server, and runs a handshake to verify the connection.

Requires a Foreman Intelligence account that can create API keys (**Account Settings → Authentication → Manage**). Claude Code needs a paid plan.

## Usage

```
What Explores do I have access to in Foreman Intelligence?
Show uptime by site for the last 30 days, then make it a dashboard.
```

Claude authenticates as you. Same models, same folders.

## Options

**macOS** — pass after `bash -s --`:
```bash
curl -fsSL ...install.sh | bash -s -- --reconfigure
```

**Windows** — env vars or download and pass flags directly:
```powershell
$env:FI_RECONFIGURE=1; irm ...install.ps1 | iex
```

| macOS | Windows | |
|---|---|---|
| `--reconfigure` | `-Reconfigure` / `FI_RECONFIGURE=1` | New API key |
| `--target code\|desktop` | `-Target` / `FI_TARGET=` | Single app |
| `--no-skill` | `-NoSkill` / `FI_NO_SKILL=1` | Skip skill install |
| `--uninstall` | `-Uninstall` / `FI_UNINSTALL=1` | Remove everything |
| `--yes` | `-Yes` / `FI_YES=1` | Non-interactive (needs `FI_LOOKER_CLIENT_ID` + `FI_LOOKER_CLIENT_SECRET`) |

Re-running without flags repairs in place.

## Files

| | macOS | Windows |
|---|---|---|
| Binary + launcher | `~/.foreman-intelligence/bin/` | `%LOCALAPPDATA%\foreman-intelligence\bin\` |
| Config | `~/.foreman-intelligence/config.env` | `%LOCALAPPDATA%\foreman-intelligence\config.json` |
| Secret | Keychain `foreman-intelligence-looker` | DPAPI `…\foreman-intelligence\secret.dpapi` |
| MCP (Code) | `foreman-intelligence` user scope | same |
| MCP (Desktop) | `claude_desktop_config.json` | `%APPDATA%\Claude\claude_desktop_config.json`, and for the MSIX app the package's copy (see Notes) |
| Skill | `~/.claude/skills/foreman-intelligence/` | `%USERPROFILE%\.claude\skills\foreman-intelligence\` |
| PATH | unchanged | Claude Code's folder (`%USERPROFILE%\.local\bin`) added to the user PATH if missing; kept on uninstall |
| Log | `~/.foreman-intelligence/install.log` | `%LOCALAPPDATA%\foreman-intelligence\install.log` |

## Notes

- Legacy `looker-toolbox` connectors from the manual setup will cause duplicate tool registration. Remove them.
- Claude Desktop from claude.ai/download on Windows is an MSIX package. It reads its config from `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json`, while its Edit Config button opens the copy in `%APPDATA%\Claude\` ([anthropics/claude-code#26073](https://github.com/anthropics/claude-code/issues/26073)). The installer finds the package and writes the connector to both.

---

## Development

### Tests

```bash
bash tests/run.sh                                        # macOS
powershell -ExecutionPolicy Bypass -File tests\run.ps1   # Windows PowerShell 5.1
```

`run.sh`: throwaway `$HOME`, mock Keychain, fake Looker, stub binaries. `run.ps1` runs `install.ps1` the way `irm | iex` does, against a fake Looker, a stub `toolbox.exe` and a stub `claude` that behaves like the real one; it edits your user PATH and restores it. CI runs both (Windows under PowerShell 5.1, not pwsh), plus ShellCheck and PSScriptAnalyzer.

### Releases

Bump `FI_VERSION` in `install.sh` and `$FiVersion` in `install.ps1`, commit, tag:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

CI checks the tag against both version strings, runs tests, attaches `install.sh`, `install.ps1`, and `SHA256SUMS`. Pin with `releases/download/v0.1.0/install.sh`.

### Toolbox updates

Update `TOOLBOX_VERSION` and `TOOLBOX_SHA256_*` in both scripts. macOS hashes are `darwin/{arm64,amd64}`, Windows are `windows/{amd64,arm64}`. See Google's [release notes](https://github.com/googleapis/mcp-toolbox/releases).

### Domain migration

Host both scripts at `https://intelligence.foreman.mn/claude/`, update URLs here and in each script header. Nothing else depends on GitHub.
