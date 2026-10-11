#!/usr/bin/env bash
# Checks are passed to eval in single quotes on purpose.
# shellcheck disable=SC2016,SC2034
# End-to-end tests for install.sh. Everything runs in a throwaway HOME with a
# throwaway Keychain, a fake Looker login endpoint, a stub `claude` and a stub
# toolbox, so nothing touches the real machine's Claude setup or Keychain.
#
#   bash tests/run.sh
#
# Needs macOS (security, osascript) and python3 for the fake Looker server.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fi-tests.XXXXXX")"
PASS=0
FAIL=0
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    security delete-keychain "$WORK/test.keychain-db" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

GOOD_ID="test-client-id"
GOOD_SECRET='s3cret"with$odd\chars'

# ---------------------------------------------------------------- fixtures

security create-keychain -p test "$WORK/test.keychain-db"
security unlock-keychain -p test "$WORK/test.keychain-db"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
cat >"$WORK/looker.py" <<EOF
import http.server, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        q = urllib.parse.parse_qs(body)
        good = q.get('client_id') == ['$GOOD_ID'] and q.get('client_secret') == [r'''$GOOD_SECRET''']
        if self.path == '/api/4.0/login' and good:
            self.send_response(200); self.end_headers()
            self.wfile.write(b'{"access_token":"t","token_type":"Bearer","expires_in":3600}')
        else:
            self.send_response(404); self.end_headers(); self.wfile.write(b'{"message":"Not found"}')
    def do_GET(self):
        if self.path.startswith('/api/4.0/user') and self.headers.get('Authorization') == 'token t':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'{"id":43,"display_name":"Test"}')
        else:
            self.send_response(404); self.end_headers(); self.wfile.write(b'{"message":"Not found"}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', $PORT), H).serve_forever()
EOF
python3 "$WORK/looker.py" &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

# Stub toolbox: answers initialize and tools/list, but only when the launcher
# handed it the right secret from the Keychain.
cat >"$WORK/toolbox" <<EOF
#!/bin/bash
if [ "\$LOOKER_CLIENT_SECRET" != '$GOOD_SECRET' ] || [ "\$LOOKER_CLIENT_ID" != '$GOOD_ID' ]; then
    echo "bad credentials in environment" >&2; exit 1
fi
[ "\$*" = "--stdio --prebuilt looker" ] || { echo "bad args: \$*" >&2; exit 1; }
while IFS= read -r line; do
    case "\$line" in
        *'"id":1'*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"stub","version":"0"}}}' ;;
        *'"id":2'*) echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"get_models"},{"name":"get_explores"},{"name":"query"}]}}' ;;
    esac
done
EOF
chmod +x "$WORK/toolbox"
TOOLBOX_SHA="$(shasum -a 256 "$WORK/toolbox" | cut -d' ' -f1)"

# Stub claude: records every call.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >>"$WORK/claude-calls.log"
EOF
chmod +x "$WORK/bin/claude"

new_home() {
    HOME_DIR="$WORK/home-$1"
    mkdir -p "$HOME_DIR/Library/Application Support/Claude"
    : >"$WORK/claude-calls.log"
}

run_installer() {
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME_DIR" TMPDIR="$WORK" \
        FI_BASE_URL="http://127.0.0.1:$PORT" \
        FI_KEYCHAIN="$WORK/test.keychain-db" \
        FI_TOOLBOX_URL="file://$WORK/toolbox" FI_TOOLBOX_SHA256="${SHA_OVERRIDE:-$TOOLBOX_SHA}" \
        FI_CLAUDE_BIN="$WORK/bin/claude" \
        FI_LOOKER_CLIENT_ID="${ID_OVERRIDE-$GOOD_ID}" FI_LOOKER_CLIENT_SECRET="${SECRET_OVERRIDE-$GOOD_SECRET}" \
        bash "$INSTALLER" --yes "$@" </dev/null >"$WORK/out.txt" 2>&1
}

desktop_json() { cat "$HOME_DIR/Library/Application Support/Claude/claude_desktop_config.json"; }

# ---------------------------------------------------------------- tests

echo "Fresh install into both apps"
new_home fresh
cat >"$HOME_DIR/Library/Application Support/Claude/claude_desktop_config.json" <<'EOF'
{
  "mcpServers": {
    "other-server": { "command": "/usr/bin/true", "args": [] }
  },
  "globalShortcut": "Alt+Space"
}
EOF
if run_installer --target both; then ok "installer exits 0"; else bad "installer exits 0"; cat "$WORK/out.txt"; fi
FIH="$HOME_DIR/.foreman-intelligence"
check "toolbox installed and executable" '[ -x "$FIH/bin/toolbox" ]'
check "launcher installed" '[ -x "$FIH/bin/foreman-intelligence-mcp" ]'
check "config.env is private" '[ "$(stat -f %Lp "$FIH/config.env")" = "600" ]'
check "config.env holds the client id" 'grep -q "LOOKER_CLIENT_ID=$GOOD_ID" "$FIH/config.env"'
check "secret is not in config.env" '! grep -qF "s3cret" "$FIH/config.env"'
check "secret is not in the install log" '! grep -qF "s3cret" "$FIH/install.log"'
check "hex secret is not in the install log" '! grep -q "$(printf %s "$GOOD_SECRET" | od -An -tx1 | tr -d " \n")" "$FIH/install.log"'
check "secret stored in Keychain" '[ "$(security find-generic-password -s foreman-intelligence-looker -a looker-api-secret -w "$WORK/test.keychain-db")" = "$GOOD_SECRET" ]'
check "smoke test counted the stub's tools" 'grep -q "3 Foreman Intelligence tools" "$WORK/out.txt"'
check "registered with Claude Code at user scope" 'grep -qx "mcp add foreman-intelligence --scope user -- $FIH/bin/foreman-intelligence-mcp" "$WORK/claude-calls.log"'
check "desktop config has the new server" 'desktop_json | grep -q "\"foreman-intelligence\""'
check "desktop config kept the other server" 'desktop_json | grep -q "\"other-server\""'
check "desktop config kept other settings" 'desktop_json | grep -q "globalShortcut"'
check "desktop config was backed up" '[ -f "$HOME_DIR/Library/Application Support/Claude/claude_desktop_config.json.bak-foreman-intelligence" ]'
check "Claude Code skill installed" '[ -f "$HOME_DIR/.claude/skills/foreman-intelligence/SKILL.md" ]'
check "secret never printed" '! grep -qF "s3cret" "$WORK/out.txt"'
check "prints direct API-key URL with resolved id" 'grep -q "admin/next/users/api3_key/43" "$WORK/out.txt"'

echo "Re-run repairs without re-downloading"
if run_installer --target both; then ok "second run exits 0"; else bad "second run exits 0"; cat "$WORK/out.txt"; fi
check "toolbox not downloaded again" 'grep -q "Already installed and verified" "$WORK/out.txt"'
check "saved key reused" 'grep -q "Saved API key still works" "$WORK/out.txt"'
check "still exactly one desktop entry" '[ "$(desktop_json | grep -c "\"foreman-intelligence\"")" = "1" ]'

echo "Bad credentials are rejected before anything is registered"
new_home badcreds
if SECRET_OVERRIDE="wrong" run_installer --target both; then bad "installer fails"; else ok "installer fails"; fi
check "explains the problem" 'grep -q "didn.t accept that Client ID and Secret" "$WORK/out.txt"'
check "nothing registered with Claude Code" '! grep -q "mcp add" "$WORK/claude-calls.log"'
check "desktop config not created" '[ ! -f "$HOME_DIR/Library/Application Support/Claude/claude_desktop_config.json" ]'

echo "Tampered download is refused"
new_home badsha
security delete-generic-password -s foreman-intelligence-looker -a looker-api-secret "$WORK/test.keychain-db" >/dev/null 2>&1 || true
if SHA_OVERRIDE="0000000000000000000000000000000000000000000000000000000000000000" run_installer --target code; then bad "installer fails"; else ok "installer fails"; fi
check "explains the checksum failure" 'grep -q "failed its checksum" "$WORK/out.txt"'
check "no toolbox left behind" '[ ! -e "$HOME_DIR/.foreman-intelligence/bin/toolbox" ]'

echo "Broken Claude Desktop JSON is left untouched"
new_home badjson
printf '{ "mcpServers": { broken\n' >"$HOME_DIR/Library/Application Support/Claude/claude_desktop_config.json"
if run_installer --target desktop; then bad "installer fails"; else ok "installer fails"; fi
check "explains the JSON problem" 'grep -q "isn.t valid JSON" "$WORK/out.txt"'
check "file unchanged" '[ "$(desktop_json)" = "{ \"mcpServers\": { broken" ]'

echo "Old manual-setup connector is flagged"
new_home legacy
cat >"$HOME_DIR/.claude.json" <<'EOF'
{ "mcpServers": { "looker-toolbox": { "type": "stdio", "command": "/opt/homebrew/bin/toolbox", "args": ["--stdio","--prebuilt","looker"] } } }
EOF
run_installer --target code || { bad "legacy install exits 0"; cat "$WORK/out.txt"; }
check "warns about looker-toolbox" 'grep -q "older \"looker-toolbox\" connector" "$WORK/out.txt"'

echo "Uninstall removes everything it added"
HOME_DIR="$WORK/home-fresh"
: >"$WORK/claude-calls.log"
if run_installer --uninstall; then ok "uninstall exits 0"; else bad "uninstall exits 0"; cat "$WORK/out.txt"; fi
check "removed from Claude Code" 'grep -qx "mcp remove foreman-intelligence --scope user" "$WORK/claude-calls.log"'
check "removed from Claude Desktop" '! desktop_json | grep -q "\"foreman-intelligence\""'
check "other desktop server kept" 'desktop_json | grep -q "\"other-server\""'
check "install folder removed" '[ ! -e "$HOME_DIR/.foreman-intelligence" ]'
check "skill removed" '[ ! -e "$HOME_DIR/.claude/skills/foreman-intelligence" ]'
check "Keychain item removed" '! security find-generic-password -s foreman-intelligence-looker -a looker-api-secret "$WORK/test.keychain-db" >/dev/null 2>&1'

echo "A download cut off at any point runs nothing"
# main() is only called on the last line, so every prefix of the file must be
# side-effect free: no output and no files, whatever line the cut lands on.
TRUNC_HOME="$WORK/home-truncated"
mkdir -p "$TRUNC_HOME"
total="$(wc -l <"$INSTALLER")"
trunc_ok=true
for n in $(seq 1 37 $((total - 1))); do
    head -n "$n" "$INSTALLER" >"$WORK/truncated.sh"
    out="$(env -i PATH=/usr/bin:/bin HOME="$TRUNC_HOME" bash "$WORK/truncated.sh" 2>/dev/null </dev/null || true)"
    if [ -n "$out" ] || [ -n "$(ls -A "$TRUNC_HOME")" ]; then trunc_ok=false; echo "    cut at line $n had effects"; fi
done
check "every truncated prefix is inert" '$trunc_ok'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
