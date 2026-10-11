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
| MCP (Desktop) | `claude_desktop_config.json` | `%APPDATA%\Claude\claude_desktop_config.json` |
| Skill | `~/.claude/skills/foreman-intelligence/` | `%USERPROFILE%\.claude\skills\foreman-intelligence\` |
| Log | `~/.foreman-intelligence/install.log` | `%LOCALAPPDATA%\foreman-intelligence\install.log` |

## Notes

- Legacy `looker-toolbox` connectors from the manual setup will cause duplicate tool registration. Remove them.

---

## Development

### Tests

```bash
bash tests/run.sh
```

Throwaway `$HOME`, mock Keychain, fake Looker, stub binaries. CI runs on macOS with ShellCheck. The PowerShell installer was validated on a throwaway Windows 10 VM (install, repair, uninstall, DPAPI round-trip). CI lints it with PSScriptAnalyzer.

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
