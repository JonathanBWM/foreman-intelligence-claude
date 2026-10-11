<#
Foreman Intelligence for Claude: one-command Windows installer.

  irm https://github.com/JonathanBWM/foreman-intelligence-claude/releases/latest/download/install.ps1 | iex

Connects Claude Code and/or Claude Desktop to Foreman Intelligence (Looker)
through Google's MCP Toolbox:
  1. downloads a pinned, sha256-verified toolbox.exe (no package manager needed)
  2. asks for the user's Looker API key and checks it against Looker
  3. keeps the secret encrypted with Windows DPAPI (current user), not in a config file
  4. registers one launcher with every Claude app it finds
  5. proves the connection with a real MCP handshake

Re-running is safe and is the repair path. -Uninstall removes everything.
Targets Windows PowerShell 5.1 (built in), so no PowerShell 7 required.

When run through `irm | iex` there are no parameters, so set behaviour through
the FI_* environment variables documented in Get-FiHelp. For flags, download the
file and run it directly:  powershell -ExecutionPolicy Bypass -File install.ps1 -Reconfigure
#>

[CmdletBinding()]
param(
    [ValidateSet('auto', 'code', 'desktop', 'both')]
    [string]$Target = $(if ($env:FI_TARGET) { $env:FI_TARGET } else { 'auto' }),
    [switch]$Reconfigure = [bool]$env:FI_RECONFIGURE,
    [switch]$NoSkill = [bool]$env:FI_NO_SKILL,
    [switch]$Yes = [bool]$env:FI_YES,
    [switch]$Uninstall = [bool]$env:FI_UNINSTALL,
    [switch]$ShowHelp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# Without this, Invoke-WebRequest's progress bar makes large downloads crawl on
# Windows PowerShell 5.1, especially when stdout is redirected.
$ProgressPreference = 'SilentlyContinue'

$FiVersion = '0.1.1'

$ToolboxVersion = '1.13.1'
# Published by Google in the v1.13.1 release notes (googleapis/mcp-toolbox).
$ToolboxSha = @{
    'amd64' = 'fbc00ac9d5be48c5c9948189a33db800087f9bd71778ac1c9c401fcb72a59582'
    'arm64' = 'fe4c49cf945044b837cbb91980cfec6cd816536de74afc0cfae0d46b7aa30f16'
}

$ServerName       = 'foreman-intelligence'
$LegacyServerNames = @('looker-toolbox', 'looker')

# Overridable for testing and for a future move to an OBM domain.
$BaseUrl    = if ($env:FI_BASE_URL)      { $env:FI_BASE_URL }      else { 'https://intelligence.foreman.mn' }
$FiHome     = if ($env:FI_HOME)          { $env:FI_HOME }          else { Join-Path $env:LOCALAPPDATA 'foreman-intelligence' }
$ClaudeDir  = if ($env:FI_CLAUDE_DIR)    { $env:FI_CLAUDE_DIR }    else { Join-Path $env:USERPROFILE '.claude' }
$DesktopCfg = if ($env:FI_DESKTOP_CONFIG){ $env:FI_DESKTOP_CONFIG }else { Join-Path $env:APPDATA 'Claude\claude_desktop_config.json' }
$ToolboxUrlOverride = $env:FI_TOOLBOX_URL
$ToolboxShaOverride = $env:FI_TOOLBOX_SHA256
$ClaudeBinOverride  = $env:FI_CLAUDE_BIN

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$script:LogFile    = $null
$script:Launcher   = $null
$script:ClaudeBin  = $null
$script:WantCode   = $false
$script:WantDesktop = $false

# ---------------------------------------------------------------- output

$script:UseColor = $Host.UI.RawUI -and -not $env:FI_NO_COLOR
function Write-Line([string]$glyph, [string]$color, [string]$msg) {
    if ($script:UseColor) { Write-Host "$glyph " -ForegroundColor $color -NoNewline; Write-Host $msg }
    else { Write-Host "$glyph $msg" }
}
function Log($m)        { Write-Line '->' 'Cyan'   $m }
function LogOk($m)      { Write-Line 'OK' 'Green'  $m }
function LogWarn($m)    { Write-Line '!'  'Yellow' $m }
function Note($m) { if ($script:LogFile) { "{0} {1}" -f (Get-Date -Format s), $m | Out-File -Append -Encoding utf8 $script:LogFile } }
function Step($m) { Write-Host ''; if ($script:UseColor) { Write-Host $m -ForegroundColor White } else { Write-Host $m } }

function Fail($m) {
    Write-Line 'x' 'Red' $m
    if ($script:LogFile -and (Test-Path $script:LogFile)) { Write-Host "  Details: $script:LogFile" -ForegroundColor DarkGray }
    Write-Host "  Running this installer again is safe once the problem is fixed." -ForegroundColor DarkGray
    throw $m
}

function Get-FiHelp {
    @"
Foreman Intelligence for Claude installer v$FiVersion

Run directly for flags:
  powershell -ExecutionPolicy Bypass -File install.ps1 [-Target auto|code|desktop|both]
                                                       [-Reconfigure] [-NoSkill] [-Yes] [-Uninstall]

Through 'irm | iex' there are no flags; use environment variables instead:
  FI_TARGET=desktop        same as -Target
  FI_RECONFIGURE=1         enter a new API key even if one is saved
  FI_NO_SKILL=1            don't install the Claude Code skill
  FI_YES=1                 don't prompt; needs FI_LOOKER_CLIENT_ID and FI_LOOKER_CLIENT_SECRET
  FI_UNINSTALL=1           remove everything this installer added
"@
}

# ---------------------------------------------------------------- prompts

function Test-Interactive { -not $Yes -and -not [Environment]::UserInteractive.Equals($false) -and $Host.UI }

function Confirm-Yes([string]$question, [bool]$default) {
    if ($Yes -or -not (Test-Interactive)) { return $default }
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$question $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a -match '^[Yy]'
}

# ---------------------------------------------------------------- secret (DPAPI)

function Protect-Secret([string]$plain) {
    # DPAPI CurrentUser: only this Windows account can decrypt.
    $ss = ConvertTo-SecureString -String $plain -AsPlainText -Force
    ConvertFrom-SecureString -SecureString $ss
}
function Unprotect-Secret([string]$enc) {
    $ss = ConvertTo-SecureString -String $enc
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Read-SecretFile { $p = Join-Path $FiHome 'secret.dpapi'; if (Test-Path $p) { Unprotect-Secret (Get-Content -Raw $p).Trim() } }

# ---------------------------------------------------------------- helpers

function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower() }

function Get-Arch {
    $a = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $a = $env:PROCESSOR_ARCHITEW6432 }
    switch ($a) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } 'x86' { 'amd64' } default { $null } }
}

function Find-ClaudeCode {
    if ($ClaudeBinOverride) { if (Test-Path $ClaudeBinOverride) { return $ClaudeBinOverride } else { return $null } }
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:USERPROFILE '.local\bin\claude.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe'))) {
        if (Test-Path $p) { return $p }
    }
    $null
}

function Test-ClaudeDesktop {
    (Test-Path (Split-Path $DesktopCfg)) -or
    (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe')) -or
    (Test-Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'))
}

# Reads a JSON config file into a PSCustomObject, or an empty one when
# absent/empty. Returns $null when the file exists but isn't valid JSON.
# Kept as PSCustomObject (not a hashtable) so untouched entries round-trip
# faithfully; a hashtable conversion turns empty arrays into empty objects.
function Read-JsonConfig([string]$path) {
    if (-not (Test-Path $path)) { return (New-Object PSObject) }
    $text = Get-Content -Raw -Path $path
    if ([string]::IsNullOrWhiteSpace($text)) { return (New-Object PSObject) }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}
function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}
function Set-Prop($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
function Write-JsonConfig([string]$path, $tree) {
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($tree | ConvertTo-Json -Depth 20) | Out-File -Encoding utf8 -FilePath $path
}

# ---------------------------------------------------------------- stages

function Initialize-Dirs {
    New-Item -ItemType Directory -Force -Path (Join-Path $FiHome 'bin') | Out-Null
    $script:LogFile = Join-Path $FiHome 'install.log'
    '' | Out-File -Encoding utf8 $script:LogFile
    $script:Launcher = Join-Path $FiHome 'bin\foreman-intelligence-mcp.ps1'
    Note "installer $FiVersion, toolbox $ToolboxVersion, base $BaseUrl"
}

function Select-Targets {
    Step 'Finding Claude'
    $script:ClaudeBin = Find-ClaudeCode
    if ($script:ClaudeBin) { LogOk "Claude Code found at $script:ClaudeBin" }
    $haveDesktop = Test-ClaudeDesktop
    if ($haveDesktop) { LogOk 'Claude Desktop found' }

    switch ($Target) {
        'code'    { $script:WantCode = $true }
        'desktop' { $script:WantDesktop = $true }
        'both'    { $script:WantCode = $true; $script:WantDesktop = $true }
        'auto'    {
            if ($script:ClaudeBin) { $script:WantCode = $true }
            if ($haveDesktop)      { $script:WantDesktop = $true }
        }
    }

    if (-not $script:WantCode -and -not $script:WantDesktop) {
        LogWarn 'No Claude app found on this PC.'
        Write-Host '  Claude Desktop (chat app): download from https://claude.ai/download, then run this again.'
        Write-Host '  Claude Code (terminal): can be installed now.'
        if (Confirm-Yes 'Install Claude Code now?' $true) { $script:WantCode = $true }
        else { Fail 'Install Claude Desktop or Claude Code first, then run this installer again.' }
    }

    if ($script:WantCode -and -not $script:ClaudeBin) {
        Log "Installing Claude Code with Anthropic's official installer"
        try { Invoke-Expression (Invoke-RestMethod 'https://claude.ai/install.ps1') } catch { Fail "Claude Code install failed: $($_.Exception.Message)" }
        $script:ClaudeBin = Find-ClaudeCode
        if (-not $script:ClaudeBin) { Fail "Claude Code installed but the claude command wasn't found. Open a new terminal and run this again." }
        LogOk 'Claude Code installed'
    }
}

function Install-Toolbox {
    Step "Installing the Looker connector (MCP Toolbox $ToolboxVersion)"
    $arch = Get-Arch
    if (-not $arch) { Fail "Unsupported processor: $env:PROCESSOR_ARCHITECTURE" }
    $sha = $ToolboxSha[$arch]
    $url = "https://storage.googleapis.com/mcp-toolbox-for-databases/v$ToolboxVersion/windows/$arch/toolbox.exe"
    if ($ToolboxUrlOverride) { $url = $ToolboxUrlOverride; $sha = $ToolboxShaOverride }
    $dest = Join-Path $FiHome 'bin\toolbox.exe'

    if ((Test-Path $dest) -and (Get-Sha256 $dest) -eq $sha) { LogOk 'Already installed and verified'; return }

    Log "Downloading for $arch"
    Note "toolbox url $url"
    $tmp = Join-Path $FiHome ('bin\toolbox.{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
    try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120 }
    catch { Remove-Item -Force $tmp -ErrorAction SilentlyContinue; Fail 'Could not download the connector. Check your internet connection.' }
    $got = Get-Sha256 $tmp
    if ($got -ne $sha) { Note "sha256 expected $sha got $got"; Remove-Item -Force $tmp; Fail 'The downloaded connector failed its checksum, so it was not installed.' }
    Move-Item -Force $tmp $dest
    LogOk 'Installed and checksum verified'
}

# Returns @{ ok=$bool; error=$string } without ever logging the secret.
function Test-Credentials([string]$id, [string]$secret) {
    $body = 'client_id={0}&client_secret={1}' -f [Uri]::EscapeDataString($id), [Uri]::EscapeDataString($secret)
    try {
        $resp = Invoke-WebRequest -Uri "$BaseUrl/api/4.0/login" -Method Post -Body $body `
            -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 30
        Note "credential check http $($resp.StatusCode)"
        if ($resp.Content -match '"access_token"') { return @{ ok = $true } }
        return @{ ok = $false; error = 'Foreman Intelligence answered, but not with a login token.' }
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Note "credential check failed http $code"
        if ($code -in 400, 401, 403, 404) { return @{ ok = $false; error = "Foreman Intelligence didn't accept that Client ID and Secret." } }
        if ($code) { return @{ ok = $false; error = "Foreman Intelligence returned HTTP $code." } }
        return @{ ok = $false; error = "Couldn't reach $BaseUrl. Check your internet or VPN connection." }
    }
}

function Get-SavedClientId {
    $p = Join-Path $FiHome 'config.json'
    if (Test-Path $p) { try { (ConvertFrom-Json (Get-Content -Raw $p)).client_id } catch { $null } }
}

# The authenticated user's numeric Looker id, or $null. Used to deep-link to
# that user's own API-key admin page, which is keyed by id.
function Get-LookerUserId([string]$id, [string]$secret) {
    try {
        $body = 'client_id={0}&client_secret={1}' -f [Uri]::EscapeDataString($id), [Uri]::EscapeDataString($secret)
        $login = Invoke-RestMethod -Uri "$BaseUrl/api/4.0/login" -Method Post -Body $body `
            -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 20
        if (-not $login.access_token) { return $null }
        $me = Invoke-RestMethod -Uri "$BaseUrl/api/4.0/user?fields=id" `
            -Headers @{ Authorization = "token $($login.access_token)" } -TimeoutSec 20
        if ($me.id) { return [string]$me.id }
    } catch {}
    return $null
}

# The user's own API-key page when the id resolves, else the self-service
# account page (no id, works for everyone).
function Get-ApiKeyUrl([string]$id, [string]$secret) {
    $uid = Get-LookerUserId $id $secret
    if ($uid) { return "$BaseUrl/admin/next/users/api3_key/$uid" }
    return "$BaseUrl/account"
}

function Request-Credentials {
    Step 'Connecting your Foreman Intelligence account'

    if (-not $Reconfigure) {
        $savedId = Get-SavedClientId
        $savedSecret = Read-SecretFile
        if ($savedId -and $savedSecret) {
            Log 'Checking your saved API key'
            if ((Test-Credentials $savedId $savedSecret).ok) { LogOk 'Saved API key still works'; return @{ id = $savedId; secret = $savedSecret } }
            LogWarn "Saved API key no longer works. Let's set up a new one."
        }
    }

    if ($env:FI_LOOKER_CLIENT_ID -and $env:FI_LOOKER_CLIENT_SECRET) {
        Log 'Checking the API key from the environment'
        $r = Test-Credentials $env:FI_LOOKER_CLIENT_ID $env:FI_LOOKER_CLIENT_SECRET
        if (-not $r.ok) { Fail $r.error }
        LogOk 'API key accepted'
        return @{ id = $env:FI_LOOKER_CLIENT_ID; secret = $env:FI_LOOKER_CLIENT_SECRET }
    }

    if (-not (Test-Interactive)) { Fail 'No console to ask for your API key. Set FI_LOOKER_CLIENT_ID and FI_LOOKER_CLIENT_SECRET, or run without -Yes.' }

    Write-Host ''
    Write-Host '  Claude needs a Foreman Intelligence API key tied to your own account.'
    Write-Host '  It only sees what you can already see.'
    Write-Host ''
    Write-Host '  In the page that opens:'
    Write-Host '    1. Sign in if asked'
    Write-Host '    2. Find the API keys / Authentication section (click Manage if shown)'
    Write-Host '    3. Create a new API key, then copy the Client ID and Client Secret'
    Write-Host ''
    Write-Host '  No API-key option? Your account cannot create API keys yet. Ask your'
    Write-Host '  Foreman Intelligence admin, then run this installer again.'
    Write-Host ''
    # Deep-link to this user's own API-key page when a prior key resolves their
    # id; otherwise the self-service account page.
    $openUrl = "$BaseUrl/account"
    $prevId = Get-SavedClientId; $prevSecret = Read-SecretFile
    if ($prevId -and $prevSecret) { $openUrl = Get-ApiKeyUrl $prevId $prevSecret }
    [void](Read-Host '  Press Enter to open Foreman Intelligence in your browser')
    try { Start-Process $openUrl } catch { LogWarn "Couldn't open a browser. Go to $openUrl" }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Host ''
        $id = (Read-Host '  Client ID').Trim()
        $secureSecret = Read-Host '  Client Secret (hidden)' -AsSecureString
        $secret = (New-Object System.Net.NetworkCredential('', $secureSecret)).Password.Trim()
        if (-not $id -or -not $secret) { LogWarn 'Both the Client ID and the Client Secret are needed.'; continue }
        Log 'Checking with Foreman Intelligence'
        $r = Test-Credentials $id $secret
        if ($r.ok) { LogOk 'API key accepted'; return @{ id = $id; secret = $secret } }
        LogWarn $r.error
    }
    Fail "The API key wasn't accepted after 3 tries. Check the Client ID and Secret in Account Settings, then run this again."
}

function Save-Configuration($creds) {
    Step 'Saving your settings'
    Protect-Secret $creds.secret | Out-File -Encoding ascii (Join-Path $FiHome 'secret.dpapi')
    LogOk 'Client Secret encrypted with Windows DPAPI (only your account can read it)'

    @{ base_url = $BaseUrl; client_id = $creds.id; verify_ssl = $true } |
        ConvertTo-Json | Out-File -Encoding utf8 (Join-Path $FiHome 'config.json')

    # The launcher is what every Claude app runs. It decrypts the secret with
    # DPAPI, sets the environment, and hands stdio straight to toolbox.exe.
    $toolbox = Join-Path $FiHome 'bin\toolbox.exe'
    $launcherBody = @'
# Generated by the Foreman Intelligence installer. Re-run the installer to change it.
$ErrorActionPreference = 'Stop'
$fiDir = Split-Path (Split-Path $MyInvocation.MyCommand.Path)
$cfg = ConvertFrom-Json (Get-Content -Raw (Join-Path $fiDir 'config.json'))
$encPath = Join-Path $fiDir 'secret.dpapi'
try {
    $ss = ConvertTo-SecureString -String (Get-Content -Raw $encPath).Trim()
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
} catch {
    [Console]::Error.WriteLine('Foreman Intelligence: cannot read the saved API key. Re-run the installer with -Reconfigure.')
    exit 1
}
$env:LOOKER_BASE_URL = $cfg.base_url
$env:LOOKER_CLIENT_ID = $cfg.client_id
$env:LOOKER_CLIENT_SECRET = $secret
$env:LOOKER_VERIFY_SSL = 'true'
& (Join-Path $fiDir 'bin\toolbox.exe') --stdio --prebuilt looker @args
exit $LASTEXITCODE
'@
    $launcherBody | Out-File -Encoding utf8 $script:Launcher
    LogOk "Settings saved in $FiHome"
}

# Speaks MCP to the launcher exactly as Claude will, and counts the tools.
# Pipes a finite request file through the launcher: toolbox answers, hits EOF
# and exits on its own. A background job bounds it so a wedged connector can't
# hang the install.
function Invoke-SmokeTest {
    Step 'Testing the connection'
    # toolbox logs to stderr; under ErrorActionPreference=Stop PowerShell turns
    # native stderr into a terminating error, so relax it for this call only.
    $ErrorActionPreference = 'Continue'
    $inFile  = Join-Path $FiHome 'smoke-in.jsonl'
    $outFile = Join-Path $FiHome 'smoke-out.txt'
    $errFile = Join-Path $FiHome 'smoke-err.txt'
    # Build the init line on its own statement: inside @( ... ) the comma binds
    # tighter than +, so 'a'+$x+'b', 'c' would fold every line into one string.
    $initLine = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"foreman-intelligence-installer","version":"' + $FiVersion + '"}}}'
    $lines = @(
        $initLine,
        '{"jsonrpc":"2.0","method":"notifications/initialized"}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    )
    Set-Content -Path $inFile -Value $lines -Encoding ascii

    # Finite piped input: toolbox answers then exits on EOF (no hang to bound).
    Get-Content $inFile | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Launcher 1> $outFile 2> $errFile

    $tools = 0
    if (Test-Path $outFile) {
        foreach ($line in (Get-Content $outFile)) {
            if ($line -match '"id":\s*2[,}]') {
                try { $m = ConvertFrom-Json $line; if ($m.result -and $m.result.tools) { $tools = @($m.result.tools).Count } } catch {}
                break
            }
        }
    }
    Note ("smoke stdout: " + ((Get-Content $outFile -ErrorAction SilentlyContinue) -join ' | '))
    if (Test-Path $errFile) { (Get-Content $errFile | ForEach-Object { "  toolbox: $_" }) -join "`n" | Out-File -Append -Encoding utf8 $script:LogFile }
    Remove-Item -Force $inFile, $outFile, $errFile -ErrorAction SilentlyContinue

    if ($tools -lt 1) { Fail "The connector didn't start correctly. The last lines of its output are in the log." }
    LogOk "Connected: Claude will have $tools Foreman Intelligence tools"
}

function Register-ClaudeCode {
    if (-not $script:WantCode) { return }
    Step 'Connecting Claude Code'
    & $script:ClaudeBin mcp remove $ServerName --scope user 2>&1 | Out-Null
    & $script:ClaudeBin mcp add $ServerName --scope user -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Launcher 2>&1 | Out-File -Append -Encoding utf8 $script:LogFile
    if ($LASTEXITCODE -ne 0) { Fail 'Could not register with Claude Code.' }
    LogOk "Added `"$ServerName`" for every Claude Code project"

    $userCfg = Join-Path $env:USERPROFILE '.claude.json'
    $servers = Get-Prop (Read-JsonConfig $userCfg) 'mcpServers'
    if ($servers) {
        foreach ($name in $LegacyServerNames) {
            $s = Get-Prop $servers $name
            if ($s -and (($s | ConvertTo-Json -Depth 10) -match 'toolbox')) {
                LogWarn "An older `"$name`" connector from the manual setup is also configured."
                Write-Host "  Claude would see two copies of every tool. Remove the old one with:"
                Write-Host "    claude mcp remove $name --scope user"
            }
        }
    }

    if (-not $NoSkill) { Install-Skill }
}

function Install-Skill {
    $dir = Join-Path $ClaudeDir 'skills\foreman-intelligence'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $SkillText | Out-File -Encoding utf8 (Join-Path $dir 'SKILL.md')
    LogOk 'Installed the Foreman Intelligence skill for Claude Code'
}

function Register-ClaudeDesktop {
    if (-not $script:WantDesktop) { return }
    Step 'Connecting Claude Desktop'
    $tree = Read-JsonConfig $DesktopCfg
    if ($null -eq $tree) { Fail "Claude Desktop's config file isn't valid JSON, so it was left untouched: $DesktopCfg" }
    if (Test-Path $DesktopCfg) { Copy-Item -Force $DesktopCfg "$DesktopCfg.bak-foreman-intelligence"; Note 'desktop config backed up' }

    $servers = Get-Prop $tree 'mcpServers'
    if ($null -eq $servers) { $servers = New-Object PSObject; Set-Prop $tree 'mcpServers' $servers }
    Set-Prop $servers $ServerName ([pscustomobject]@{
        command = 'powershell.exe'
        args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Launcher)
    })
    Write-JsonConfig $DesktopCfg $tree
    LogOk "Added `"$ServerName`" to Claude Desktop"

    foreach ($name in $LegacyServerNames) {
        if ($name -ne $ServerName -and (Get-Prop $servers $name)) {
            LogWarn "An older `"$name`" connector from the manual setup is also in Claude Desktop."
            Write-Host '  Remove it in Settings -> Developer -> Edit Config so Claude sees one copy of each tool.'
        }
    }

    if ((Get-Process -Name Claude -ErrorAction SilentlyContinue) -and (Test-Interactive)) {
        if (Confirm-Yes 'Claude Desktop is open. Restart it now to load the connector?' $true) {
            Get-Process -Name Claude -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
            $exe = Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'
            if (Test-Path $exe) { Start-Process $exe }
            LogOk 'Claude Desktop restarted'
        } else { LogWarn 'Fully quit Claude Desktop and reopen it to load the connector.' }
    }
}

function Complete-Install($creds) {
    Step 'Done'
    Write-Host ''
    Write-Host '  Foreman Intelligence is connected. Try asking Claude:'
    Write-Host ''
    Write-Host '    "What Explores do I have access to in Foreman Intelligence?"'
    Write-Host '    "Show uptime by site for the last 30 days, then make it a dashboard."'
    Write-Host ''
    if ($script:WantCode)    { Write-Host '  Claude Code: start a new session with `claude` (type /mcp to see the connector).' }
    if ($script:WantDesktop) { Write-Host '  Claude Desktop: open a new chat.' }
    $uid = Get-LookerUserId $creds.id $creds.secret
    if ($uid) {
        Write-Host ''
        Write-Host "  Manage or rotate this key anytime:"
        Write-Host "    $BaseUrl/admin/next/users/api3_key/$uid"
    }
    Write-Host ''
    Write-Host '  Something off later? Run the same install command again; it repairs itself.' -ForegroundColor DarkGray
    Write-Host '  New API key: -Reconfigure. Remove everything: -Uninstall.' -ForegroundColor DarkGray
}

function Invoke-Uninstall {
    Step 'Removing Foreman Intelligence for Claude'
    if (-not (Confirm-Yes 'Remove the connector, its saved API key and its settings?' $true)) { Write-Host 'Nothing removed.'; return }

    $cb = Find-ClaudeCode
    if ($cb) { & $cb mcp remove $ServerName --scope user 2>&1 | Out-Null; LogOk 'Removed from Claude Code' }

    $tree = Read-JsonConfig $DesktopCfg
    if ($null -eq $tree) { LogWarn "Claude Desktop's config isn't valid JSON; remove `"$ServerName`" by hand." }
    else {
        $servers = Get-Prop $tree 'mcpServers'
        if ($servers -and $servers.PSObject.Properties[$ServerName]) {
            $servers.PSObject.Properties.Remove($ServerName)
            Write-JsonConfig $DesktopCfg $tree
            LogOk 'Removed from Claude Desktop (restart it to finish)'
        }
    }

    $skill = Join-Path $ClaudeDir 'skills\foreman-intelligence'
    if (Test-Path $skill) { Remove-Item -Recurse -Force $skill; LogOk 'Removed the Claude Code skill' }
    if (Test-Path $FiHome) { Remove-Item -Recurse -Force $FiHome; LogOk "Removed $FiHome" }
    Write-Host ''
    Write-Host '  The API key itself still exists in Foreman Intelligence. Delete it in'
    Write-Host '  Account Settings -> Authentication if you no longer need it.'
}

# ---------------------------------------------------------------- skill text

$SkillText = @'
---
name: foreman-intelligence
description: How to answer questions and build Looks and dashboards in Foreman Intelligence (Looker) through the foreman-intelligence MCP tools. Use whenever the user asks about their mining fleet data in Foreman Intelligence, wants a chart, Look, dashboard or tile, asks what data or Explores exist, or mentions hashrate, uptime, curtailment, efficiency (J/TH), power, sites or miners in a Foreman Intelligence context.
---

# Foreman Intelligence

Foreman Intelligence is OBM's Looker instance for bitcoin-mining fleet data. The
`foreman-intelligence` MCP tools act as the signed-in user, so Claude sees only
the models, Explores and folders that user can see. Most users don't write SQL,
and they shouldn't need to: build everything from Explores.

## Find the data first

1. `get_models`, then `get_explores` for the model that fits the question.
2. `get_dimensions` and `get_measures` on the chosen Explore. Use the field
   names exactly as returned; never guess a field name.
3. If a filter value is uncertain (a site name, a miner model), check it with
   `get_field_value_suggestions` before filtering on it.

## Show before saving

- Run `query` and show the user the numbers (a small table, at most ~20 rows)
  before creating anything. Ask whether that's what they meant.
- Default to a sensible time window (the last 30 days) and say which one you used.
- Prefer `query` over `query_sql`. Only use SQL when the user asks for it or no
  Explore covers the question, and say so when you do.

## Saving

- Create Looks and dashboards in the user's personal folder unless they name
  another folder.
- Give dashboards plain titles that say what they show ("Uptime by Site, 30
  days"), not internal codes.
- Before changing an existing dashboard, name the exact dashboard and tile and
  get a yes. Never touch another person's content without asking.
- Always finish with the link to what was created or changed.

## Vocabulary

Hashrate is usually reported in TH/s or PH/s, efficiency in J/TH (lower is
better), and power in kW or MW. Curtailment means miners were intentionally
powered down (often for power-price or demand-response reasons), so it is not
the same as downtime. When a drop in hashrate or uptime shows up, check for
curtailment before calling it a problem.
'@

# ---------------------------------------------------------------- main

function Invoke-Main {
    if ($ShowHelp) { Get-FiHelp; return }
    Write-Host ''
    Write-Host "Foreman Intelligence for Claude  installer v$FiVersion"

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Fail 'This installer is for Windows. On macOS use install.sh.' }

    if ($Uninstall) {
        $script:LogFile = $null
        Invoke-Uninstall
        return
    }

    Initialize-Dirs
    Select-Targets
    Install-Toolbox
    $creds = Request-Credentials
    Save-Configuration $creds
    Invoke-SmokeTest
    Register-ClaudeCode
    Register-ClaudeDesktop
    Complete-Install $creds
}

Invoke-Main
