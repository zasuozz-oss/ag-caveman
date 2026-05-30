#!/usr/bin/env bash
#
# caveman new-machine setup — Claude Code + Codex CLI + Google Antigravity
#
# Installs the caveman skill/plugin via the official installer, then writes the
# caveman activation instruction (from ./caveman-rule.md) straight into each
# agent's GLOBAL rule file so the mode is always-on (no per-session /caveman).
#
# Works on macOS / Linux and on Windows via Git Bash (or WSL).
#
# Usage:
#   bash setup.sh              # full install + global rule injection
#   bash setup.sh --rules-only # only (re)write the global rule blocks
#   bash setup.sh --no-rules   # only run installers, skip rule injection
#   bash setup.sh --dry-run    # print every action, change nothing
#
set -u

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPO="JuliusBrussee/caveman"
CMD_TIMEOUT="${CAVEMAN_TIMEOUT:-300}"   # seconds, per install command

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RULE_FILE="$SCRIPT_DIR/caveman-rule.md"  # single source of the instruction

DRY_RUN=0
DO_INSTALL=1
DO_RULES=1
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=1 ;;
    --rules-only) DO_INSTALL=0 ;;
    --no-rules)   DO_RULES=0 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Platform detection + paths
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux)  OS=linux ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) OS=unknown ;;
esac

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="$HOME/.codex"
GEMINI_DIR="$HOME/.gemini/config"        # Antigravity config home

CLAUDE_RULE="$CLAUDE_DIR/CLAUDE.md"      # Claude Code global rule
CODEX_RULE="$CODEX_DIR/AGENTS.md"        # Codex CLI global rule
GEMINI_RULE="$GEMINI_DIR/GEMINI.md"      # Antigravity / Gemini global rule
GEMINI_SKILLS="$GEMINI_DIR/skills"

MARK_BEGIN="<!-- BEGIN CAVEMAN (managed by ag-caveman/setup.sh) -->"
MARK_END="<!-- END CAVEMAN -->"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;33m[caveman]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;31m[caveman] WARN:\033[0m %s\n' "$*" >&2; }

# run a command with a finite timeout; never block forever
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "DRY: $*"; return 0; fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CMD_TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CMD_TIMEOUT" "$@"
  else
    "$@"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Inject (or replace) the caveman block in a rule file, idempotently.
# Body is read from $RULE_FILE.
inject_rule() {
  local file="$1" label="$2"
  local dir; dir="$(dirname "$file")"

  if [ ! -f "$RULE_FILE" ]; then
    warn "rule source missing: $RULE_FILE — skipping $label"; return 1
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: inject $RULE_FILE -> $file ($label)"; return 0
  fi

  mkdir -p "$dir"
  [ -f "$file" ] || : > "$file"

  local block tmp
  block="$(printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$(cat "$RULE_FILE")" "$MARK_END")"
  tmp="$(mktemp)"

  if grep -qF "$MARK_BEGIN" "$file"; then
    # replace existing managed block
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v repl="$block" '
      $0==b {print repl; skip=1; next}
      $0==e {skip=0; next}
      skip!=1 {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    log "updated caveman block -> $file ($label)"
  else
    { [ -s "$file" ] && printf '\n'; printf '%s\n' "$block"; } >> "$file"
    rm -f "$tmp"
    log "added caveman block -> $file ($label)"
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — install caveman for each agent (official installer)
# ---------------------------------------------------------------------------
install_caveman() {
  log "OS=$OS  installing caveman via official installer ($REPO)"

  if ! have npx && ! have node; then
    warn "node/npx not found. Install Node.js first (https://nodejs.org). Skipping installers."
    return 1
  fi

  # Claude Code: plugin + hooks + statusline
  if [ "$OS" = windows ]; then
    log "Claude: install.ps1 via PowerShell"
    run powershell.exe -NoProfile -Command \
      "irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex" \
      || warn "Claude installer failed (continuing)"
  else
    log "Claude: install.sh via curl|bash"
    if have curl; then
      run bash -c "curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash" \
        || warn "Claude installer failed (continuing)"
    else
      warn "curl missing; falling back to npx for Claude"
      run npx -y "github:$REPO" -- --only claude --with-hooks \
        || warn "Claude npx installer failed (continuing)"
    fi
  fi

  # Codex CLI: skill via npx-skills
  log "Codex: npx skills add $REPO -a codex"
  run npx -y skills add "$REPO" -a codex || warn "Codex installer failed (continuing)"

  # Google Antigravity: soft-probe agent, force with --only
  log "Antigravity: npx ... --only antigravity"
  run npx -y "github:$REPO" -- --only antigravity || warn "Antigravity installer failed (continuing)"

  # Antigravity may drop skills project-locally (./.agents/skills); make sure
  # they also live in the Gemini config skills dir, then clean project junk.
  if [ -d "./.agents/skills" ] && [ ! -d "$GEMINI_SKILLS/caveman" ]; then
    log "copying antigravity skills -> $GEMINI_SKILLS"
    mkdir -p "$GEMINI_SKILLS"
    cp -R ./.agents/skills/* "$GEMINI_SKILLS"/ 2>/dev/null || true
  fi
  [ -d "./.agents" ] && rm -rf "./.agents" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 2 — write the global rule blocks
# ---------------------------------------------------------------------------
inject_all_rules() {
  log "injecting caveman instruction into global rules (source: $RULE_FILE)"
  inject_rule "$CLAUDE_RULE" "Claude Code"
  inject_rule "$CODEX_RULE"  "Codex CLI"
  inject_rule "$GEMINI_RULE" "Antigravity / Gemini"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
[ "$DO_INSTALL" = 1 ] && install_caveman
[ "$DO_RULES"   = 1 ] && inject_all_rules

log "done."
log "Claude:      $CLAUDE_RULE"
log "Codex:       $CODEX_RULE"
log "Antigravity: $GEMINI_RULE  (skills: $GEMINI_SKILLS)"
log "Verify:      npx -y github:$REPO -- --list"
