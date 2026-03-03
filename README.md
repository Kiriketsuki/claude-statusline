# claude-statusline

A three-line Claude Code status bar — Chrysaki Geometric Dashboard design — displaying model, workspace context, API usage, and vault inbox depth.

Built for the [obKidian](https://github.com/Kiriketsuki/obKidian) vault but usable in any Claude Code setup.

## Status Line Layout

### Line 1: Brand Bar

```
 ━━  ⬢ Claude Sonnet 4.6  ━━━━━━━━━━━━  obKidian  ◆  main ↑2  ━━
```

Animated tri-primary gradient (Emerald → Royal Blue → Amethyst) flows continuously across the entire line. The `━` bridge auto-expands to fill terminal width. The `◆` separator is muted; `↑N` is Blonde Light.

### Line 2: Usage Metrics

```
 ▰ 5h   ▲▼▲▼△▽△▽  13% (4h 25m)    ▰ 7d   ▲▼▲▼▲▼▲▼  50% (4d 19h)
```

8-position progress bars with threshold colours and shape morphing:

| State | Shape | Colour |
|:---|:---|:---|
| Normal | `▰` | Emerald Lt (5h) / Secondary (7d) |
| Warning >=50% | `▱` | Blonde |
| Critical >=75% | `◆` | Ruby |

### Line 3: Context + Status

```
 ▰ ctx  ▲▼▲▽△▽△▽  36% (72k/200k)    ◈ issues: 3    ◇ inbox: 5
```

Context bar uses Teal (normal) → Orange (>=50%) → Ruby (>=80% bar). Critical marker at >=128k tokens absolute. Handoff warning appended at >=100k tokens.

All label fields are 3-char wide so progress bars column-align across lines 2 and 3. Percentages use `%2d` format for consistent 1–99% width.

## Colour Thresholds

| Metric | Normal | Warning | Critical |
|:---|:---|:---|:---|
| 5h usage | Emerald Lt | Blonde (>=50%) | Ruby (>=75%) |
| 7d usage | Secondary | Blonde (>=50%) | Ruby (>=75%) |
| Context % | Teal | Orange (>=50%) | Ruby (>=80% bar) |
| Context tokens | Teal marker | Orange marker (>=50%) | Ruby marker (>=128k abs) |

## Bar Styles

Set `CHRYSAKI_BAR_STYLE` in your shell environment to switch progress bar shapes. Default: `wave`.

| Style | Filled | Empty | Effect |
|:---|:---|:---|:---|
| `wave` | `▲▼▲▼...` | `△▽△▽...` | Alternating up/down triangles — tiling trapezoid effect **(default)** |
| `hex` | `⬢⬢⬢⬢...` | `⬡⬡⬡⬡...` | Black/white hexagons |
| `diamond` | `◆◆◆◆...` | `◇◇◇◇...` | Black/white diamonds |
| `circle` | `●●●●...` | `○○○○...` | Black/white circles |
| `block` | `████...` | `░░░░...` | Full block / light shade |

```bash
# In ~/.bashrc, ~/.zshrc, ~/.config/fish/config.fish, etc.
export CHRYSAKI_BAR_STYLE=hex
```

## Setup

Install as a submodule inside your `~/.claude` directory:

```bash
git submodule add https://github.com/Kiriketsuki/claude-statusline.git statusline
```

Wire up `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline/statusline-command.sh"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "bash ~/.claude/statusline/fetch-usage.sh > /dev/null 2>&1 &" }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash ~/.claude/statusline/fetch-usage.sh > /dev/null 2>&1 &" },
          { "type": "command", "command": "bash ~/.claude/statusline/fetch-stats.sh > /dev/null 2>&1 &" }
        ]
      }
    ]
  }
}
```

## Cross-Platform Compatibility

The script uses `#!/usr/bin/env bash` and is tested on:

| Platform | Shell | Notes |
|:---|:---|:---|
| Windows | Git Bash (MINGW/MSYS) | WinGet PATH auto-detected; `/tmp/` maps to Windows temp |
| Windows | WSL (Ubuntu/Debian) | Full Linux bash — works natively |
| Linux | bash / zsh / fish | Claude Code invokes `bash` explicitly |
| macOS | bash / zsh | Afterthought; should work, `date -j` fallback in place |

The `command:` in `settings.json` always calls `bash` explicitly, so the user's interactive shell (PowerShell, Fish, Zsh, etc.) does not affect the renderer.

Platform-specific setup (WinGet PATH) is conditional on `uname -s` matching `MINGW*|MSYS*|CYGWIN*` — no-ops on Linux/macOS.

## Scripts

| Script | Role |
|:---|:---|
| `statusline-command.sh` | Main renderer — reads caches and emits the formatted 3-line status bar |
| `fetch-usage.sh` | Background fetcher — polls the Anthropic API for 5h/7d usage; writes to `/tmp/.claude_usage_cache` |
| `fetch-stats.sh` | Background fetcher — polls GitHub for open issue count per repo; writes to `/tmp/.claude_stats_cache_{slug}` |

## Dependencies

- `bash` >= 4.0 — substring ops, `local`, arithmetic
- `jq` — JSON parsing (WinGet on Windows, package manager on Linux/macOS)
- `curl` — Anthropic API calls (`fetch-usage.sh`)
- `gh` — GitHub CLI for issue counts (`fetch-stats.sh`); must be authenticated
- `git` — branch and commit info
- `tput` — terminal width detection (falls back to 80 cols if unavailable)

## Cache Files

| File | Written by | Read by | Content |
|:---|:---|:---|:---|
| `/tmp/.claude_usage_cache` | `fetch-usage.sh` | `statusline-command.sh` | `5h%\n7d%\nreset_ts\nreset_ts` |
| `/tmp/.claude_stats_cache_{slug}` | `fetch-stats.sh` | `statusline-command.sh` | Open issue count |

## Unicode Reference

All chars emitted as explicit UTF-8 byte sequences for shell-locale independence:

| Char | U+ | Used for |
|:---|:---|:---|
| `⬢` U+2B22 | Black Hexagon | `hex` style filled / Line 1 model badge |
| `⬡` U+2B21 | White Hexagon | `hex` style empty |
| `▲` U+25B2 | Up-pointing Triangle | `wave` filled (even) |
| `▼` U+25BC | Down-pointing Triangle | `wave` filled (odd) |
| `△` U+25B3 | Up-pointing Triangle (outline) | `wave` empty (even) |
| `▽` U+25BD | Down-pointing Triangle (outline) | `wave` empty (odd) |
| `◆` U+25C6 | Black Diamond | `diamond` filled / critical marker / Line 1 sep |
| `◇` U+25C7 | White Diamond | `diamond` empty / inbox icon |
| `◈` U+25C8 | Diamond with dot | Issues icon |
| `●` U+25CF | Black Circle | `circle` filled |
| `○` U+25CB | White Circle | `circle` empty |
| `█` U+2588 | Full Block | `block` filled |
| `░` U+2591 | Light Shade | `block` empty |
| `▰` U+25B0 | Black Parallelogram | Normal section marker |
| `▱` U+25B1 | White Parallelogram | Warning section marker |
| `━` U+2501 | Heavy Horizontal | Line 1 bridge and bookends |
| `↑` U+2191 | Upwards Arrow | Unsynced commit count |
| `→` U+2192 | Rightwards Arrow | Handoff warning |
