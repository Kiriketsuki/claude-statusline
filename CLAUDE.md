# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**claude-statusline** is a three-line Claude Code status bar (Chrysaki Geometric Dashboard design). It renders model info, workspace context, API usage metrics, and vault inbox depth inside the Claude Code UI via the `statusLine` command hook.

Installed as a git submodule at `~/.claude/statusline/` and wired up through `~/.claude/settings.json`.

## Scripts

| Script | Role |
|:---|:---|
| `statusline-command.sh` | Main renderer — reads caches, emits the formatted 3-line status bar to stdout |
| `fetch-usage.sh` | Background fetcher — polls Anthropic OAuth API for 5h/7d utilization; writes to `/tmp/.claude_usage_cache` |
| `fetch-stats.sh` | Background fetcher — polls GitHub via `gh` CLI for open issue count; writes to `/tmp/.claude_stats_cache_{slug}` |

## Architecture

### Data flow

```
PreToolUse hook  --> fetch-usage.sh (background) --> /tmp/.claude_usage_cache
Stop hook        --> fetch-usage.sh + fetch-stats.sh (background) --> cache files
statusLine cmd   --> statusline-command.sh (reads caches, reads git state, renders 3 lines)
```

`statusline-command.sh` receives the Claude Code status JSON on stdin (piped by Claude Code) and reads all live data from it (model, context window, version). Usage and issue counts come from cache files written by the background fetchers — no blocking I/O in the renderer.

### Cache files

| File | Content (line-by-line) |
|:---|:---|
| `/tmp/.claude_usage_cache` | `five_h%`, `seven_d%`, `five_h_reset_iso`, `seven_d_reset_iso` |
| `/tmp/.claude_stats_cache_{repo_slug}` | open issue count |
| `/tmp/.claude_token_cache` | OAuth access token (15-min TTL, chmod 600) |

### Line layout

- **Line 1 (Brand Bar)**: Animated Emerald→RoyalBlue→Amethyst gradient across `━` bridge; model badge pulses solid/outline by tier (▲=Haiku, ⬟=Sonnet, ⬢=Opus); smart CWD shows `parent/basename`; git branch + `↑N` unsynced commits.
- **Line 2 (Usage)**: 5h and 7d usage sections with 8-position progress bars; section marker morphs ▰→▱→◆ at thresholds; `(Xh Ym)` reset countdown from ISO timestamp.
- **Line 3 (Context + Status)**: Context window bar; handoff warning at >=100k tokens; CLI version with upgrade arrow; open issues; vault inbox depth (reads `001-Inbox/Scratch Book.md`).

### Colour thresholds

| Metric | Normal | Warning (>=50%) | Critical |
|:---|:---|:---|:---|
| 5h usage | Emerald Lt | Blonde | Ruby (>=75%) |
| 7d usage | Secondary | Blonde | Ruby (>=75%) |
| Context % | Teal | Orange | Ruby (>=80% bar) |
| Context tokens | Teal | Orange (>=50%) | Ruby (>=128k abs) |

### Column alignment

Lines 2 and 3 share a `first_w` variable — the max pixel-width of the 5h section vs the ctx section — so the `│` dividers align vertically. All label fields are 3-char wide (`5h`, `7d`, `ctx`) and percentages use `%2d%%` format.

### Bar styles

Configurable via `CHRYSAKI_BAR_STYLE` env var. Default: `wave` (alternating ▲▼/△▽ triangles). Options: `hex`, `diamond`, `circle`, `block`.

`wave_shift` (0 or 1, toggled every 2 seconds) scrolls the wave pattern for animation. `grad_phase` (advances 6 units/second on a 400-unit cycle) drives the Line 1 gradient animation.

## Key Implementation Details

- **Gradient rendering**: Two functions — `gradient_text` (local scale) and `gradient_text_off` (global offset into a shared scale) — the latter is used on Line 1 so the gradient flows continuously across all segments despite them being printed separately.
- **Unicode output**: All non-ASCII chars are emitted as explicit UTF-8 byte sequences (`printf "\xe2\x96\xb2"`) for shell-locale independence.
- **Platform detection**: `uname -s` checks for `MINGW*|MSYS*|CYGWIN*` to add WinGet PATH on Windows Git Bash; no-ops on Linux/macOS.
- **Token caching** (`fetch-usage.sh`): OAuth token is cached to `/tmp/.claude_token_cache` for 15 minutes (stat mtime, chmod 600) to avoid repeated credential file reads.
- **Multi-account GitHub** (`fetch-stats.sh`): Selects `gh auth token --user` based on repo owner (`Jovian-Aurrigo` vs `Kiriketsuki`); exits silently for unknown owners.

## Dependencies

- `bash` >= 4.0, `jq`, `curl`, `git`, `gh` (authenticated), `tput`
- On Windows: tools installed via WinGet; path `/c/Users/Kidriel/AppData/Local/Microsoft/WinGet/Links` auto-appended

**Quick test** (pipe minimal status JSON to renderer):
```bash
echo '{"model":"claude-sonnet-4-6","context_window":{"tokens_used":1000,"tokens_remaining":199000}}' \
  | bash statusline-command.sh
```

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **statusline** (8 symbols, 0 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## When Debugging

1. `gitnexus_query({query: "<error or symptom>"})` — find execution flows related to the issue
2. `gitnexus_context({name: "<suspect function>"})` — see all callers, callees, and process participation
3. `READ gitnexus://repo/statusline/process/{processName}` — trace the full execution flow step by step
4. For regressions: `gitnexus_detect_changes({scope: "compare", base_ref: "main"})` — see what your branch changed

## When Refactoring

- **Renaming**: MUST use `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` first. Review the preview — graph edits are safe, text_search edits need manual review. Then run with `dry_run: false`.
- **Extracting/Splitting**: MUST run `gitnexus_context({name: "target"})` to see all incoming/outgoing refs, then `gitnexus_impact({target: "target", direction: "upstream"})` to find all external callers before moving code.
- After any refactor: run `gitnexus_detect_changes({scope: "all"})` to verify only expected files changed.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Tools Quick Reference

| Tool | When to use | Command |
|------|-------------|---------|
| `query` | Find code by concept | `gitnexus_query({query: "auth validation"})` |
| `context` | 360-degree view of one symbol | `gitnexus_context({name: "validateUser"})` |
| `impact` | Blast radius before editing | `gitnexus_impact({target: "X", direction: "upstream"})` |
| `detect_changes` | Pre-commit scope check | `gitnexus_detect_changes({scope: "staged"})` |
| `rename` | Safe multi-file rename | `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` |
| `cypher` | Custom graph queries | `gitnexus_cypher({query: "MATCH ..."})` |

## Impact Risk Levels

| Depth | Meaning | Action |
|-------|---------|--------|
| d=1 | WILL BREAK — direct callers/importers | MUST update these |
| d=2 | LIKELY AFFECTED — indirect deps | Should test |
| d=3 | MAY NEED TESTING — transitive | Test if critical path |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/statusline/context` | Codebase overview, check index freshness |
| `gitnexus://repo/statusline/clusters` | All functional areas |
| `gitnexus://repo/statusline/processes` | All execution flows |
| `gitnexus://repo/statusline/process/{name}` | Step-by-step execution trace |

## Self-Check Before Finishing

Before completing any code modification task, verify:
1. `gitnexus_impact` was run for all modified symbols
2. No HIGH/CRITICAL risk warnings were ignored
3. `gitnexus_detect_changes()` confirms changes match expected scope
4. All d=1 (WILL BREAK) dependents were updated

## Keeping the Index Fresh

After committing code changes, the GitNexus index becomes stale. Re-run analyze to update it:

```bash
npx gitnexus analyze
```

If the index previously included embeddings, preserve them by adding `--embeddings`:

```bash
npx gitnexus analyze --embeddings
```

To check whether embeddings exist, inspect `.gitnexus/meta.json` — the `stats.embeddings` field shows the count (0 means no embeddings). **Running analyze without `--embeddings` will delete any previously generated embeddings.**

> Claude Code users: A PostToolUse hook handles this automatically after `git commit` and `git merge`.

## CLI

- Re-index: `npx gitnexus analyze`
- Check freshness: `npx gitnexus status`
- Generate docs: `npx gitnexus wiki`

<!-- gitnexus:end -->
