#!/usr/bin/env bash
# Foreman Intelligence for Claude: one-command macOS installer.
#
#   curl -fsSL https://github.com/JonathanBWM/foreman-intelligence-claude/releases/latest/download/install.sh | bash
#
# Connects Claude Code and/or Claude Desktop to Foreman Intelligence (Looker)
# through Google's MCP Toolbox:
#   1. downloads a pinned, sha256-verified toolbox binary (no Homebrew needed)
#   2. asks for the user's Looker API key and checks it against Looker
#   3. keeps the secret in the macOS Keychain, never in a config file
#   4. registers one launcher with every Claude app it finds
#   5. proves the connection with a real MCP handshake
#
# Re-running is safe and is the repair path. `--uninstall` removes everything.
# Must stay compatible with macOS's /bin/bash 3.2: no associative arrays,
# no ${var,,}, no mapfile, and no empty-array expansion under `set -u`.
#
# Everything runs inside main(), called on the last line, so a download cut
# off mid-stream by `curl | bash` executes nothing.

set -euo pipefail

FI_VERSION="0.1.1"

TOOLBOX_VERSION="1.13.1"
# Published by Google in the v1.13.1 release notes (googleapis/mcp-toolbox).
TOOLBOX_SHA256_ARM64="fb14fd0692c777d14e45fbebeebd7907564a0e3a1942c55a8829cfd9423f012b"
TOOLBOX_SHA256_AMD64="b26129f5773312d071fc28b060ca203843798caa5f82d2a123914907572dfde6"

SERVER_NAME="foreman-intelligence"
KEYCHAIN_SERVICE="foreman-intelligence-looker"
KEYCHAIN_ACCOUNT="looker-api-secret"
# Entry names the earlier manual setup guide told people to create.
LEGACY_SERVER_NAMES="looker-toolbox looker"

# Overridable for testing and for a future move to an OBM domain.
FI_BASE_URL="${FI_BASE_URL:-https://intelligence.foreman.mn}"
FI_HOME="${FI_HOME:-$HOME/.foreman-intelligence}"
FI_CLAUDE_DIR="${FI_CLAUDE_DIR:-$HOME/.claude}"
FI_DESKTOP_CONFIG="${FI_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"
FI_KEYCHAIN="${FI_KEYCHAIN:-}"   # empty = the user's default (login) keychain
FI_TOOLBOX_URL="${FI_TOOLBOX_URL:-}"
FI_TOOLBOX_SHA256="${FI_TOOLBOX_SHA256:-}"
FI_CLAUDE_BIN="${FI_CLAUDE_BIN:-}"

SECURITY_BIN="/usr/bin/security"
LAUNCHER=""
LOG_FILE=""
TMP_DIR=""
TARGET="auto"
ASSUME_YES=false
RECONFIGURE=false
INSTALL_SKILL=true
DO_UNINSTALL=false
WANT_CODE=false
WANT_DESKTOP=false
CLAUDE_BIN=""
CLIENT_ID=""
CLIENT_SECRET=""
STTY_SAVED=""

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_NC=$'\033[0m'
else
    C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_NC=""
fi

log()         { printf '%s→%s %s\n' "$C_CYAN" "$C_NC" "$1"; }
log_success() { printf '%s✓%s %s\n' "$C_GREEN" "$C_NC" "$1"; }
log_warn()    { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_NC" "$1"; }
log_error()   { printf '%s✗%s %s\n' "$C_RED" "$C_NC" "$1" >&2; }
step()        { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_NC"; }

fail() {
    log_error "$1"
    if [ -n "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        printf '%s  Details: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_NC" >&2
    fi
    printf '%s  Running this installer again is safe once the problem is fixed.%s\n' "$C_DIM" "$C_NC" >&2
    exit 1
}

# Appends a timestamped line to the install log (never secrets).
note() { [ -n "$LOG_FILE" ] && printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >>"$LOG_FILE"; return 0; }

cleanup() {
    if [ -n "$STTY_SAVED" ]; then stty "$STTY_SAVED" </dev/tty 2>/dev/null || true; fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}

usage() {
    cat <<EOF
Foreman Intelligence for Claude installer v$FI_VERSION

Usage: install.sh [options]

  --target auto|code|desktop|both   Which Claude apps to connect (default: auto,
                                    meaning every Claude app found on this Mac)
  --reconfigure                     Enter a new Looker API key even if one is saved
  --no-skill                        Don't install the Foreman Intelligence skill
                                    for Claude Code
  --yes, -y                         Don't ask questions. A new install then needs
                                    FI_LOOKER_CLIENT_ID and FI_LOOKER_CLIENT_SECRET
                                    in the environment
  --uninstall                       Remove everything this installer added
  --version                         Print the installer version
  --help, -h                        Show this help

Piping from curl? Pass options after "bash -s --", for example:
  curl -fsSL <url>/install.sh | bash -s -- --reconfigure
EOF
}

# ---------------------------------------------------------------- prompts

has_tty() { ( : </dev/tty ) 2>/dev/null; }

# ask VAR "Prompt" -- reads a visible answer from the terminal into VAR.
ask() {
    local __answer=""
    printf '%s' "$2" >/dev/tty
    IFS= read -r __answer </dev/tty || true
    printf -v "$1" '%s' "$__answer"
}

# ask_secret VAR "Prompt" -- like ask, without echoing what is typed.
ask_secret() {
    local __answer=""
    printf '%s' "$2" >/dev/tty
    STTY_SAVED="$(stty -g </dev/tty 2>/dev/null || true)"
    stty -echo </dev/tty 2>/dev/null || true
    IFS= read -r __answer </dev/tty || true
    if [ -n "$STTY_SAVED" ]; then stty "$STTY_SAVED" </dev/tty 2>/dev/null || true; fi
    STTY_SAVED=""
    printf '\n' >/dev/tty
    printf -v "$1" '%s' "$__answer"
}

# confirm "Question" default(Y|N) -- true for yes. --yes answers the default.
confirm() {
    local reply="" hint="[Y/n]"
    [ "$2" = "N" ] && hint="[y/N]"
    if [ "$ASSUME_YES" = true ] || ! has_tty; then
        [ "$2" = "Y" ]
        return
    fi
    ask reply "$1 $hint "
    case "$reply" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        *) [ "$2" = "Y" ] ;;
    esac
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------- helpers

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

urlencode() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out="$out$c" ;;
            *) out="$out$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

keychain_args() { [ -n "$FI_KEYCHAIN" ] && printf '%s' "$FI_KEYCHAIN"; return 0; }

keychain_read() {
    if [ -n "$FI_KEYCHAIN" ]; then
        "$SECURITY_BIN" find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$FI_KEYCHAIN" 2>/dev/null
    else
        "$SECURITY_BIN" find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null
    fi
}

# Writes through `security -i` on stdin, hex-encoded, so the secret never
# appears in a process list and needs no quoting.
keychain_write() {
    local hex
    hex="$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"
    printf 'add-generic-password -U -s %s -a %s -l %s -X %s %s\n' \
        "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" "Foreman-Intelligence-Looker-API" "$hex" "$(keychain_args)" \
        | "$SECURITY_BIN" -i >>"$LOG_FILE" 2>&1
}

keychain_delete() {
    if [ -n "$FI_KEYCHAIN" ]; then
        "$SECURITY_BIN" delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" "$FI_KEYCHAIN" >/dev/null 2>&1
    else
        "$SECURITY_BIN" delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1
    fi
}

find_claude_code() {
    local c
    if [ -n "$FI_CLAUDE_BIN" ]; then
        [ -x "$FI_CLAUDE_BIN" ] && { printf '%s' "$FI_CLAUDE_BIN"; return 0; }
        return 1
    fi
    c="$(command -v claude 2>/dev/null || true)"
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
    for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

claude_desktop_present() {
    [ -d "/Applications/Claude.app" ] || [ -d "$HOME/Applications/Claude.app" ] \
        || [ -d "$(dirname "$FI_DESKTOP_CONFIG")" ]
}

# Runs the Claude Desktop config editor (JavaScript for Automation, built into
# macOS, so no jq or python is needed). Modes: add | remove | legacy.
# legacy also reads ~/.claude.json, whose top-level mcpServers is Claude Code's
# user scope.
desktop_config() {
    local mode="$1" path="${2:-$FI_DESKTOP_CONFIG}" js="$TMP_DIR/desktop-config.js"
    cat >"$js" <<'JXA'
ObjC.import('Foundation');
function readText(p) {
  var fm = $.NSFileManager.defaultManager;
  if (!fm.fileExistsAtPath(p)) return null;
  var s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null);
  return s.isNil() ? null : ObjC.unwrap(s);
}
function writeText(p, text) {
  var dir = $(p).stringByDeletingLastPathComponent;
  $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  if (!$(text).writeToFileAtomicallyEncodingError(p, true, $.NSUTF8StringEncoding, null)) throw new Error('cannot write ' + p);
}
function run(argv) {
  var mode = argv[0], path = argv[1], name = argv[2], command = argv[3], legacy = (argv[4] || '').split(' ');
  var text = readText(path), config = {};
  if (text !== null && text.trim() !== '') {
    try { config = JSON.parse(text); } catch (e) { return 'INVALID_JSON'; }
    if (typeof config !== 'object' || config === null || Array.isArray(config)) return 'INVALID_JSON';
  }
  var servers = config.mcpServers;
  if (servers !== undefined && (typeof servers !== 'object' || servers === null || Array.isArray(servers))) return 'INVALID_JSON';
  if (mode === 'legacy') {
    var found = [];
    for (var i = 0; i < legacy.length; i++) {
      var s = servers && servers[legacy[i]];
      if (s && /toolbox/.test(JSON.stringify(s))) found.push(legacy[i]);
    }
    return 'LEGACY:' + found.join(' ');
  }
  if (mode === 'add') {
    config.mcpServers = servers || {};
    config.mcpServers[name] = { command: command, args: [] };
  } else if (mode === 'remove') {
    if (!servers || !(name in servers)) return 'UNCHANGED';
    delete servers[name];
  }
  writeText(path, JSON.stringify(config, null, 2) + '\n');
  return 'OK';
}
JXA
    osascript -l JavaScript "$js" "$mode" "$path" "$SERVER_NAME" "$LAUNCHER" "$LEGACY_SERVER_NAMES" 2>>"$LOG_FILE"
}

# ---------------------------------------------------------------- stages

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --target) [ $# -ge 2 ] || { usage; exit 2; }; TARGET="$2"; shift 2 ;;
            --target=*) TARGET="${1#--target=}"; shift ;;
            --reconfigure) RECONFIGURE=true; shift ;;
            --no-skill) INSTALL_SKILL=false; shift ;;
            --yes|-y) ASSUME_YES=true; shift ;;
            --uninstall) DO_UNINSTALL=true; shift ;;
            --version) echo "$FI_VERSION"; exit 0 ;;
            --help|-h) usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
        esac
    done
    case "$TARGET" in auto|code|desktop|both) ;; *) log_error "--target must be auto, code, desktop or both"; exit 2 ;; esac
}

check_platform() {
    [ "$(uname -s)" = "Darwin" ] || fail "This installer is for macOS. Windows support is coming; for now follow the manual guide."
    local missing=""
    for cmd in curl shasum osascript od stty; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -x "$SECURITY_BIN" ] || missing="$missing security"
    [ -z "$missing" ] || fail "Missing system tools:$missing"
}

prepare_dirs() {
    mkdir -p "$FI_HOME/bin"
    chmod 700 "$FI_HOME"
    LOG_FILE="$FI_HOME/install.log"
    : >"$LOG_FILE"
    chmod 600 "$LOG_FILE"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/foreman-intelligence.XXXXXX")"
    LAUNCHER="$FI_HOME/bin/foreman-intelligence-mcp"
    note "installer $FI_VERSION, toolbox $TOOLBOX_VERSION, base $FI_BASE_URL"
}

choose_targets() {
    step "Finding Claude"
    if CLAUDE_BIN="$(find_claude_code)"; then
        log_success "Claude Code found at $CLAUDE_BIN"
    else
        CLAUDE_BIN=""
    fi
    local have_desktop=false
    if claude_desktop_present; then
        have_desktop=true
        log_success "Claude Desktop found"
    fi

    case "$TARGET" in
        code) WANT_CODE=true ;;
        desktop) WANT_DESKTOP=true ;;
        both) WANT_CODE=true; WANT_DESKTOP=true ;;
        auto)
            [ -n "$CLAUDE_BIN" ] && WANT_CODE=true
            [ "$have_desktop" = true ] && WANT_DESKTOP=true
            ;;
    esac

    if [ "$WANT_CODE" = false ] && [ "$WANT_DESKTOP" = false ]; then
        log_warn "No Claude app found on this Mac."
        printf '  Claude Desktop (chat app): download from https://claude.ai/download, then run this again.\n'
        printf '  Claude Code (terminal): can be installed now.\n'
        if confirm "Install Claude Code now?" Y; then
            WANT_CODE=true
        else
            fail "Install Claude Desktop or Claude Code first, then run this installer again."
        fi
    fi

    if [ "$WANT_CODE" = true ] && [ -z "$CLAUDE_BIN" ]; then
        log "Installing Claude Code with Anthropic's official installer"
        curl -fsSL https://claude.ai/install.sh | bash >>"$LOG_FILE" 2>&1 \
            || fail "Claude Code install failed. Try: curl -fsSL https://claude.ai/install.sh | bash"
        CLAUDE_BIN="$(find_claude_code)" || fail "Claude Code installed but the claude command wasn't found."
        log_success "Claude Code installed"
    fi
}

toolbox_target() {
    local arch
    arch="$(uname -m)"
    # An x86_64 shell under Rosetta on Apple Silicon should still get arm64.
    if [ "$arch" = "x86_64" ] && [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
        arch="arm64"
    fi
    case "$arch" in
        arm64) printf 'arm64 %s' "$TOOLBOX_SHA256_ARM64" ;;
        x86_64) printf 'amd64 %s' "$TOOLBOX_SHA256_AMD64" ;;
        *) return 1 ;;
    esac
}

install_toolbox() {
    step "Installing the Looker connector (MCP Toolbox $TOOLBOX_VERSION)"
    local target arch sha url dest="$FI_HOME/bin/toolbox"
    target="$(toolbox_target)" || fail "Unsupported Mac processor: $(uname -m)"
    arch="${target% *}"
    sha="${target#* }"
    url="https://storage.googleapis.com/mcp-toolbox-for-databases/v$TOOLBOX_VERSION/darwin/$arch/toolbox"
    if [ -n "$FI_TOOLBOX_URL" ]; then url="$FI_TOOLBOX_URL"; sha="$FI_TOOLBOX_SHA256"; fi

    if [ -x "$dest" ] && [ "$(sha256_of "$dest")" = "$sha" ]; then
        log_success "Already installed and verified"
        return
    fi
    log "Downloading for $arch"
    note "toolbox url $url"
    curl -fsSL --retry 3 -o "$TMP_DIR/toolbox" "$url" >>"$LOG_FILE" 2>&1 \
        || fail "Couldn't download the connector. Check your internet connection."
    local got
    got="$(sha256_of "$TMP_DIR/toolbox")"
    if [ "$got" != "$sha" ]; then
        note "sha256 expected $sha got $got"
        fail "The downloaded connector failed its checksum, so it was not installed."
    fi
    chmod 755 "$TMP_DIR/toolbox"
    mv -f "$TMP_DIR/toolbox" "$dest"
    log_success "Installed and checksum verified"
}

# Sets VALIDATION_ERROR on failure.
validate_credentials() {
    local id="$1" secret="$2" code body="$TMP_DIR/login.json"
    VALIDATION_ERROR=""
    code="$(printf 'client_id=%s&client_secret=%s' "$(urlencode "$id")" "$(urlencode "$secret")" \
        | curl -sS -o "$body" -w '%{http_code}' --max-time 30 -X POST \
            -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- \
            "$FI_BASE_URL/api/4.0/login" 2>>"$LOG_FILE")" || code="000"
    note "credential check http $code"
    case "$code" in
        200)
            if grep -q '"access_token"' "$body"; then rm -f "$body"; return 0; fi
            VALIDATION_ERROR="Foreman Intelligence answered, but not with a login token."
            ;;
        400|401|403|404) VALIDATION_ERROR="Foreman Intelligence didn't accept that Client ID and Secret." ;;
        000) VALIDATION_ERROR="Couldn't reach $FI_BASE_URL. Check your internet or VPN connection." ;;
        *) VALIDATION_ERROR="Foreman Intelligence returned HTTP $code." ;;
    esac
    rm -f "$body"
    return 1
}

saved_client_id() {
    [ -f "$FI_HOME/config.env" ] || return 1
    local line
    line="$(grep '^LOOKER_CLIENT_ID=' "$FI_HOME/config.env" | head -1)" || return 1
    line="${line#LOOKER_CLIENT_ID=}"
    line="${line#\'}"; line="${line%\'}"
    [ -n "$line" ] && printf '%s' "$line"
}

# Echoes the authenticated user's numeric Looker id, or nothing on failure.
# Used to deep-link to that user's own API-key admin page, which is keyed by id.
looker_user_id() {
    local id="$1" secret="$2" tok
    tok="$(printf 'client_id=%s&client_secret=%s' "$(urlencode "$id")" "$(urlencode "$secret")" \
        | curl -sS --max-time 20 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
            --data-binary @- "$FI_BASE_URL/api/4.0/login" 2>/dev/null \
        | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')"
    [ -n "$tok" ] || return 1
    curl -sS --max-time 20 -H "Authorization: token $tok" "$FI_BASE_URL/api/4.0/user?fields=id" 2>/dev/null \
        | sed -n 's/.*"id" *: *\([0-9][0-9]*\).*/\1/p' | head -1
}

# The user's own API-key page when we can resolve their id, else the
# self-service account page (no id, works for everyone).
apikey_url() {
    local id="$1" secret="$2" uid
    uid="$(looker_user_id "$id" "$secret" 2>/dev/null || true)"
    if [ -n "$uid" ]; then printf '%s/admin/next/users/api3_key/%s' "$FI_BASE_URL" "$uid"
    else printf '%s/account' "$FI_BASE_URL"; fi
}

collect_credentials() {
    step "Connecting your Foreman Intelligence account"

    local saved_id saved_secret
    if [ "$RECONFIGURE" = false ] && saved_id="$(saved_client_id)" && saved_secret="$(keychain_read)" && [ -n "$saved_secret" ]; then
        log "Checking your saved API key"
        if validate_credentials "$saved_id" "$saved_secret"; then
            CLIENT_ID="$saved_id"; CLIENT_SECRET="$saved_secret"
            log_success "Saved API key still works"
            return
        fi
        log_warn "$VALIDATION_ERROR Let's set up a new key."
    fi

    if [ -n "${FI_LOOKER_CLIENT_ID:-}" ] && [ -n "${FI_LOOKER_CLIENT_SECRET:-}" ]; then
        log "Checking the API key from the environment"
        validate_credentials "$FI_LOOKER_CLIENT_ID" "$FI_LOOKER_CLIENT_SECRET" || fail "$VALIDATION_ERROR"
        CLIENT_ID="$FI_LOOKER_CLIENT_ID"; CLIENT_SECRET="$FI_LOOKER_CLIENT_SECRET"
        log_success "API key accepted"
        return
    fi

    if [ "$ASSUME_YES" = true ] || ! has_tty; then
        fail "No terminal to ask for your API key. Set FI_LOOKER_CLIENT_ID and FI_LOOKER_CLIENT_SECRET, or run without --yes."
    fi

    cat >/dev/tty <<EOF

  Claude needs a Foreman Intelligence API key tied to your own account.
  It only sees what you can already see.

  ${C_BOLD}In the page that opens:${C_NC}
    1. Sign in if asked
    2. Find the API keys / Authentication section (click ${C_BOLD}Manage${C_NC} if shown)
    3. ${C_BOLD}Create a new API key${C_NC}, then copy the Client ID and Client Secret

  No API-key option? Your account can't create API keys yet. Ask your
  Foreman Intelligence admin, then run this installer again.

EOF
    # Deep-link to this user's own API-key page when a prior key can resolve
    # their id; otherwise the self-service account page.
    local open_url="$FI_BASE_URL/account" prev_id prev_secret
    prev_id="$(saved_client_id 2>/dev/null || true)"
    prev_secret="$(keychain_read 2>/dev/null || true)"
    if [ -n "$prev_id" ] && [ -n "$prev_secret" ]; then open_url="$(apikey_url "$prev_id" "$prev_secret")"; fi
    # shellcheck disable=SC2034 # assigned by ask via printf -v
    local ignored=""
    ask ignored "  Press Enter to open Foreman Intelligence in your browser... "
    open "$open_url" >/dev/null 2>&1 || log_warn "Couldn't open a browser. Go to $open_url"

    local attempt=1 id secret
    while [ $attempt -le 3 ]; do
        printf '\n' >/dev/tty
        ask id "  Client ID: "
        ask_secret secret "  Client Secret (hidden as you type or paste): "
        id="$(trim "$id")"; secret="$(trim "$secret")"
        if [ -z "$id" ] || [ -z "$secret" ]; then
            log_warn "Both the Client ID and the Client Secret are needed."
        else
            log "Checking with Foreman Intelligence"
            if validate_credentials "$id" "$secret"; then
                CLIENT_ID="$id"; CLIENT_SECRET="$secret"
                log_success "API key accepted"
                return
            fi
            log_warn "$VALIDATION_ERROR"
        fi
        attempt=$((attempt + 1))
    done
    fail "The API key wasn't accepted after 3 tries. Check the Client ID and Secret in Account Settings, then run this again."
}

save_configuration() {
    step "Saving your settings"
    keychain_write "$CLIENT_SECRET" || fail "Couldn't save the secret to your Keychain."
    log_success "Client Secret saved in your macOS Keychain"

    local cfg="$FI_HOME/config.env"
    {
        printf '# Foreman Intelligence for Claude. The Client Secret lives in the macOS Keychain\n'
        printf '# (service %s), not here. Re-run the installer with --reconfigure to change it.\n' "$KEYCHAIN_SERVICE"
        printf 'LOOKER_BASE_URL=%q\n' "$FI_BASE_URL"
        printf 'LOOKER_CLIENT_ID=%q\n' "$CLIENT_ID"
        printf 'LOOKER_VERIFY_SSL=true\n'
    } >"$cfg"
    chmod 600 "$cfg"

    # The launcher is what every Claude app runs. Claude Desktop starts it with
    # a bare environment, so every path is absolute. stdout is the MCP channel:
    # errors go to stderr only. Single-quoted $ below is meant for the launcher.
    # shellcheck disable=SC2016
    {
        printf '#!/bin/bash\n'
        printf '# Generated by the Foreman Intelligence installer v%s. Re-run the installer to change it.\n' "$FI_VERSION"
        printf 'set -euo pipefail\n'
        printf 'FI_HOME=%q\n' "$FI_HOME"
        printf 'FI_KEYCHAIN=%q\n' "$FI_KEYCHAIN"
        printf '. "$FI_HOME/config.env"\n'
        printf 'if [ -n "$FI_KEYCHAIN" ]; then\n'
        printf '    LOOKER_CLIENT_SECRET="$(%s find-generic-password -s %q -a %q -w "$FI_KEYCHAIN" 2>/dev/null)" || LOOKER_CLIENT_SECRET=""\n' "$SECURITY_BIN" "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT"
        printf 'else\n'
        printf '    LOOKER_CLIENT_SECRET="$(%s find-generic-password -s %q -a %q -w 2>/dev/null)" || LOOKER_CLIENT_SECRET=""\n' "$SECURITY_BIN" "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT"
        printf 'fi\n'
        printf 'if [ -z "$LOOKER_CLIENT_SECRET" ]; then\n'
        printf '    echo "Foreman Intelligence: no API key in the Keychain. Re-run the installer with --reconfigure." >&2\n'
        printf '    exit 1\n'
        printf 'fi\n'
        printf 'export LOOKER_BASE_URL LOOKER_CLIENT_ID LOOKER_CLIENT_SECRET LOOKER_VERIFY_SSL\n'
        printf 'exec "$FI_HOME/bin/toolbox" --stdio --prebuilt looker "$@"\n'
    } >"$LAUNCHER"
    chmod 700 "$LAUNCHER"
    log_success "Settings saved in $FI_HOME"
}

# Speaks MCP to the launcher exactly as Claude will, through a FIFO so stdin
# stays open until the answer arrives.
smoke_test() {
    step "Testing the connection"
    local fifo="$TMP_DIR/mcp.in" out="$TMP_DIR/mcp.out" err="$TMP_DIR/mcp.err" pid i tools
    mkfifo "$fifo"
    "$LAUNCHER" <"$fifo" >"$out" 2>"$err" &
    pid=$!
    exec 3>"$fifo"
    printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"foreman-intelligence-installer","version":"'"$FI_VERSION"'"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' >&3 || true
    for (( i = 0; i < 60; i++ )); do
        grep -Eq '"id": ?2[,}]' "$out" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    exec 3>&-
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sed 's/^/  toolbox: /' "$err" >>"$LOG_FILE" 2>/dev/null || true

    tools="$(count_tools "$out")"
    if [ -z "$tools" ] || [ "$tools" -eq 0 ]; then
        fail "The connector didn't start correctly. The last lines of its output are in the log."
    fi
    log_success "Connected: Claude will have $tools Foreman Intelligence tools"
}

# Prints how many tools the tools/list response (id 2) in file $1 lists, or 0.
count_tools() {
    osascript -l JavaScript - "$1" 2>/dev/null <<'JXA' || echo 0
ObjC.import('Foundation');
function run(argv) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (s.isNil()) return '0';
  var lines = ObjC.unwrap(s).split('\n');
  for (var i = 0; i < lines.length; i++) {
    try {
      var m = JSON.parse(lines[i]);
      if (m.id === 2 && m.result && m.result.tools) return String(m.result.tools.length);
    } catch (e) {}
  }
  return '0';
}
JXA
}

register_claude_code() {
    [ "$WANT_CODE" = true ] || return 0
    step "Connecting Claude Code"
    "$CLAUDE_BIN" mcp remove "$SERVER_NAME" --scope user >>"$LOG_FILE" 2>&1 || true
    "$CLAUDE_BIN" mcp add "$SERVER_NAME" --scope user -- "$LAUNCHER" >>"$LOG_FILE" 2>&1 \
        || fail "Couldn't register with Claude Code."
    log_success "Added \"$SERVER_NAME\" for every Claude Code project"

    local legacy name
    legacy="$(desktop_config legacy "$HOME/.claude.json" 2>/dev/null || true)"
    for name in ${legacy#LEGACY:}; do
        log_warn "An older \"$name\" connector from the manual setup is also configured."
        printf '  Claude would see two copies of every tool. Remove the old one with:\n'
        printf '    claude mcp remove %s --scope user\n' "$name"
    done

    if [ "$INSTALL_SKILL" = true ]; then
        install_skill
    fi
}

install_skill() {
    local dir="$FI_CLAUDE_DIR/skills/foreman-intelligence"
    mkdir -p "$dir"
    cat >"$dir/SKILL.md" <<'SKILL'
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
SKILL
    log_success "Installed the Foreman Intelligence skill for Claude Code"
}

register_claude_desktop() {
    [ "$WANT_DESKTOP" = true ] || return 0
    step "Connecting Claude Desktop"
    local result
    result="$(desktop_config legacy)" || fail "Couldn't read the Claude Desktop config."
    if [ "$result" = "INVALID_JSON" ]; then
        fail "Claude Desktop's config file isn't valid JSON, so it was left untouched: $FI_DESKTOP_CONFIG"
    fi
    if [ -f "$FI_DESKTOP_CONFIG" ]; then
        cp -p "$FI_DESKTOP_CONFIG" "$FI_DESKTOP_CONFIG.bak-foreman-intelligence"
        note "desktop config backed up"
    fi
    [ "$(desktop_config add)" = "OK" ] || fail "Couldn't update the Claude Desktop config."
    log_success "Added \"$SERVER_NAME\" to Claude Desktop"

    local legacy="${result#LEGACY:}" name
    for name in $legacy; do
        log_warn "An older \"$name\" connector from the manual setup is also in Claude Desktop."
        printf '  Remove it in Settings → Developer → Edit Config so Claude sees one copy of each tool.\n'
    done

    # Never quit someone's app unattended: --yes and no-terminal runs only advise.
    if pgrep -x Claude >/dev/null 2>&1; then
        if [ "$ASSUME_YES" = false ] && has_tty \
            && confirm "Claude Desktop is open. Restart it now to load the connector?" Y; then
            osascript -e 'quit app "Claude"' >/dev/null 2>&1 || true
            for (( i = 0; i < 20; i++ )); do pgrep -x Claude >/dev/null 2>&1 || break; sleep 0.5; done
            open -a Claude >/dev/null 2>&1 || true
            log_success "Claude Desktop restarted"
        else
            log_warn "Fully quit Claude Desktop (⌘Q) and reopen it to load the connector."
        fi
    fi
}

finish() {
    step "Done"
    printf '\n  Foreman Intelligence is connected. Try asking Claude:\n\n'
    printf '    %s"What Explores do I have access to in Foreman Intelligence?"%s\n' "$C_BOLD" "$C_NC"
    printf '    %s"Show uptime by site for the last 30 days, then make it a dashboard."%s\n\n' "$C_BOLD" "$C_NC"
    if [ "$WANT_CODE" = true ]; then
        printf '  Claude Code: start a new session with %sclaude%s (type /mcp to see the connector).\n' "$C_BOLD" "$C_NC"
    fi
    if [ "$WANT_DESKTOP" = true ]; then
        printf '  Claude Desktop: open a new chat.\n'
    fi
    local uid
    uid="$(looker_user_id "$CLIENT_ID" "$CLIENT_SECRET" 2>/dev/null || true)"
    if [ -n "$uid" ]; then
        printf '\n  Manage or rotate this key anytime:\n    %s/admin/next/users/api3_key/%s\n' "$FI_BASE_URL" "$uid"
    fi
    printf '\n  %sSomething off later? Run the same install command again; it repairs itself.%s\n' "$C_DIM" "$C_NC"
    printf '  %sNew API key: add --reconfigure. Remove everything: add --uninstall.%s\n\n' "$C_DIM" "$C_NC"
}

uninstall() {
    step "Removing Foreman Intelligence for Claude"
    if ! confirm "Remove the connector, its saved API key and its settings?" Y; then
        echo "Nothing removed."
        exit 0
    fi
    LAUNCHER="$FI_HOME/bin/foreman-intelligence-mcp"
    LOG_FILE="/dev/null"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/foreman-intelligence.XXXXXX")"

    if CLAUDE_BIN="$(find_claude_code)"; then
        if "$CLAUDE_BIN" mcp remove "$SERVER_NAME" --scope user >/dev/null 2>&1; then
            log_success "Removed from Claude Code"
        fi
    fi
    if [ -f "$FI_DESKTOP_CONFIG" ]; then
        case "$(desktop_config remove)" in
            OK) log_success "Removed from Claude Desktop (restart it to finish)" ;;
            INVALID_JSON) log_warn "Claude Desktop's config isn't valid JSON; remove \"$SERVER_NAME\" by hand." ;;
        esac
    fi
    if [ -f "$FI_CLAUDE_DIR/skills/foreman-intelligence/SKILL.md" ]; then
        rm -rf "$FI_CLAUDE_DIR/skills/foreman-intelligence"
        log_success "Removed the Claude Code skill"
    fi
    if keychain_delete; then log_success "Removed the API key from your Keychain"; fi
    rm -rf "$FI_HOME"
    log_success "Removed $FI_HOME"
    printf '\n  The API key itself still exists in Foreman Intelligence. Delete it in\n'
    printf '  Account Settings → Authentication if you no longer need it.\n\n'
}

main() {
    parse_args "$@"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    printf '\n%sForeman Intelligence for Claude%s  %sinstaller v%s%s\n' "$C_BOLD" "$C_NC" "$C_DIM" "$FI_VERSION" "$C_NC"

    if [ "$DO_UNINSTALL" = true ]; then
        uninstall
        return
    fi

    check_platform
    prepare_dirs
    choose_targets
    install_toolbox
    collect_credentials
    save_configuration
    smoke_test
    register_claude_code
    register_claude_desktop
    finish
}

main "$@"
