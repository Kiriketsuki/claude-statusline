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
