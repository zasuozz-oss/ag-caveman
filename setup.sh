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
CODEX_SKILLS="$CODEX_DIR/skills"           # Codex reads global skills here
CLAUDE_SKILLS="$CLAUDE_DIR/skills"         # Claude reads global skills here
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"  # Claude Code global settings (env/permissions/hooks/...)
CODEX_CONFIG="$CODEX_DIR/config.toml"      # Codex global config (MCP servers)

MCP_SHRINK_PKG="caveman-shrink"            # npm pkg for the MCP shrink proxy

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

# Snapshot ~/.claude/settings.json before the official installer runs.
# The upstream caveman installer (--with-hooks) rewrites settings.json from a
# template and keeps only a subset of keys, silently dropping anything it does
# not know about (env, permissions.deny/defaultMode, autoCompact*, theme,
# enabledPlugins, hasCompletedOnboarding, skipDangerousModePermissionPrompt,
# and any pre-existing hooks). We snapshot here and merge the dropped keys back
# in restore_claude_settings() after the installer finishes.
SETTINGS_SNAPSHOT=""
snapshot_claude_settings() {
  SETTINGS_SNAPSHOT=""
  [ -f "$CLAUDE_SETTINGS" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: snapshot $CLAUDE_SETTINGS before caveman installer"
    return 0
  fi
  SETTINGS_SNAPSHOT="$(mktemp)"
  cp -f "$CLAUDE_SETTINGS" "$SETTINGS_SNAPSHOT"
  log "snapshotted settings.json (will restore caveman-dropped keys after install)"
}

# Merge the pre-install snapshot back into the post-install settings.json so the
# installer's destructive rewrite cannot lose user config. The installer's own
# additions (caveman hooks, etc.) are preserved; snapshot only FILLS keys the
# installer dropped — it never overwrites what the installer set. Arrays
# (permissions.allow/deny) and hooks are unioned (dedup by command).
restore_claude_settings() {
  [ -n "$SETTINGS_SNAPSHOT" ] || return 0
  [ -f "$SETTINGS_SNAPSHOT" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: merge snapshot back into $CLAUDE_SETTINGS"
    return 0
  fi
  if ! have node; then
    warn "node not found — cannot merge settings.json; snapshot kept at $SETTINGS_SNAPSHOT"
    return 0
  fi
  node - "$CLAUDE_SETTINGS" "$SETTINGS_SNAPSHOT" <<'NODE'
const fs = require('node:fs');
const [newF, oldF] = process.argv.slice(2);
let nw = {}, od = {};
try { nw = JSON.parse(fs.readFileSync(newF, 'utf8')); } catch {}
try { od = JSON.parse(fs.readFileSync(oldF, 'utf8')); } catch { process.exit(0); }

// 1. Restore any top-level key the installer dropped (env, model, theme,
//    autoCompactEnabled, enabledPlugins, hasCompletedOnboarding, ...).
for (const k of Object.keys(od)) {
  if (!(k in nw)) nw[k] = od[k];
}

// 2. env: old fills gaps, never clobber what the installer set.
if (od.env && typeof od.env === 'object') {
  nw.env = { ...od.env, ...(nw.env || {}) };
}

// 3. permissions: union allow/deny arrays; restore defaultMode/other subkeys.
if (od.permissions && typeof od.permissions === 'object') {
  nw.permissions = nw.permissions || {};
  for (const arr of ['allow', 'deny']) {
    const merged = [...new Set([...(nw.permissions[arr] || []), ...(od.permissions[arr] || [])])];
    if (merged.length || arr in nw.permissions || arr in od.permissions) nw.permissions[arr] = merged;
  }
  for (const sk of Object.keys(od.permissions)) {
    if (!(sk in nw.permissions)) nw.permissions[sk] = od.permissions[sk];
  }
}

// 4. hooks: union per event; keep installer's hooks AND the user's old ones,
//    dedup by command string.
if (od.hooks && typeof od.hooks === 'object') {
  nw.hooks = nw.hooks || {};
  for (const [ev, entries] of Object.entries(od.hooks)) {
    if (!Array.isArray(entries)) continue;
    if (!nw.hooks[ev]) { nw.hooks[ev] = entries; continue; }
    const have = new Set(nw.hooks[ev].flatMap((e) => (e.hooks || []).map((h) => h.command)));
    for (const e of entries) {
      const cmds = (e.hooks || []).map((h) => h.command);
      if (!cmds.some((c) => have.has(c))) nw.hooks[ev].push(e);
    }
  }
}

fs.writeFileSync(newF, JSON.stringify(nw, null, 2) + '\n');
NODE
  log "restored caveman-dropped settings.json keys (env/permissions/hooks/...) from snapshot"
  rm -f "$SETTINGS_SNAPSHOT"
  SETTINGS_SNAPSHOT=""
}

# Snapshot ~/.codex/config.toml before the official installer runs. config.toml
# holds MCP servers, per-project trust_level, plugin/marketplace state and TUI
# prefs — none of which the caveman installer manages. The same defensive guard
# we use for Claude: snapshot here, then in restore_codex_config() fill back any
# table or top-level key the installer dropped. (Codex itself reorders the file
# on every run, which is fine — the merge is keyed on table headers, not order.)
CODEX_SNAPSHOT=""
snapshot_codex_config() {
  CODEX_SNAPSHOT=""
  [ -f "$CODEX_CONFIG" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: snapshot $CODEX_CONFIG before caveman installer"
    return 0
  fi
  CODEX_SNAPSHOT="$(mktemp)"
  cp -f "$CODEX_CONFIG" "$CODEX_SNAPSHOT"
  log "snapshotted config.toml (will restore installer-dropped tables/keys after install)"
}

# Merge the pre-install snapshot back into config.toml: any TOML table or
# top-level key present in the snapshot but missing afterwards is appended. The
# installer's additions/reordering are preserved — we only FILL gaps, never
# overwrite. TOML tables are order-independent, so appending a dropped block at
# the end is valid.
restore_codex_config() {
  [ -n "$CODEX_SNAPSHOT" ] || return 0
  [ -f "$CODEX_SNAPSHOT" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: merge snapshot back into $CODEX_CONFIG"
    return 0
  fi
  if ! have node; then
    warn "node not found — cannot merge config.toml; snapshot kept at $CODEX_SNAPSHOT"
    return 0
  fi
  node - "$CODEX_CONFIG" "$CODEX_SNAPSHOT" <<'NODE'
const fs = require('node:fs');
const [newF, oldF] = process.argv.slice(2);
let newText, oldText;
try { newText = fs.readFileSync(newF, 'utf8'); } catch { process.exit(0); }
try { oldText = fs.readFileSync(oldF, 'utf8'); } catch { process.exit(0); }

// Split a TOML document into a preamble (top-level key=val lines before the
// first table header) and an ordered list of { header, text } blocks. A header
// is a line like `[table]` or `[[array]]`; identity is the trimmed header text.
function parse(text) {
  const lines = text.split('\n');
  const preamble = [];
  const blocks = [];
  let cur = null;
  for (const line of lines) {
    if (/^\s*\[.*\]\s*$/.test(line)) {
      if (cur) blocks.push(cur);
      cur = { header: line.trim(), lines: [line] };
    } else if (cur) {
      cur.lines.push(line);
    } else {
      preamble.push(line);
    }
  }
  if (cur) blocks.push(cur);
  return { preamble, blocks };
}

// top-level bare key from a `key = value` line (skip comments/blanks)
function bareKey(line) {
  const m = line.match(/^\s*([A-Za-z0-9_."'-]+)\s*=/);
  return m ? m[1] : null;
}

const nw = parse(newText);
const od = parse(oldText);

// 1. Tables present in old but missing in new → append them verbatim.
const haveHeaders = new Set(nw.blocks.map((b) => b.header));
const appended = [];
for (const b of od.blocks) {
  if (!haveHeaders.has(b.header)) appended.push(b);
}

// 2. Top-level keys present in old preamble but missing in new preamble.
const newKeys = new Set(nw.preamble.map(bareKey).filter(Boolean));
const restoredKeys = od.preamble.filter((l) => {
  const k = bareKey(l);
  return k && !newKeys.has(k);
});

if (appended.length === 0 && restoredKeys.length === 0) process.exit(0);

let out = newText.replace(/\s*$/, '\n');
if (restoredKeys.length) {
  // Prepend restored bare keys ahead of the first table so they stay top-level.
  const idx = out.search(/^\s*\[.*\]\s*$/m);
  const inject = restoredKeys.join('\n') + '\n';
  out = idx === -1 ? out + inject : out.slice(0, idx) + inject + out.slice(idx);
}
for (const b of appended) {
  out = out.replace(/\s*$/, '\n') + '\n' + b.lines.join('\n').replace(/\s*$/, '') + '\n';
}
fs.writeFileSync(newF, out);
NODE
  log "restored installer-dropped config.toml tables/keys from snapshot"
  rm -f "$CODEX_SNAPSHOT"
  CODEX_SNAPSHOT=""
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
  # Snapshot settings.json first: the installer's --with-hooks rewrite drops
  # any keys it doesn't manage. We merge them back right after.
  snapshot_claude_settings
  log "Claude: --only claude --with-hooks (non-interactive)"
  run npx -y "github:$REPO" -- --only claude --with-hooks --non-interactive \
    || warn "Claude installer failed (continuing)"
  restore_claude_settings

  # Codex CLI: skill (installer runs `skills add ... --yes --all` internally)
  # Snapshot config.toml first: guard its MCP servers / trust_levels / plugins
  # against any destructive rewrite, then fill back anything dropped.
  snapshot_codex_config
  log "Codex: --only codex (non-interactive)"
  run npx -y "github:$REPO" -- --only codex --non-interactive \
    || warn "Codex installer failed (continuing)"
  restore_codex_config

  # Google Antigravity: soft-probe agent, force with --only
  log "Antigravity: --only antigravity (non-interactive)"
  run npx -y "github:$REPO" -- --only antigravity --non-interactive \
    || warn "Antigravity installer failed (continuing)"

  # The universal `skills add` step (codex/antigravity) drops skills into the
  # project-local ./.agents/skills dir, NOT into each agent's GLOBAL skills dir.
  # Mirror them into the global dirs so the agents actually see caveman, then
  # clean the project junk. (Without this, codex/antigravity get no skills.)
  if [ -d "./.agents/skills" ]; then
    if [ ! -d "$GEMINI_SKILLS/caveman" ]; then
      log "copying skills -> $GEMINI_SKILLS (Antigravity)"
      mkdir -p "$GEMINI_SKILLS"
      cp -R ./.agents/skills/* "$GEMINI_SKILLS"/ 2>/dev/null || true
    fi
    if [ ! -d "$CODEX_SKILLS/caveman" ]; then
      log "copying skills -> $CODEX_SKILLS (Codex)"
      mkdir -p "$CODEX_SKILLS"
      cp -R ./.agents/skills/* "$CODEX_SKILLS"/ 2>/dev/null || true
    fi
    # Claude: the official installer SYMLINKS ~/.claude/skills/<skill> at
    # ../../.agents/skills (i.e. ~/.agents/skills), but the real files land in the
    # project-local ./.agents/skills and get deleted by the rm below — leaving
    # broken links (and Finder alias badges). Replace any caveman symlink/stub with
    # a REAL copy from the source that's actually present.
    mkdir -p "$CLAUDE_SKILLS"
    for s in ./.agents/skills/*/; do
      [ -d "$s" ] || continue
      sn="$(basename "$s")"
      if [ -L "$CLAUDE_SKILLS/$sn" ] || [ ! -e "$CLAUDE_SKILLS/$sn" ]; then
        rm -rf "$CLAUDE_SKILLS/$sn"
        cp -R "$s" "$CLAUDE_SKILLS/$sn" 2>/dev/null \
          && log "materialized Claude skill $sn (was symlink/missing)"
      fi
    done
  fi
  [ -d "./.agents" ] && rm -rf "./.agents" 2>/dev/null || true

  # Optionally wire the caveman-shrink MCP proxy for codex. NOTE: caveman-shrink
  # is NOT a standalone server — it's a middleware that must WRAP an upstream MCP
  # command (`caveman-shrink <upstream-cmd> [args]`). Registered bare it exits 2
  # ("missing upstream command") and codex reports a failed handshake. So we only
  # register it when the caller names an upstream to wrap via CAVEMAN_SHRINK_UPSTREAM.
  #
  #   CAVEMAN_SHRINK_UPSTREAM="codegraph serve --mcp" bash setup.sh
  #
  # registers a [mcp_servers.codegraph] that pipes codegraph through the shrinker.
  wire_codex_mcp
}

# Register a caveman-shrink-wrapped MCP server in codex's global config.toml,
# but ONLY when CAVEMAN_SHRINK_UPSTREAM names the upstream command to wrap.
# Idempotent: skips if the target [mcp_servers.<name>] table already exists.
wire_codex_mcp() {
  local upstream="${CAVEMAN_SHRINK_UPSTREAM:-}"
  if [ -z "$upstream" ]; then
    log "codex MCP: CAVEMAN_SHRINK_UPSTREAM unset — skipping (shrink proxy needs an upstream to wrap)"
    return 0
  fi

  # Name the wrapped server after the upstream's first token.
  local name; name="${upstream%% *}"
  # Build a TOML string array of: caveman-shrink <upstream tokens...>
  local arr='"-y", "'"$MCP_SHRINK_PKG"'"' tok
  for tok in $upstream; do arr="$arr, \"$tok\""; done

  local block
  block="$(printf '\n[mcp_servers.%s]\ncommand = "npx"\nargs = [%s]\n' "$name" "$arr")"

  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY: register wrapped MCP [mcp_servers.$name] in $CODEX_CONFIG -> npx $MCP_SHRINK_PKG $upstream"
    return 0
  fi

  if [ -f "$CODEX_CONFIG" ] && grep -qF "[mcp_servers.$name]" "$CODEX_CONFIG"; then
    warn "codex MCP [$name] already present in $CODEX_CONFIG — leaving as-is (edit manually to wrap)"
    return 0
  fi

  mkdir -p "$CODEX_DIR"
  printf '%s' "$block" >> "$CODEX_CONFIG"
  log "registered shrink-wrapped MCP [$name] -> $CODEX_CONFIG"
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
