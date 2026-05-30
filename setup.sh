#!/usr/bin/env bash
#
# caveman new-machine setup — Claude Code + Codex CLI + Google Antigravity
#
# Installs the caveman skill/plugin via the official installer, then writes the
# caveman activation instruction (from ./CAVEMAN.md) straight into each
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
RULE_SRC="$SCRIPT_DIR/CAVEMAN.md"        # single source of the instruction

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
GEMINI_DIR="$HOME/.gemini"               # Antigravity rule home (AKS.md/GEMINI.md live here)

CLAUDE_RULE="$CLAUDE_DIR/CLAUDE.md"      # Claude Code global rule
CODEX_RULE="$CODEX_DIR/AGENTS.md"        # Codex CLI global rule
GEMINI_RULE="$GEMINI_DIR/GEMINI.md"      # Antigravity / Gemini global rule
GEMINI_SKILLS="$GEMINI_DIR/config/skills"  # installer drops skills here

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

# Copy CAVEMAN.md into an agent's rule dir, then wire a reference into that
# agent's global rule file. The reference (not the body) lives in the rule file,
# wrapped in idempotent markers so re-running replaces it in place — and so any
# OLD full-body block from a previous setup.sh version is migrated to a ref.
#
#   $1 rule_file   global rule file to edit (CLAUDE.md / AGENTS.md / GEMINI.md)
#   $2 copy_dest   where CAVEMAN.md is copied (per-agent dir)
#   $3 ref_line    the reference line written into the rule file
#   $4 label       human label for logs
wire_rule() {
  local file="$1" dest="$2" ref="$3" label="$4"
  local dir; dir="$(dirname "$file")"

  if [ ! -f "$RULE_SRC" ]; then
    warn "rule source missing: $RULE_SRC — skipping $label"; return 1
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: cp $RULE_SRC -> $dest"
    echo "DRY: ensure ref in $file ($label):  $ref"
    return 0
  fi

  # 1. copy the rule file into the agent's dir
  mkdir -p "$(dirname "$dest")"
  cp -f "$RULE_SRC" "$dest"
  log "copied CAVEMAN.md -> $dest"

  # 2. wire the reference into the global rule file
  mkdir -p "$dir"
  [ -f "$file" ] || : > "$file"

  local block tmp
  block="$(printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$ref" "$MARK_END")"
  tmp="$(mktemp)"

  if grep -qF "$MARK_BEGIN" "$file"; then
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v repl="$block" '
      $0==b {print repl; skip=1; next}
      $0==e {skip=0; next}
      skip!=1 {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    log "updated caveman ref -> $file ($label)"
  else
    { [ -s "$file" ] && printf '\n'; printf '%s\n' "$block"; } >> "$file"
    rm -f "$tmp"
    log "added caveman ref -> $file ($label)"
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

  # All three agents go through the SAME official installer (bin/install.js)
  # invoked via npx. We always pass `--only <agent>` and `--non-interactive`
  # so the installer never renders its agent/skill selection TUI — that picker
  # is unusable under Git Bash (mintty): arrow keys / space don't register and
  # the run hangs. `--only` preselects the agent; the installer then drives the
  # inner `skills add` with `--yes --all` itself, so no sub-prompt either.

  # Claude Code: plugin + hooks + statusline
  log "Claude: --only claude --with-hooks (non-interactive)"
  run npx -y "github:$REPO" -- --only claude --with-hooks --non-interactive \
    || warn "Claude installer failed (continuing)"

  # Codex CLI: skill (installer runs `skills add ... --yes --all` internally)
  log "Codex: --only codex (non-interactive)"
  run npx -y "github:$REPO" -- --only codex --non-interactive \
    || warn "Codex installer failed (continuing)"

  # Google Antigravity: soft-probe agent, force with --only
  log "Antigravity: --only antigravity (non-interactive)"
  run npx -y "github:$REPO" -- --only antigravity --non-interactive \
    || warn "Antigravity installer failed (continuing)"

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
  log "wiring CAVEMAN.md into global rules (source: $RULE_SRC)"
  # Claude & Codex: native @import of their own copy.
  wire_rule "$CLAUDE_RULE" "$CLAUDE_DIR/CAVEMAN.md" '@~/.claude/CAVEMAN.md'  "Claude Code"
  wire_rule "$CODEX_RULE"  "$CODEX_DIR/CAVEMAN.md"  '@~/.codex/CAVEMAN.md'   "Codex CLI"
  # Antigravity: no @import — it reads files via view_file(), like ~/.gemini/AKS.md.
  wire_rule "$GEMINI_RULE" "$GEMINI_DIR/CAVEMAN.md" \
    'Before doing anything, you MUST execute: `view_file("~/.gemini/CAVEMAN.md")`' \
    "Antigravity / Gemini"
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
