# ag-caveman

New-machine setup for [**caveman**](https://github.com/JuliusBrussee/caveman) — the agent skill that makes AI coding assistants talk terse ("why use many token when few token do trick"). One script installs caveman for **Claude Code**, **Codex CLI**, and **Google Antigravity**, then writes the caveman activation instruction straight into each agent's **global rule file** so the mode is always-on.

## Why this exists

The official caveman installer wires an always-on **hook only for Claude Code**. Codex CLI and Antigravity have no SessionStart hook, so without help they only get the skill — not automatic activation. This repo fills that gap: it injects a managed caveman block into each agent's global rule file (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`), giving you consistent always-on behavior across all three.

## Contents

| File | Purpose |
|------|---------|
| `setup.sh` | Cross-platform installer + global-rule injector (macOS / Linux / Windows Git Bash). |
| `caveman-rule.md` | Single source of the caveman activation instruction. Edit this to change behavior everywhere. |
| `.gitignore` | Ignores `.claude/` local config and the usual junk. |

## Quick start

On a new machine:

```bash
git clone https://github.com/zasuozz-oss/ag-caveman.git
cd ag-caveman
bash setup.sh
```

> **Windows:** run from **Git Bash** (or WSL). Requires [Node.js](https://nodejs.org) (provides `npx`) and `git`.

## What `setup.sh` does

1. **Installs caveman per agent** via the official installer:
   - **Claude Code** — `install.sh` (macOS/Linux via `curl | bash`) or `install.ps1` (Windows via PowerShell). Gets plugin + hooks + statusline.
   - **Codex CLI** — `npx skills add JuliusBrussee/caveman -a codex`.
   - **Antigravity** — `npx github:JuliusBrussee/caveman -- --only antigravity`, then copies skills into `~/.gemini/config/skills`.
2. **Injects the caveman instruction** from `caveman-rule.md` into each global rule file, wrapped in idempotent markers:
   - Claude Code → `~/.claude/CLAUDE.md`
   - Codex CLI → `~/.codex/AGENTS.md`
   - Antigravity → `~/.gemini/config/GEMINI.md`

Re-running is safe: the managed block is replaced in place, never duplicated.

## Flags

| Flag | Effect |
|------|--------|
| (none) | Full install + rule injection. |
| `--rules-only` | Only (re)write the global rule blocks. Use after editing `caveman-rule.md`. |
| `--no-rules` | Only run the installers, skip rule injection. |
| `--dry-run` | Print every action, change nothing. |
| `-h`, `--help` | Show usage. |

Override the per-command timeout (default 300s) with `CAVEMAN_TIMEOUT=600 bash setup.sh`.

## Changing the default behavior

The default caveman level is **full**. To change wording or level, edit `caveman-rule.md`, then push it to all three agents:

```bash
bash setup.sh --rules-only
```

Per-session override (Claude Code): `/caveman lite|full|ultra`. Stop with `stop caveman` or `normal mode`.

## Notes

- Caveman keeps full technical accuracy — only fluff (articles, filler, pleasantries, hedging) is dropped.
- Code, commit messages, and PR bodies are always written in normal prose (enforced by the rule).
- Caveman itself is by [JuliusBrussee](https://github.com/JuliusBrussee/caveman); this repo is only a setup wrapper.
