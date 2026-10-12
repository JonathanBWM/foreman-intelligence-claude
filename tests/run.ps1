# End-to-end tests for install.ps1 under Windows PowerShell 5.1, which is what
# `irm | iex` gets on a stock Windows PC. Each run pipes the installer into
# Invoke-Expression in a fresh powershell.exe, the way the one-liner does,
# against a fake Looker server, a stub toolbox.exe and a stub claude that acts
# like the real CLI: "mcp remove" of a server that isn't registered prints to
# stderr and exits 1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
#
# Run it from Windows PowerShell (it compiles the stub toolbox.exe with
# Add-Type). Needs python for the fake Looker server. Adding Claude Code to the
# user PATH is under test, so this edits the current user's PATH in the
# registry and puts it back when done.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Root      = Split-Path -Parent $PSScriptRoot
$Installer = Join-Path $Root 'install.ps1'
$TempRoot  = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$Work      = Join-Path $TempRoot ('fi-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:Pass = 0
$script:Fail = 0
$script:Out = ''
$script:ExitCode = $null

function Ok($m)  { $script:Pass++; Write-Host "  ok    $m" }
function Bad($m) { $script:Fail++; Write-Host "  FAIL  $m" }
function Check([string]$name, [scriptblock]$test) {
    $r = $false
    try { $r = [bool](& $test) } catch { $r = $false }
    if ($r) { Ok $name } else { Bad $name }
}

$GoodId     = 'test-client-id'
$GoodSecret = 's3cret "with" odd&chars %PATH%'
$Sentinel   = '%USERPROFILE%\fi-path-sentinel'

$HomeDir   = Join-Path $Work 'home'            # stands in for %USERPROFILE%
$ClaudeDir = Join-Path $HomeDir '.local\bin'   # where Anthropic's installer puts claude
$FiHome    = Join-Path $Work 'foreman-intelligence'
$Launcher  = Join-Path $FiHome 'bin\foreman-intelligence-mcp.ps1'

# ---------------------------------------------------------------- user PATH

function Open-EnvKey([bool]$write) { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $write) }
function Get-UserPath {
    $k = Open-EnvKey $false
    try { [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $k.Close() }
}
function Get-UserPathKind {
    $k = Open-EnvKey $false
    try { [string]$k.GetValueKind('Path') } finally { $k.Close() }
}
function Get-PathCount([string]$dir) {
    @((Get-UserPath) -split ';' | Where-Object { $_.TrimEnd('\') -eq $dir.TrimEnd('\') }).Count
}

# ---------------------------------------------------------------- running it

function Get-Calls {
    $f = Join-Path $ClaudeDir 'calls.log'
    if (Test-Path $f) { @(Get-Content $f | ForEach-Object { $_.Trim() }) } else { @() }
}

# Runs the installer the way `irm | iex` does: piped into Invoke-Expression in
# a fresh Windows PowerShell, so the installer and the session share a scope.
function Invoke-Installer([hashtable]$extra = @{}) {
    $vars = @{
        USERPROFILE             = $HomeDir
        FI_HOME                 = $FiHome
        FI_CLAUDE_DIR           = (Join-Path $HomeDir '.claude')
        FI_DESKTOP_CONFIG       = (Join-Path $Work 'Claude\claude_desktop_config.json')
        FI_BASE_URL             = "http://127.0.0.1:$Port"
        FI_TOOLBOX_URL          = "http://127.0.0.1:$Port/toolbox.exe"
        FI_TOOLBOX_SHA256       = $ToolboxSha
        FI_LOOKER_CLIENT_ID     = $GoodId
        FI_LOOKER_CLIENT_SECRET = $GoodSecret
        FI_TARGET               = 'code'
        FI_YES                  = '1'
        FI_NO_COLOR             = '1'
        FI_UNINSTALL            = $null
    }
    foreach ($k in $extra.Keys) { $vars[$k] = $extra[$k] }
    Remove-Item -Force (Join-Path $ClaudeDir 'calls.log') -ErrorAction SilentlyContinue

    $cmd = @"
try { Get-Content -Raw -LiteralPath '$Installer' | Invoke-Expression }
catch { 'INSTALLER STOPPED: ' + `$_.Exception.Message; `$_.InvocationInfo.PositionMessage; exit 1 }
if (Get-Command claude -ErrorAction SilentlyContinue) { 'CLAUDE ON SESSION PATH' }
exit 0
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try {
        # The child's stderr comes back as error records; keep them as text
        # rather than letting Stop end the test.
        $ErrorActionPreference = 'Continue'
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" })
        $script:ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $script:Out = $lines -join "`n"
    if ($script:ExitCode -ne 0) { Write-Host $script:Out }
}

# ---------------------------------------------------------------- fixtures

$Server = $null
$PathSaved = $false
try {
    Write-Host "Windows PowerShell $($PSVersionTable.PSVersion)"
    if (Get-Command claude -ErrorAction SilentlyContinue) { throw 'A real claude is on PATH; run this where Claude Code is not on PATH.' }
    New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null

    # Stub claude: logs every call and keeps one registration like the real CLI.
    # CRLF line endings, since cmd.exe can miss labels in LF-only batch files.
    @'
@echo off
>>"%~dp0calls.log" echo %*
if /i not "%~1"=="mcp" exit /b 0
if /i "%~2"=="add" goto add
if /i "%~2"=="remove" goto remove
exit /b 0
:add
>"%~dp0registered" echo %*
echo Added stdio MCP server %~3 to user config
exit /b 0
:remove
if not exist "%~dp0registered" goto missing
del "%~dp0registered"
echo Removed MCP server %~3 from user config
exit /b 0
:missing
>&2 echo No MCP server named "%~3" in user scope
exit /b 1
'@ -split "`r?`n" | Set-Content -Encoding ascii -Path (Join-Path $ClaudeDir 'claude.cmd')

    # Stub toolbox: answers initialize and tools/list, but only when the
    # launcher handed it the right credentials from the DPAPI file.
    $Toolbox = Join-Path $Work 'toolbox.exe'
    Add-Type -OutputAssembly $Toolbox -OutputType ConsoleApplication -TypeDefinition @'
using System;
public static class StubToolbox {
    public static int Main(string[] args) {
        if (Environment.GetEnvironmentVariable("LOOKER_CLIENT_ID") != Environment.GetEnvironmentVariable("FI_TEST_ID") ||
            Environment.GetEnvironmentVariable("LOOKER_CLIENT_SECRET") != Environment.GetEnvironmentVariable("FI_TEST_SECRET")) {
            Console.Error.WriteLine("bad credentials in environment");
            return 1;
        }
        if (string.Join(" ", args) != "--stdio --prebuilt looker") {
            Console.Error.WriteLine("bad args: " + string.Join(" ", args));
            return 1;
        }
        string line;
        while ((line = Console.ReadLine()) != null) {
            if (line.Contains("\"id\":1")) Console.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"stub\",\"version\":\"0\"}}}");
            else if (line.Contains("\"id\":2")) Console.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"get_models\"},{\"name\":\"get_explores\"},{\"name\":\"query\"}]}}");
        }
        return 0;
    }
}
'@
    $ToolboxSha = (Get-FileHash -Algorithm SHA256 -Path $Toolbox).Hash.ToLower()

    # Fake Looker: login, the "me" lookup, and the toolbox download.
    $env:FI_TEST_ID      = $GoodId
    $env:FI_TEST_SECRET  = $GoodSecret
    $env:FI_TEST_TOOLBOX = $Toolbox
    $LookerPy = Join-Path $Work 'looker.py'
    $PortFile = Join-Path $Work 'port'
    @'
import http.server, os, sys, urllib.parse
ID, SECRET, TOOLBOX = os.environ['FI_TEST_ID'], os.environ['FI_TEST_SECRET'], os.environ['FI_TEST_TOOLBOX']
class H(http.server.BaseHTTPRequestHandler):
    # PowerShell 5.1 only hands back text (and Invoke-RestMethod only parses
    # JSON) when the response says what it is, as Looker's does.
    def reply(self, code, body, ctype='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        q = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get('Content-Length', 0))).decode())
        if self.path == '/api/4.0/login' and q.get('client_id') == [ID] and q.get('client_secret') == [SECRET]:
            self.reply(200, b'{"access_token":"t","token_type":"Bearer","expires_in":3600}')
        else:
            self.reply(404, b'{"message":"Not found"}')
    def do_GET(self):
        if self.path == '/toolbox.exe':
            with open(TOOLBOX, 'rb') as f:
                self.reply(200, f.read(), 'application/octet-stream')
        elif self.path.startswith('/api/4.0/user') and self.headers.get('Authorization') == 'token t':
            self.reply(200, b'{"id":43,"display_name":"Test"}')
        else:
            self.reply(404, b'{"message":"Not found"}')
    def log_message(self, *a):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), H)
with open(sys.argv[1], 'w') as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
'@ | Set-Content -Encoding ascii -Path $LookerPy
    $Server = Start-Process -FilePath python -ArgumentList @("`"$LookerPy`"", "`"$PortFile`"") -NoNewWindow -PassThru
    $Port = $null
    for ($i = 0; $i -lt 100 -and -not $Port; $i++) {
        Start-Sleep -Milliseconds 100
        if ($Server.HasExited) { throw 'The fake Looker server exited.' }
        try { $t = Get-Content -Raw $PortFile -ErrorAction Stop; if ($t) { $Port = $t.Trim() } } catch { }
    }
    if (-not $Port) { throw 'The fake Looker server did not start.' }

    # Save the real user PATH, then add an unexpanded entry the installer must
    # leave exactly as it is.
    $k = Open-EnvKey $false
    $OrigPath = $k.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $OrigKind = if ($null -ne $OrigPath) { $k.GetValueKind('Path') } else { $null }
    $k.Close()
    $PathSaved = $true
    $seed = if ($OrigPath) { ([string]$OrigPath).TrimEnd(';') + ';' + $Sentinel } else { $Sentinel }
    $k = Open-EnvKey $true
    $k.SetValue('Path', $seed, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    $k.Close()

    # ------------------------------------------------------------ tests

    Write-Host 'Fresh install: Claude Code installed but not on PATH, nothing registered yet'
    Invoke-Installer
    Check 'installer exits 0' { $script:ExitCode -eq 0 }
    Check 'runs to the end' { $script:Out -match 'Foreman Intelligence is connected' }
    Check "smoke test counted the stub's tools" { $script:Out -match 'Claude will have 3 Foreman Intelligence tools' }
    Check 'cleared any old registration first' { (Get-Calls) -contains 'mcp remove foreman-intelligence --scope user' }
    Check 'registered with Claude Code at user scope' { (Get-Calls) -contains "mcp add foreman-intelligence --scope user -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Launcher" }
    Check 'Claude Code skill installed' { Test-Path (Join-Path $HomeDir '.claude\skills\foreman-intelligence\SKILL.md') }
    Check "claude's folder added to the user PATH once" { (Get-PathCount $ClaudeDir) -eq 1 }
    Check 'says so' { $script:Out -match 'to your PATH' }
    Check 'user PATH is still REG_EXPAND_SZ' { (Get-UserPathKind) -eq 'ExpandString' }
    Check 'other PATH entries left unexpanded' { ((Get-UserPath) -split ';') -contains $Sentinel }
    Check 'claude works in the same window right away' { $script:Out -match 'CLAUDE ON SESSION PATH' }
    Check 'secret never printed' { -not $script:Out.Contains($GoodSecret) }
    Check 'secret not in the install log' { -not (Get-Content -Raw (Join-Path $FiHome 'install.log')).Contains($GoodSecret) }
    Check 'prints direct API-key URL with resolved id' { $script:Out -match 'admin/next/users/api3_key/43' }

    Write-Host 'Re-run repairs in place'
    Invoke-Installer
    Check 'second run exits 0' { $script:ExitCode -eq 0 }
    Check 'toolbox not downloaded again' { $script:Out -match 'Already installed and verified' }
    Check 'saved key reused' { $script:Out -match 'Saved API key still works' }
    Check 'still registered' { Test-Path (Join-Path $ClaudeDir 'registered') }
    Check 'PATH entry not duplicated' { (Get-PathCount $ClaudeDir) -eq 1 }

    Write-Host 'Uninstall removes what it added'
    Invoke-Installer @{ FI_UNINSTALL = '1' }
    Check 'uninstall exits 0' { $script:ExitCode -eq 0 }
    Check 'removed from Claude Code' { $script:Out -match 'Removed from Claude Code' }
    Check 'no longer registered' { -not (Test-Path (Join-Path $ClaudeDir 'registered')) }
    Check 'install folder removed' { -not (Test-Path $FiHome) }
    Check 'skill removed' { -not (Test-Path (Join-Path $HomeDir '.claude\skills\foreman-intelligence')) }
    Check 'PATH left alone (Claude Code still lives there)' { (Get-PathCount $ClaudeDir) -eq 1 }

    Write-Host 'Uninstall with nothing registered in Claude Code'
    Invoke-Installer @{ FI_UNINSTALL = '1' }
    Check 'uninstall exits 0' { $script:ExitCode -eq 0 }
    Check "doesn't claim a removal" { $script:Out -notmatch 'Removed from Claude Code' }
} finally {
    if ($PathSaved) {
        $k = Open-EnvKey $true
        if ($null -eq $OrigPath) { $k.DeleteValue('Path', $false) } else { $k.SetValue('Path', $OrigPath, $OrigKind) }
        $k.Close()
    }
    if ($Server -and -not $Server.HasExited) { Stop-Process -Id $Server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
