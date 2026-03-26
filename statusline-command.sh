#!/usr/bin/env bash
# Platform-specific PATH augmentation
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    # Windows Git Bash: ensure WinGet-installed tools (jq, etc.) are on PATH
    WINGET_LINKS="/c/Users/Kidriel/AppData/Local/Microsoft/WinGet/Links"
    [ -d "$WINGET_LINKS" ] && export PATH="$PATH:$WINGET_LINKS"
    ;;
esac

# --- accessibility flags ---
# NO_COLOR (https://no-color.org/): when present in the environment (even empty), disable ANSI.
# Local extension: NO_COLOR=0 explicitly re-enables colour (intentional deviation from spec).
if [ "${NO_COLOR+set}" = "set" ] && [ "${NO_COLOR}" != "0" ]; then
  NO_COLOUR=1
else
  NO_COLOUR=0
fi
# CHRYSAKI_NO_ANIMATE: any value other than '0' freezes all animation phases.
CHRYSAKI_NO_ANIMATE="${CHRYSAKI_NO_ANIMATE:-0}"

input=$(cat)

# --- model ---
model_raw=$(echo "$input" | jq -r '.model.display_name // ""')
# Prefix "Claude " if not already present (API returns e.g. "Sonnet 4.6")
case "$model_raw" in
  Claude*) model="$model_raw" ;;
  *)       model="Claude $model_raw" ;;
esac

# --- folder ---
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir_name=$(basename "$dir")

# --- smart CWD display: show parent/basename for context (e.g. dev/obKidian) ---
raw_parent=$(dirname "$dir" 2>/dev/null)
parent_base=$(basename "$raw_parent" 2>/dev/null)
if [ "$raw_parent" = "$HOME" ] || [ "$raw_parent" = "/" ] || \
   [ -z "$parent_base" ] || [ "$parent_base" = "." ]; then
  dir_display="$dir_name"
else
  dir_display="${parent_base}/${dir_name}"
fi

# --- git branch + unsynced + changes + worktree ---
branch=""
unsynced=0
git_insertions=0
git_deletions=0
worktree_name=""
if [ -d "${dir}/.git" ] || git -C "$dir" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$dir" rev-parse --short HEAD 2>/dev/null)
  commit_hash=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
  unsynced=$(git -C "$dir" log '@{u}..HEAD' --oneline 2>/dev/null | wc -l | tr -d ' ')
  # Staged and unstaged file counts
  staged_count=$(git -C "$dir" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  unstaged_count=$(git -C "$dir" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  # Changes: insertions/deletions from staged + unstaged
  _unstaged=$(git -C "$dir" diff --shortstat 2>/dev/null)
  _staged=$(git -C "$dir" diff --cached --shortstat 2>/dev/null)
  git_insertions=$(( $(echo "$_unstaged" | grep -oP '\d+(?= insertion)' 2>/dev/null || echo 0) + $(echo "$_staged" | grep -oP '\d+(?= insertion)' 2>/dev/null || echo 0) ))
  git_deletions=$(( $(echo "$_unstaged" | grep -oP '\d+(?= deletion)' 2>/dev/null || echo 0) + $(echo "$_staged" | grep -oP '\d+(?= deletion)' 2>/dev/null || echo 0) ))
  # Worktree detection: git dir contains /worktrees/<name> when in a worktree
  _git_dir=$(git -C "$dir" rev-parse --git-dir 2>/dev/null)
  if [ -n "$_git_dir" ] && echo "$_git_dir" | grep -q '/worktrees/'; then
    worktree_name=$(basename "$_git_dir")
  fi
fi

# --- stats cache (issues, per-repo) ---
issue_count=""
remote=$(git -C "$dir" remote get-url origin 2>/dev/null)
if [ -n "$remote" ]; then
  repo_slug=$(echo "$remote" | sed 's|.*github\.com[:/]||' | sed 's|.*github-[a-z]*:||' | sed 's|\.git$||' | tr '/' '_')
  STATS_CACHE="/tmp/.claude_stats_cache_${repo_slug}"
  if [ -f "$STATS_CACHE" ]; then
    issue_count=$(sed -n '1p' "$STATS_CACHE")
    pr_number=$(sed -n '2p' "$STATS_CACHE")
    pr_title=$(sed -n '3p' "$STATS_CACHE")
    # Truncate PR title to 15 chars
    [ ${#pr_title} -gt 15 ] && pr_title="${pr_title:0:15}…"
  fi
fi

# --- inbox depth (obKidian only) ---
inbox_depth=0
SCRATCH="$dir/001-Inbox/Scratch Book.md"
if [ -f "$SCRATCH" ]; then
  inbox_depth=$(awk '/^## Ramblings/{found=1; next} /^## /{found=0} found && /^- /{c++} END{print c+0}' "$SCRATCH")
fi

# --- usage stats (5h / 7d) from native rate_limits in JSON stdin ---
# Claude Code >= 2.1 provides rate_limits.five_hour and rate_limits.seven_day directly.
five_h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null | cut -d. -f1)
seven_d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null | cut -d. -f1)
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
seven_d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

# --- account config dir (still needed for email display and fetch-stats.sh) ---
if [ -n "$CLAUDE_CONFIG_DIR" ]; then
  _config_dir="$CLAUDE_CONFIG_DIR"
else
  case "$dir" in
    */workdev/Aurrigo*) _config_dir="$HOME/.claude-aurrigo" ;;
    *)                  _config_dir="$HOME/.claude" ;;
  esac
fi
_acct=$(basename "$_config_dir")

# --- compute_delta: Unix epoch -> human-readable time until reset ---
compute_delta() {
  local reset_epoch="$1" now_epoch diff days hours minutes
  [ -z "$reset_epoch" ] && return
  now_epoch=$(date -u "+%s")
  diff=$(( reset_epoch - now_epoch ))
  if [ "$diff" -le 0 ]; then echo "now"; return; fi
  days=$(( diff / 86400 ))
  hours=$(( (diff % 86400) / 3600 ))
  minutes=$(( (diff % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then echo "${days}d ${hours}h"
  elif [ "$hours" -gt 0 ]; then echo "${hours}h ${minutes}m"
  else echo "${minutes}m"
  fi
}

# --- osc8_link: clickable hyperlink via OSC 8 escape sequence ---
# Usage: osc8_link TEXT URL
# When CHRYSAKI_NO_LINKS=1 or NO_COLOUR=1, prints TEXT only (no escape sequences).
osc8_link() {
  local text="$1" url="$2"
  if [ "${CHRYSAKI_NO_LINKS:-0}" = "1" ] || [ "$NO_COLOUR" -eq 1 ]; then
    printf "%s" "$text"
  else
    printf "\033]8;;%s\033\\\\%s\033]8;;\033\\\\" "$url" "$text"
  fi
}

# --- gradient_text / gradient_text_off: REMOVED in v2.1 ---
# Gradient rendering looked broken when static (Claude Code only re-renders on events).
# Replaced by solid jewel-tone colours. The phase math (grad_phase) is retained for
# future re-enablement behind CHRYSAKI_ANIMATE when refreshIntervalSeconds lands.

# --- progress_bar: 8-position progress bar with threshold colours and configurable shape ---
# Usage: progress_bar PERCENT NR NG NB WARN_T WR WG WB CRIT_T CR CG CB
# Shape controlled by CHRYSAKI_BAR_STYLE env var (default: wave).
# Does NOT print reset -- caller handles that.
#
# Styles:
#   hex      -- ⬢ / ⬡  (black hexagon / white hexagon)    [default]
#   diamond  -- ◆ / ◇  (black diamond / white diamond)
#   circle   -- ● / ○  (black circle / white circle)
#   wave     -- ▲▼ / △▽  alternating up/down triangles (tiling trapezoid effect)
#   block    -- █ / ░  (full block / light shade)
progress_bar() {
  local pct="$1"
  local nr="$2"  ng="$3"  nb="$4"
  local wt="$5"  wr="$6"  wg="$7"  wb="$8"
  local ct="$9"  cr="${10}" cg="${11}" cb="${12}"
  local fr fg fb filled i

  # Select fill colour based on thresholds
  if [ "$pct" -ge "$ct" ] 2>/dev/null; then
    fr="$cr" fg="$cg" fb="$cb"
  elif [ "$pct" -ge "$wt" ] 2>/dev/null; then
    fr="$wr" fg="$wg" fb="$wb"
  else
    fr="$nr" fg="$ng" fb="$nb"
  fi

  # filled = round(pct * 8 / 100), clamped 0-8
  filled=$(( (pct * 8 + 50) / 100 ))
  [ "$filled" -gt 8 ] && filled=8
  [ "$filled" -lt 0 ] && filled=0

  # Colour prefix for filled positions (empty when NO_COLOUR)
  local cfill=""
  [ "$NO_COLOUR" -eq 0 ] && cfill=$(printf "\033[38;2;%d;%d;%dm" "$fr" "$fg" "$fb")

  i=0
  while [ "$i" -lt 8 ]; do
    case "${BAR_STYLE:-wave}" in
      diamond)
        if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x97\x86" "$cfill"           # ◆
        else printf "%b\xe2\x97\x87" "$C_HEX_EMPTY"; fi ;;                          # ◇
      circle)
        if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x97\x8f" "$cfill"           # ●
        else printf "%b\xe2\x97\x8b" "$C_HEX_EMPTY"; fi ;;                          # ○
      wave)
        # 2-phase alternation (up/down), 4-step scroll via wave_shift.
        # Filled and empty cells use the same solid glyph (▲▼); only color differs.
        local wpos=$(( (i + wave_shift) % 4 ))
        case "$wpos" in
          0|2) if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x96\xb2" "$cfill"   # ▲ solid up, filled
               else printf "%b\xe2\x96\xb2" "$C_HEX_EMPTY"; fi ;;                  # ▲ solid up, dim
          1|3) if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x96\xbc" "$cfill"   # ▼ solid down, filled
               else printf "%b\xe2\x96\xbc" "$C_HEX_EMPTY"; fi ;;                  # ▼ solid down, dim
        esac ;;
      block)
        if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x96\x88" "$cfill"           # █
        else printf "%b\xe2\x96\x91" "$C_HEX_EMPTY"; fi ;;                          # ░
      *)  # hex (default)
        if [ "$i" -lt "$filled" ]; then printf "%s\xe2\xac\xa2" "$cfill"           # ⬢
        else printf "%b\xe2\xac\xa1" "$C_HEX_EMPTY"; fi ;;                          # ⬡
    esac
    i=$(( i + 1 ))
  done
  printf "%b" "$R"
}

# --- section_marker: shape-morphing section icon based on thresholds ---
# Outputs ▰ (normal) / ▱ (warning) / ◆ (critical)
section_marker() {
  local val="$1" wt="$2" ct="$3"
  if   [ "$val" -ge "$ct" ] 2>/dev/null; then printf "\xe2\x97\x86"   # ◆ solid diamond
  elif [ "$val" -ge "$wt" ] 2>/dev/null; then printf "\xe2\x96\xb1"   # ▱ open parallelogram
  else                                        printf "\xe2\x96\xb0"   # ▰ filled parallelogram
  fi
}

# --- CLI version (from input JSON when available) ---
ver_current=$(echo "$input" | jq -r '.version // empty' 2>/dev/null)
ver_latest=$(echo "$input" | jq -r '.latestVersion // empty' 2>/dev/null)

# --- context window ---
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_str=""
ctx_tokens_str=""
ctx_used=""
used_int=""
if [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")
  ctx_str="${used_int}%"
  ctx_used=$(echo "$input" | jq -r '
    (.context_window.current_usage.cache_read_input_tokens
     + .context_window.current_usage.cache_creation_input_tokens
     + .context_window.current_usage.input_tokens
     + .context_window.current_usage.output_tokens) // empty' 2>/dev/null)
  ctx_total=$(echo "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
  if [ -n "$ctx_used" ] && [ -n "$ctx_total" ]; then
    ctx_tokens_str="$(( ctx_used / 1000 ))k/$(( ctx_total / 1000 ))k"
  fi
fi

# --- progressive compact level (context-driven + width-driven) ---
compact_level=0
if [ -n "$used_int" ]; then
  [ "$used_int" -ge 60 ] && compact_level=1   # hide reset timers
  [ "$used_int" -ge 75 ] && compact_level=2   # collapse token breakdown
  [ "$used_int" -ge 85 ] && compact_level=3   # hide bridges
fi
# Width-driven compact is applied after COLS is determined (see below)

# --- cost, speed, session clock ---
cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)
_usd_to_sgd="${CHRYSAKI_USD_TO_SGD:-1.35}"
cost_sgd=$(echo "$cost_usd $_usd_to_sgd" | awk '{printf "%.2f", $1 * $2}')

duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0' 2>/dev/null)
api_duration_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // 0' 2>/dev/null)

# Token speed: clamp api_duration_ms to minimum 1ms to avoid div-by-zero
total_out_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)
_api_ms="$api_duration_ms"
[ "$_api_ms" -lt 1 ] 2>/dev/null && _api_ms=1
tok_per_sec=$(echo "$total_out_tokens $_api_ms" | awk '{printf "%.0f", $1 / $2 * 1000}')

# Session clock
session_clock="0m"
if [ "$duration_ms" -gt 0 ] 2>/dev/null; then
  _secs=$(( duration_ms / 1000 ))
  _hrs=$(( _secs / 3600 ))
  _mins=$(( (_secs % 3600) / 60 ))
  _s=$(( _secs % 60 ))
  if [ "$_hrs" -gt 0 ]; then session_clock="${_hrs}hr ${_mins}m ${_s}s"
  elif [ "$_mins" -gt 0 ]; then session_clock="${_mins}m ${_s}s"
  else session_clock="${_s}s"; fi
fi

# --- cache token breakdown (for L3 token groups) ---
cache_read_in=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null)
cache_create_in=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' 2>/dev/null)
raw_in=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0' 2>/dev/null)
raw_out=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0' 2>/dev/null)

# Format token counts for display (Nk)
_fmt_k() { echo $(( $1 / 1000 ))k; }
cache_read_in_k=$(_fmt_k "$cache_read_in")
cache_create_in_k=$(_fmt_k "$cache_create_in")
raw_in_k=$(_fmt_k "$raw_in")
raw_out_k=$(_fmt_k "$raw_out")
# Compact mode totals
total_in_k=$(_fmt_k $(( cache_read_in + raw_in )))
total_out_k=$(_fmt_k $(( cache_create_in + raw_out )))

# --- Chrysaki colour palette ---
if [ "$NO_COLOUR" -eq 1 ]; then
  R="" DIM="" BOLD=""
  C_BLONDE_LT="" C_TEAL="" C_EMERALD_LT="" C_ORANGE=""
  C_SEC="" C_MUTED="" C_WARN="" C_ERROR="" C_HEX_EMPTY=""
  C_GREEN="" C_RED=""
else
  R="\033[0m"
  DIM="\033[2m"
  BOLD="\033[1m"

  # Identity colours
  C_BLONDE_LT="\033[38;2;208;184;80m"   # #d0b850 Blonde Light  -- unsynced commits
  C_TEAL="\033[38;2;30;136;152m"         # #1e8898 Teal          -- ctx (normal), issues
  C_EMERALD_LT="\033[38;2;26;138;106m"  # #1a8a6a Emerald Light -- 5h normal, inbox
  C_ORANGE="\033[38;5;208m"              # Terminal orange       -- ctx warning

  # Text hierarchy
  C_SEC="\033[38;2;160;164;184m"         # #a0a4b8 Secondary     -- 7d normal
  C_MUTED="\033[38;2;106;110;130m"       # #6a6e82 Muted         -- separators, reset timers

  # Alert thresholds
  C_WARN="\033[38;2;184;160;56m"         # #b8a038 Blonde        -- >=50% warning
  C_ERROR="\033[38;2;192;64;80m"         # #c04050 Error         -- >=75%/128k critical

  # Bar empty-position colour
  C_HEX_EMPTY="\033[38;2;64;70;90m"     # #40465a -- dim background positions

  # Git change colours
  C_GREEN="\033[38;2;80;180;80m"         # #50b450 -- insertions
  C_RED="\033[38;2;192;80;80m"           # #c05050 -- deletions
fi

# --- threshold colour logic ---
# ctx: Teal (normal) / orange (>=50%) / red (>=128k tokens)
ctx_color="$C_TEAL"
if   [ -n "$ctx_used" ] && [ "$ctx_used" -ge 128000 ] 2>/dev/null; then ctx_color="$C_ERROR"
elif [ -n "$used_int" ] && [ "$used_int"  -ge 50     ] 2>/dev/null; then ctx_color="$C_ORANGE"
fi

# ctx section marker: ▰ normal / ▱ >=50% / ◆ >=128k tokens absolute
ctx_marker=$(printf "\xe2\x96\xb0")   # ▰ default
if   [ -n "$ctx_used" ] && [ "$ctx_used" -ge 128000 ] 2>/dev/null; then ctx_marker=$(printf "\xe2\x97\x86")  # ◆
elif [ -n "$used_int" ] && [ "$used_int"  -ge 50     ] 2>/dev/null; then ctx_marker=$(printf "\xe2\x96\xb1") # ▱
fi

# handoff reminder at 100k tokens
handoff_warn=0
[ -n "$ctx_used" ] && [ "$ctx_used" -ge 100000 ] 2>/dev/null && handoff_warn=1

# 5h usage: Emerald (normal) / Blonde (>=50%) / Ruby (>=75%)
# When in warning/critical, threshold pulse modulates brightness via sine wave
five_h_color="$C_EMERALD_LT"
five_h_pulse=0   # 0 = static, 1 = pulsing
if [ -n "$five_h" ]; then
  if   [ "$five_h" -ge 75 ] 2>/dev/null; then five_h_color="$C_ERROR"; five_h_pulse=1
  elif [ "$five_h" -ge 50 ] 2>/dev/null; then five_h_color="$C_WARN";  five_h_pulse=1
  fi
fi

# 7d usage: Secondary (normal) / Blonde (>=50%) / Ruby (>=75%)
seven_d_color="$C_SEC"
seven_d_pulse=0
if [ -n "$seven_d" ]; then
  if   [ "$seven_d" -ge 75 ] 2>/dev/null; then seven_d_color="$C_ERROR"; seven_d_pulse=1
  elif [ "$seven_d" -ge 50 ] 2>/dev/null; then seven_d_color="$C_WARN";  seven_d_pulse=1
  fi
fi

# --- animation phase (shared across all rendering this frame) ---
# All phases derived from a single timestamp to avoid cross-second drift.
# CHRYSAKI_NO_ANIMATE: any value other than '0' freezes all phases.
# 8-step sine lookup for threshold pulse (scaled -100..+100); 1 step/sec = ~8s full cycle.
sine8=(0 71 100 71 0 -71 -100 -71)
if [ "$CHRYSAKI_NO_ANIMATE" != "0" ]; then
  grad_phase=0
  wave_shift=0
  badge_tick=0
  pulse_scale=100
  _jewel_seed=0
else
  _ts=$(date +%s)
  grad_phase=$(( (_ts * 6) % 400 ))
  wave_shift=$(( (_ts / 2) % 4 ))     # 0-3, 4-phase wave scroll
  badge_tick=$(( (_ts / 2) % 2 ))     # 0 or 1, solid/outline badge alternation
  pulse_idx=$(( _ts % 8 ))
  pulse_scale=$(( 85 + 15 * ${sine8[$pulse_idx]} / 100 ))   # range 70-100
  _jewel_seed="$_ts"
fi
# CHRYSAKI_JEWEL_STATIC: pin jewel index for screenshots/demos
[ -n "${CHRYSAKI_JEWEL_STATIC:-}" ] && _jewel_seed=0

# --- Chrysaki jewel tone pool (9 colours, interpolated around the Emerald-RoyalBlue-Amethyst loop) ---
# Full-brightness variants for text accents (L1 bridges, branch name).
# Dimmed variants for L2-L4 bridges.
# _jewel_seed + prime divisors ensure each line gets a different colour that shifts per render.
if [ "$NO_COLOUR" -eq 0 ]; then
  JEWEL_COLORS=(
    "\033[38;2;26;138;106m"    # 0 Emerald Lt
    "\033[38;2;26;119;100m"    # 1 Jade
    "\033[38;2;27;99;114m"     # 2 Deep Teal
    "\033[38;2;28;61;122m"     # 3 Royal Blue Lt
    "\033[38;2;43;55;128m"     # 4 Sapphire
    "\033[38;2;58;48;133m"     # 5 Indigo
    "\033[38;2;88;48;144m"     # 6 Amethyst Lt
    "\033[38;2;70;72;136m"     # 7 Twilight
    "\033[38;2;50;96;126m"     # 8 Storm
  )
  JEWEL_COLORS_DIM=(
    "\033[38;2;20;104;80m"     # 0 dimmed Emerald
    "\033[38;2;20;90;76m"      # 1 dimmed Jade
    "\033[38;2;21;75;86m"      # 2 dimmed Deep Teal
    "\033[38;2;22;46;92m"      # 3 dimmed Royal Blue
    "\033[38;2;32;42;96m"      # 4 dimmed Sapphire
    "\033[38;2;44;36;100m"     # 5 dimmed Indigo
    "\033[38;2;66;36;108m"     # 6 dimmed Amethyst
    "\033[38;2;53;54;102m"     # 7 dimmed Twilight
    "\033[38;2;38;72;95m"      # 8 dimmed Storm
  )
  # Per-line jewel selection: different primes guarantee no two adjacent lines share a colour
  C_JEWEL_L1="${JEWEL_COLORS[$(( _jewel_seed % 9 ))]}"
  C_BR_L1="${JEWEL_COLORS_DIM[$(( _jewel_seed % 9 ))]}"
  C_BR_L2="${JEWEL_COLORS_DIM[$(( (_jewel_seed / 3) % 9 ))]}"
  C_BR_L3="${JEWEL_COLORS_DIM[$(( (_jewel_seed / 7) % 9 ))]}"
  C_BR_L4="${JEWEL_COLORS_DIM[$(( (_jewel_seed / 11) % 9 ))]}"
  C_JEWEL_L4="${JEWEL_COLORS[$(( (_jewel_seed / 11) % 9 ))]}"
else
  JEWEL_COLORS=() JEWEL_COLORS_DIM=()
  C_JEWEL_L1="" C_BR_L1="" C_BR_L2="" C_BR_L3="" C_BR_L4="" C_JEWEL_L4=""
fi

# pulse_color: apply pulse_scale to an RGB colour, emit ANSI escape
# Usage: pulse_color R G B -> prints \033[38;2;r;g;bm (scaled)
pulse_color() {
  [ "$NO_COLOUR" -eq 1 ] && return
  local pr=$(( $1 * pulse_scale / 100 ))
  local pg=$(( $2 * pulse_scale / 100 ))
  local pb=$(( $3 * pulse_scale / 100 ))
  printf "\033[38;2;%d;%d;%dm" "$pr" "$pg" "$pb"
}

# Pre-compute pulsed colour escapes for 5h/7d sections
# Base RGB: C_WARN=#b8a038 (184,160,56)  C_ERROR=#c04050 (192,64,80)
if [ "$five_h_pulse" -eq 1 ] && [ "$NO_COLOUR" -eq 0 ]; then
  if [ -n "$five_h" ] && [ "$five_h" -ge 75 ] 2>/dev/null; then
    five_h_color=$(pulse_color 192 64 80)
  else
    five_h_color=$(pulse_color 184 160 56)
  fi
fi
if [ "$seven_d_pulse" -eq 1 ] && [ "$NO_COLOUR" -eq 0 ]; then
  if [ -n "$seven_d" ] && [ "$seven_d" -ge 75 ] 2>/dev/null; then
    seven_d_color=$(pulse_color 192 64 80)
  else
    seven_d_color=$(pulse_color 184 160 56)
  fi
fi

# --- terminal width ---
# Walk up the process tree to find an ancestor with a real TTY, then read its width.
# The statusline runs as a subprocess without a controlling terminal, so tput/stty on
# this process always returns 80. Walking up finds the claude process's TTY.
COLS=""
_pid=$$
for _i in 1 2 3 4 5 6 7 8; do
  _ppid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
  [ -z "$_ppid" ] || [ "$_ppid" = "1" ] && break
  _tty=$(ps -o tty= -p "$_ppid" 2>/dev/null | tr -d ' ')
  if [ -n "$_tty" ] && [ "$_tty" != "?" ]; then
    _ancestor_cols=$(stty size < "/dev/${_tty}" 2>/dev/null | awk '{print $2}')
    if [ -n "$_ancestor_cols" ] && [ "$_ancestor_cols" -gt 0 ] 2>/dev/null; then
      COLS="$_ancestor_cols"
      break
    fi
  fi
  _pid="$_ppid"
done
COLS="${COLS:-${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}}"
# Cap at 75% of terminal width so the statusline doesn't consume all real estate
COLS=$(( COLS * 3 / 4 ))

# Width-driven compact: force higher compact levels on narrow terminals
[ "$COLS" -lt 110 ] 2>/dev/null && [ "$compact_level" -lt 2 ] && compact_level=2
[ "$COLS" -lt 90 ]  2>/dev/null && [ "$compact_level" -lt 3 ] && compact_level=3

# --- bar style (override via CHRYSAKI_BAR_STYLE env var) ---
BAR_STYLE="${CHRYSAKI_BAR_STYLE:-wave}"

# --- active Claude account (from resolved config dir) ---
# Credentials file: for personal account it's $HOME/.claude.json (at home root),
# for Aurrigo it's $HOME/.claude-aurrigo/.claude.json (inside config dir)
if [ "$_acct" = ".claude" ]; then
  _creds_file="$HOME/.claude.json"
else
  _creds_file="${_config_dir}/.claude.json"
fi
if [ "$_acct" = ".claude-aurrigo" ]; then
  C_ACCOUNT="$C_ORANGE"
else
  C_ACCOUNT="$C_EMERALD_LT"
fi
claude_email=$(jq -r '.oauthAccount.emailAddress // empty' "$_creds_file" 2>/dev/null)
[ -z "$claude_email" ] && claude_email="unknown"

# Pre-compute deltas and section widths for bridge rendering
delta5="" delta7=""
[ -n "$five_h_reset" ] && delta5=$(compute_delta "$five_h_reset")
[ -n "$seven_d_reset" ] && delta7=$(compute_delta "$seven_d_reset")

five_h_sec_w=0
if [ -n "$five_h" ]; then
  five_h_pct_str=$(printf "%3d%%" "$five_h")
  five_h_sec_w=$(( 8 + 8 + 2 + ${#five_h_pct_str} ))   # " ▰ 5h   " + bar + "  " + pct
  if [ -n "$delta5" ] && [ "$compact_level" -lt 1 ]; then
    five_h_sec_w=$(( five_h_sec_w + 2 + 1 + ${#delta5} + 1 ))
  fi
fi

seven_d_sec_w=0
if [ -n "$seven_d" ]; then
  seven_d_pct_str=$(printf "%3d%%" "$seven_d")
  seven_d_sec_w=$(( 7 + 8 + 2 + ${#seven_d_pct_str} ))   # "▱ 7d   " (no leading space) + bar + "  " + pct
  if [ -n "$delta7" ] && [ "$compact_level" -lt 1 ]; then
    seven_d_sec_w=$(( seven_d_sec_w + 2 + 1 + ${#delta7} + 1 ))
  fi
fi

ctx_sec_w=0
if [ -n "$ctx_str" ]; then
  ctx_pct_str=$(printf "%3d%%" "$used_int")
  ctx_sec_w=$(( 8 + 8 + 2 + ${#ctx_pct_str} ))
  [ -n "$ctx_tokens_str" ] && ctx_sec_w=$(( ctx_sec_w + 2 + 1 + ${#ctx_tokens_str} + 1 ))
fi

# --- column alignment formula ---
# Every column transition uses the same formula:
#   bridge_chars = (mx[N] - my_content_width) + 1
# print_bridge adds 3-space padding on each side, so total gap per bridge = 7 + (mx[N] - my_width).
# This guarantees all lines' Nth columns start at the same position.
#
# Columns:  col1          col2          col3          col4          col5
#   L2:     5h section    7d section    speed         cost          clock
#   L3:     ctx section   ↓ in tokens   ↑ out tokens  handoff       —
#   L4:     branch        ⊙ hash        +N -M         unstaged      PR
#   L1:     model         (version aligns with col2)

_max() { local m=$1; shift; for v; do [ "$v" -gt "$m" ] 2>/dev/null && m=$v; done; echo "$m"; }

# --- col1 content widths ---
_l1_left_w=$(( L1_PREFIX_LEN + model_len ))
_l4_left_w=0
if [ -n "$branch" ]; then
  _l4_left_w=$(( 3 + ${#branch} ))   # " ⎇ " + branch
  [ "$unsynced" -gt 0 ] 2>/dev/null && _l4_left_w=$(( _l4_left_w + 2 + 1 + ${#unsynced} ))
fi

# --- col2 content widths ---
_l2_ml_w="$seven_d_sec_w"
_l3_ml_w=0
if [ -n "$ctx_str" ]; then
  if [ "$compact_level" -ge 2 ]; then
    _l3_ml_w=$(( 2 + ${#total_in_k} ))
  else
    _l3_ml_w=$(( 7 + ${#cache_read_in_k} + 6 + ${#raw_in_k} + 1 ))
  fi
fi
_l4_ml_w=0
[ -n "$commit_hash" ] && _l4_ml_w=$(( 2 + ${#commit_hash} ))

# --- col3 content widths ---
l2_speed_str="~${tok_per_sec}t/s"
l2_cost_str="\$${cost_sgd}"
l2_clock_str="$session_clock"
l2_clock_glyph_w=2
_l2_mc_w=${#l2_speed_str}

_l3_mc_w=0
if [ -n "$ctx_str" ]; then
  if [ "$compact_level" -ge 2 ]; then
    _l3_mc_w=$(( 2 + ${#total_out_k} ))
  else
    _l3_mc_w=$(( 7 + ${#cache_create_in_k} + 6 + ${#raw_out_k} + 1 ))
  fi
fi

# Always show +N -M (even +0 -0), so width is always populated
_l4_mc_w=0
if [ "$git_insertions" -gt 0 ] 2>/dev/null || [ "$git_deletions" -gt 0 ] 2>/dev/null; then
  [ "$git_insertions" -gt 0 ] 2>/dev/null && _l4_mc_w=$(( _l4_mc_w + 1 + ${#git_insertions} ))
  [ "$git_insertions" -gt 0 ] 2>/dev/null && [ "$git_deletions" -gt 0 ] 2>/dev/null && _l4_mc_w=$(( _l4_mc_w + 1 ))
  [ "$git_deletions" -gt 0 ] 2>/dev/null && _l4_mc_w=$(( _l4_mc_w + 1 + ${#git_deletions} ))
else
  _l4_mc_w=5   # "+0 -0"
fi

# --- col4 content widths ---
_l2_mr_w=${#l2_cost_str}
_l3_mr_w=11
[ "$handoff_warn" -ne 1 ] && _l3_mr_w=12   # "◇ no handoff"
_l4_mr_w=$(( ${#unstaged_count} + 9 ))
[ "$staged_count" -gt 0 ] 2>/dev/null && _l4_mr_w=$(( _l4_mr_w + ${#staged_count} + 8 ))

# --- col5 content widths ---
_l2_c5_w=$(( l2_clock_glyph_w + ${#l2_clock_str} ))
_l4_c5_w=5   # "no PR"
if [ -n "$pr_number" ]; then
  _l4_c5_w=$(( 4 + ${#pr_number} ))
  [ -n "$pr_title" ] && _l4_c5_w=$(( _l4_c5_w + 2 + ${#pr_title} ))
fi

# --- column maxes: one per column, the only alignment variables needed ---
mx1=$(_max "$_l1_left_w" "$five_h_sec_w" "$ctx_sec_w" "$_l4_left_w")
mx2=$(_max "$_l2_ml_w" "$_l3_ml_w" "$_l4_ml_w")
mx3=$(_max "$_l2_mc_w" "$_l3_mc_w" "$_l4_mc_w")
mx4=$(_max "$_l2_mr_w" "$_l3_mr_w" "$_l4_mr_w")
mx5=$(_max "$_l2_c5_w" "0" "$_l4_c5_w")

# --- trailing bridge: shared across all lines ---
# Each line's cumulative width through col N is: mx1+7 + mx2+7 + ... + mx[N-1]+7 + col_N_content
# Lines stopping at different columns get proportionally longer trailing bridges.
_content_through_c5=$(( mx1 + 7 + mx2 + 7 + mx3 + 7 + mx4 + 7 ))

# --- model badge: shape encodes model tier, pulses solid/outline every 2 seconds ---
# Haiku = ▲/△ (triangle, 3)  Sonnet = ⬟/⬠ (pentagon, 5)  Opus = ⬢/⬡ (hexagon, 6)
# badge_tick set in animation-phase block above (0 when frozen, 0 or 1 when live).
model_lower=$(printf "%s" "$model" | tr '[:upper:]' '[:lower:]')
if [ "$badge_tick" -eq 0 ]; then
  case "$model_lower" in
    *haiku*)  model_badge="\xe2\x96\xb2" ;;   # ▲ solid triangle  (U+25B2)
    *sonnet*) model_badge="\xe2\xac\x9f" ;;   # ⬟ solid pentagon  (U+2B1F)
    *opus*)   model_badge="\xe2\xac\xa2" ;;   # ⬢ solid hexagon   (U+2B22)
    *)        model_badge="\xe2\x97\x86" ;;   # ◆ solid diamond   (U+25C6)
  esac
else
  case "$model_lower" in
    *haiku*)  model_badge="\xe2\x96\xb3" ;;   # △ outline triangle (U+25B3)
    *sonnet*) model_badge="\xe2\xac\xa0" ;;   # ⬠ outline pentagon (U+2B20)
    *opus*)   model_badge="\xe2\xac\xa1" ;;   # ⬡ outline hexagon  (U+2B21)
    *)        model_badge="\xe2\x97\x87" ;;   # ◇ outline diamond  (U+25C7)
  esac
fi

# --- GitHub repo URL (for OSC 8 links) ---
repo_url=""
if [ -n "$remote" ]; then
  repo_path=$(echo "$remote" | sed 's|.*github\.com[:/]||' | sed 's|.*github-[a-z]*:||' | sed 's|\.git$||')
  [ -n "$repo_path" ] && repo_url="https://github.com/${repo_path}"
fi

# Bridge padding constant
BRIDGE_PAD=6

# Muted vertical divider used between sections
# "  │  " = 2 spaces + │ (U+2502) + 2 spaces, rendered in muted colour
DIV="  %b\xe2\x94\x82%b  "   # printf template: pass C_MUTED and R as args

# --- bridge helper: print N dash chars in muted colour ---
# Usage: print_bridge N [CHAR]
#   CHAR defaults to ━ (thick). Use ─ (thin) or ┈ (dashed-dot) for line-specific styles.
# When compact_level >= 3, bridges are replaced with spaces (same width).
# Bridge char constants (explicit UTF-8 byte sequences for shell-locale independence)
BR_THICK=$(printf "\xe2\x94\x81")    # ━ U+2501 BOX DRAWINGS HEAVY HORIZONTAL
BR_THIN=$(printf "\xe2\x94\x80")     # ─ U+2500 BOX DRAWINGS LIGHT HORIZONTAL
BR_DOT=$(printf "\xe2\x94\x84")      # ┄ U+2504 BOX DRAWINGS LIGHT TRIPLE DASH HORIZONTAL

# Bridge colour: set _bridge_color before calling print_bridge (defaults to C_MUTED)
_bridge_color=""
print_bridge() {
  local n="$1" ch="${2:-$BR_THIN}"
  local clr="${_bridge_color:-$C_MUTED}"
  [ "$n" -lt 1 ] && n=1
  if [ "$compact_level" -ge 3 ]; then
    printf "%$(( n + 6 ))s" ""
  else
    printf "   %b" "$clr"
    local bi=0; while [ "$bi" -lt "$n" ]; do printf "%s" "$ch"; bi=$(( bi + 1 )); done
    printf "   %b" "$R"
  fi
}

# print_bridge_end: trailing bridge — no trailing spaces, dashes fill to the edge
print_bridge_end() {
  local n="$1" ch="${2:-$BR_THIN}"
  local clr="${_bridge_color:-$C_MUTED}"
  [ "$n" -lt 1 ] && n=1
  if [ "$compact_level" -ge 3 ]; then
    printf "%$(( n + 3 ))s" ""
  else
    printf "   %b" "$clr"
    local bi=0; while [ "$bi" -lt "$n" ]; do printf "%s" "$ch"; bi=$(( bi + 1 )); done
    printf "%b" "$R"
  fi
}

# ==========================================================================
# Line 1: Brand + Version + Email
# Layout:  " ━━  ⬢ $model  [━━━ bridge ━━━]  version  [━━━]  CWD  ━  email  ━━"
# Solid colours: Emerald Lt for model/badge, jewel-tone bridges, Secondary for version.
# ==========================================================================
L1_PREFIX_LEN=7    # " ━━  ⬢ "

model_len=${#model}
dir_len=${#dir_display}

# Version display string
ver_str=""
ver_len=0
if [ -n "$ver_current" ]; then
  if [ -n "$ver_latest" ] && [ "$ver_current" != "$ver_latest" ]; then
    ver_str="v${ver_current} \xe2\x86\x92 ${ver_latest}"
    ver_len=$(( 1 + ${#ver_current} + 3 + ${#ver_latest} ))
  else
    ver_str="v${ver_current}"
    ver_len=$(( 1 + ${#ver_current} ))
  fi
fi

# Always show email (even "unknown")
email_len=${#claude_email}

# --- Effective COLS: ensure enough room for all columns + bridges ---
# L1 has its own layout; L2-L4 use the mx-based columns.
_l1_cw=$(( 7 + ${#model} + 4 + ${#dir_display} + 3 ))
[ "$ver_len" -gt 0 ] && _l1_cw=$(( _l1_cw + 3 + ver_len ))
[ "$email_len" -gt 0 ] && _l1_cw=$(( _l1_cw + 3 + email_len ))
# L2-L4 widest possible = all 5 columns + issue col6 on L4
_col_cw=$(( _content_through_c5 + mx5 ))
_l4_c6_w=0
[ -n "$issue_count" ] && [ "$issue_count" -gt 0 ] 2>/dev/null && _l4_c6_w=$(( 2 + ${#issue_count} + 7 ))
[ "$_l4_c6_w" -gt 0 ] && _col_cw=$(( _col_cw + 7 + _l4_c6_w ))
_min_cols="$_col_cw"
[ "$_l1_cw" -gt "$_min_cols" ] && _min_cols="$_l1_cw"
_min_cols=$(( _min_cols + BRIDGE_PAD + 1 ))
[ "$_min_cols" -gt "$COLS" ] && COLS="$_min_cols"

# L1 layout: " ━━  ⬢ model  ━━━━━━━━━  vX.Y.Z  ━━━━  CWD  ━  email  ━"
# Model section padded to mx1 so version aligns with col2 content on L2-L4.
_ver_display=""
_ver_display_len=0
if [ "$ver_len" -gt 0 ]; then
  _ver_display="v${ver_current}"
  _ver_display_len=${#_ver_display}
fi

# Bridge 1: model → version (pads to mx1, so version aligns with col2 content)
_l1_model_w=$(( L1_PREFIX_LEN + ${#model} ))
_bridge1_n=$(( mx1 - _l1_model_w + 1 ))
[ "$_bridge1_n" -lt 1 ] && _bridge1_n=1

# Remaining content after bridge2: CWD + bridge_email(7) + email
_l1_right_fixed=$(( dir_len + 7 + email_len ))
[ "$_ver_display_len" -gt 0 ] && _l1_right_fixed=$(( _l1_right_fixed + _ver_display_len ))

# Split remaining space between bridge2 and trailing bridge
_l1_total_fixed=$(( _l1_model_w + 6 + _bridge1_n + _l1_right_fixed ))
_l1_remaining=$(( COLS - _l1_total_fixed ))
# Bridge 2 gets remaining minus trailing bridge (trailing = " " + N dashes, minimum BRIDGE_PAD+1)
_bridge2_n=$(( _l1_remaining - 6 - BRIDGE_PAD - 1 ))
[ "$_bridge2_n" -lt 1 ] && _bridge2_n=1
# Trailing bridge: whatever bridge2 didn't consume
_l1_trail_n=$(( _l1_remaining - 6 - _bridge2_n - 1 ))
[ "$_l1_trail_n" -lt 1 ] && _l1_trail_n=1

# Build bridge strings
bridge1_str=""
bi=0; while [ "$bi" -lt "$_bridge1_n" ]; do bridge1_str="${bridge1_str}━"; bi=$(( bi + 1 )); done
bridge2_str=""
bi=0; while [ "$bi" -lt "$_bridge2_n" ]; do bridge2_str="${bridge2_str}━"; bi=$(( bi + 1 )); done

# Render Line 1 — solid colours with jewel-tone bridges
# Model + badge: Emerald Lt (brand identity)
printf "%b%b ━━  %b %s%b" "$BOLD" "$C_EMERALD_LT" "$model_badge" "$model" "$R"
# Bridge 1: model → version (jewel-tone thick dashes)
printf "   %b%s%b   " "$C_BR_L1" "$bridge1_str" "$R"
# Version
if [ "$_ver_display_len" -gt 0 ]; then
  printf "%b%s%b" "$C_SEC" "$_ver_display" "$R"
fi
# Bridge 2: version → CWD (different jewel tone segment)
_l1_br2_color="${JEWEL_COLORS_DIM[$(( (_jewel_seed / 5) % 9 ))]:-$C_MUTED}"
printf "   %b%s%b   " "$_l1_br2_color" "$bridge2_str" "$R"
# CWD
if [ -n "$repo_url" ]; then
  printf "%b" "$BOLD"
  osc8_link "$dir_display" "$repo_url"
  printf "%b" "$R"
else
  printf "%b%b%s%b" "$BOLD" "$C_JEWEL_L1" "$dir_display" "$R"
fi
# Bridge to email (thick to match L1 style)
_bridge_color="$C_MUTED"
print_bridge 1 "$BR_THICK"
# Email
printf "%b" "$C_ACCOUNT"
osc8_link "$claude_email" "https://console.anthropic.com"
printf "%b" "$R"
# Trailing bridge: fill remaining space with ━━━ in jewel tone
_l1_trail=""
bi=0; while [ "$bi" -lt "$_l1_trail_n" ]; do _l1_trail="${_l1_trail}━"; bi=$(( bi + 1 )); done
_l1_trail_color="${JEWEL_COLORS_DIM[$(( (_jewel_seed / 13) % 9 ))]:-$C_MUTED}"
printf " %b%s%b" "$_l1_trail_color" "$_l1_trail" "$R"

# ==========================================================================
# Line 2: Usage + Speed + Cost + Clock
# ==========================================================================
printf "\n"
_bridge_color="$C_BR_L2"

if [ -n "$five_h" ]; then
  five_h_marker=$(section_marker "$five_h" 50 75)
  printf "%b %s 5h   %b" "$five_h_color" "$five_h_marker" "$R"
  progress_bar "$five_h" 26 138 106 50 184 160 56 75 192 64 80
  printf "  %b%s%b" "$five_h_color" "$five_h_pct_str" "$R"
  if [ -n "$delta5" ] && [ "$compact_level" -lt 1 ]; then
    printf "  %b(%s)%b" "$five_h_color" "$delta5" "$R"
  fi
  # col1 → col2 bridge: formula = mx1 - my_col1_width + 1
  print_bridge $(( mx1 - five_h_sec_w + 1 ))
fi
if [ -n "$seven_d" ]; then
  seven_d_marker=$(section_marker "$seven_d" 50 75)
  printf "%b%s 7d   %b" "$seven_d_color" "$seven_d_marker" "$R"
  progress_bar "$seven_d" 160 164 184 50 184 160 56 75 192 64 80
  printf "  %b%s%b" "$seven_d_color" "$seven_d_pct_str" "$R"
  if [ -n "$delta7" ] && [ "$compact_level" -lt 1 ]; then
    printf "  %b(%s)%b" "$seven_d_color" "$delta7" "$R"
  fi
fi

if [ -n "${five_h}${seven_d}" ]; then
  # col2 → col3: speed
  print_bridge $(( mx2 - _l2_ml_w + 1 ))
  printf "%b%s%b" "$C_SEC" "$l2_speed_str" "$R"
  # col3 → col4: cost
  print_bridge $(( mx3 - _l2_mc_w + 1 ))
  printf "%b%s%b" "$C_BLONDE_LT" "$l2_cost_str" "$R"
  # col4 → col5: clock
  print_bridge $(( mx4 - _l2_mr_w + 1 ))
  printf "%b\xe2\x97\xb7 %s%b" "$C_MUTED" "$l2_clock_str" "$R"   # ◷ clock glyph
  # Trailing bridge: total = mx1+7 + mx2+7 + mx3+7 + mx4+7 + clock_w
  _l2_trail=$(( COLS - _content_through_c5 - _l2_c5_w - 3 ))
  [ "$_l2_trail" -gt 0 ] && print_bridge_end "$_l2_trail"
fi

# ==========================================================================
# Line 3: Context + Token Groups + Inbox
# ==========================================================================
printf "\n"
_bridge_color="$C_BR_L3"

# Token group display strings (compact_level 2+ collapses to totals)
token_group_str=""
token_group_w=0
if [ -n "$ctx_str" ]; then
  if [ "$compact_level" -ge 2 ]; then
    # Collapsed: "↓ Nk ┄ ↑ Nk"
    _in_grp_w=$(( 2 + ${#total_in_k} ))       # "↓ Nk"
    _out_grp_w=$(( 2 + ${#total_out_k} ))      # "↑ Nk"
  else
    # Full: "↓ (c ⧈ Nk  r □ Nk) ┄ ↑ (c ⧈ Nk  w □ Nk)"
    _in_grp_w=$(( 7 + ${#cache_read_in_k} + 6 + ${#raw_in_k} + 1 ))    # "↓ (c ⧈ " + Nk + "  r □ " + Nk + ")"
    _out_grp_w=$(( 7 + ${#cache_create_in_k} + 6 + ${#raw_out_k} + 1 ))  # "↑ (c ⧈ " + Nk + "  w □ " + Nk + ")"
  fi
  # Bridge between in and out uses formula: mx2 - _l3_ml_w + 1 + 6 = mx2 - _l3_ml_w + 7
  token_group_w=$(( _in_grp_w + (mx2 - _l3_ml_w) + 7 + _out_grp_w ))
fi

# L3 right cluster: inbox only (email moved to L1)
l3_right_w=0
if [ "$inbox_depth" -gt 0 ] 2>/dev/null; then
  l3_right_w=$(( 2 + ${#inbox_depth} ))   # "◇ N"
fi

# Handoff center width
handoff_center_w=0
[ "$handoff_warn" -eq 1 ] && handoff_center_w=13

if [ -n "$ctx_str" ]; then
  printf "%b %s ctx  %b" "$ctx_color" "$ctx_marker" "$R"
  progress_bar "$used_int" 30 136 152 50 200 120 56 80 192 64 80
  printf "  %b%s%b" "$ctx_color" "$ctx_pct_str" "$R"
  [ -n "$ctx_tokens_str" ] && printf "  %b(%s)%b" "$ctx_color" "$ctx_tokens_str" "$R"

  # col1 → col2: pad ctx to mx1
  print_bridge $(( mx1 - ctx_sec_w + 1 ))

  # Token groups: in → bridge → out
  if [ "$token_group_w" -gt 0 ]; then
    if [ "$compact_level" -ge 2 ]; then
      printf "%b\xe2\x86\x93 %s%b" "$C_TEAL" "$total_in_k" "$R"        # ↓ in
    else
      printf "%b\xe2\x86\x93 (c \xe2\xa7\x88 %s  r \xe2\x96\xa1 %s)%b" "$C_TEAL" "$cache_read_in_k" "$raw_in_k" "$R"   # ↓ (c ⧈ Nk  r □ Nk)
    fi
    # col2 → col3: pad in-tokens to mx2
    print_bridge $(( mx2 - _l3_ml_w + 1 ))
    if [ "$compact_level" -ge 2 ]; then
      printf "%b\xe2\x86\x91 %s%b" "$C_BLONDE_LT" "$total_out_k" "$R"  # ↑ out
    else
      printf "%b\xe2\x86\x91 (c \xe2\xa7\x88 %s  w \xe2\x96\xa1 %s)%b" "$C_BLONDE_LT" "$cache_create_in_k" "$raw_out_k" "$R"   # ↑ (c ⧈ Nk  w □ Nk)
    fi
  fi

  # col3 → col4: handoff
  print_bridge $(( mx3 - _l3_mc_w + 1 ))

  if [ "$handoff_warn" -eq 1 ]; then
    if [ "$badge_tick" -eq 0 ] && [ "$NO_COLOUR" -eq 0 ]; then
      printf "%b\xe2\xac\xa2 \xe2\x86\x92 handoff%b" "$C_WARN" "$R"
    elif [ "$badge_tick" -eq 0 ]; then
      printf "\xe2\xac\xa2 \xe2\x86\x92 handoff"
    elif [ "$NO_COLOUR" -eq 1 ]; then
      printf "\xe2\xac\xa1 \xe2\x86\x92 handoff"
    else
      printf "\033[38;2;110;96;34m\xe2\xac\xa1 \xe2\x86\x92 handoff%b" "$R"
    fi
  else
    printf "%b\xe2\x97\x87 no handoff%b" "$C_EMERALD_LT" "$R"   # ◇ no handoff
  fi

  # Trailing bridge: L3 stops at col4 (no col5)
  # total = mx1+7 + mx2+7 + mx3+7 + handoff_w
  _l3_total_w=$(( mx1 + 7 + mx2 + 7 + mx3 + 7 + _l3_mr_w ))
  _l3_trail=$(( COLS - _l3_total_w - l3_right_w - 3 ))
  [ "$_l3_trail" -gt 0 ] && print_bridge_end "$_l3_trail"

  # Right cluster: inbox
  if [ "$inbox_depth" -gt 0 ] 2>/dev/null; then
    printf "%b\xe2\x97\x87 %s%b" "$C_EMERALD_LT" "$inbox_depth" "$R"
  fi
fi

# ==========================================================================
# Line 4: Git + Worktree + Changes + Issues
# ==========================================================================
printf "\n"
_bridge_color="$C_BR_L4"

if [ -n "$branch" ]; then
  # Branch (⎇ U+2387 branching glyph)
  printf "%b \xe2\x8e\x87 %b" "$C_MUTED" "$R"
  printf "%b" "$BOLD"
  if [ -n "$repo_url" ]; then
    _branch_url="${repo_url}/tree/${branch}"
    printf "%b%b" "$BOLD" "$C_JEWEL_L4"
    osc8_link "$branch" "$_branch_url"
    printf "%b" "$R"
  else
    printf "%b%b%s%b" "$BOLD" "$C_JEWEL_L4" "$branch" "$R"
  fi

  # Unsynced commits
  if [ "$unsynced" -gt 0 ] 2>/dev/null; then
    printf "  %b\xe2\x86\x91%s%b" "$C_BLONDE_LT" "$unsynced" "$R"
  fi

  # col1 → col2: pad branch to mx1
  print_bridge $(( mx1 - _l4_left_w + 1 ))

  # Commit hash with glyph
  [ -n "$commit_hash" ] && printf "%b\xe2\x8a\x99 %s%b" "$C_MUTED" "$commit_hash" "$R"   # ⊙ hash

  # col2 → col3: changes (always shows +N -M)
  print_bridge $(( mx2 - _l4_ml_w + 1 ))
  if [ "$git_insertions" -gt 0 ] 2>/dev/null || [ "$git_deletions" -gt 0 ] 2>/dev/null; then
    [ "$git_insertions" -gt 0 ] 2>/dev/null && printf "%b+%s%b" "$C_GREEN" "$git_insertions" "$R"
    [ "$git_insertions" -gt 0 ] 2>/dev/null && [ "$git_deletions" -gt 0 ] 2>/dev/null && printf " "
    [ "$git_deletions" -gt 0 ] 2>/dev/null && printf "%b-%s%b" "$C_RED" "$git_deletions" "$R"
  else
    printf "%b+0 -0%b" "$C_MUTED" "$R"
  fi

  # col3 → col4: staged/unstaged — always show unstaged
  print_bridge $(( mx3 - _l4_mc_w + 1 ))
  [ "$staged_count" -gt 0 ] 2>/dev/null && printf "%b%s staged%b " "$C_GREEN" "$staged_count" "$R"
  printf "%b%s unstaged%b" "$C_ORANGE" "$unstaged_count" "$R"

  # Worktree name — bridged (extra, not part of column alignment)
  if [ -n "$worktree_name" ]; then
    print_bridge 1
    printf "%bworktree:%s%b" "$C_SEC" "$worktree_name" "$R"
  fi

  # col4 → col5: PR
  print_bridge $(( mx4 - _l4_mr_w + 1 ))
  if [ -n "$pr_number" ]; then
    _pr_display="PR #${pr_number}"
    [ -n "$pr_title" ] && _pr_display="PR #${pr_number}: ${pr_title}"
    if [ -n "$repo_url" ]; then
      printf "%b" "$C_TEAL"
      osc8_link "$_pr_display" "${repo_url}/pull/${pr_number}"
      printf "%b" "$R"
    else
      printf "%b%s%b" "$C_TEAL" "$_pr_display" "$R"
    fi
  else
    printf "%bno PR%b" "$C_MUTED" "$R"
  fi

  # col5 → col6: issues (L4 only, no alignment needed with other lines)
  if [ -n "$issue_count" ] && [ "$issue_count" -gt 0 ] 2>/dev/null; then
    print_bridge 1
    if [ -n "$repo_url" ]; then
      printf "%b" "$C_TEAL"
      osc8_link "◈ ${issue_count} issues" "${repo_url}/issues"
      printf "%b" "$R"
    else
      printf "%b◈ %s issues%b" "$C_TEAL" "$issue_count" "$R"
    fi
  fi

  # Trailing bridge: total = mx1+7 + mx2+7 + mx3+7 + mx4+7 + PR_w + optional(7 + issues_w)
  _l4_total_w=$(( _content_through_c5 + _l4_c5_w ))
  if [ -n "$worktree_name" ]; then
    _l4_total_w=$(( _l4_total_w + 7 + 9 + ${#worktree_name} ))
  fi
  if [ -n "$issue_count" ] && [ "$issue_count" -gt 0 ] 2>/dev/null; then
    _l4_total_w=$(( _l4_total_w + 7 + 2 + ${#issue_count} + 7 ))
  fi
  _l4_trail=$(( COLS - _l4_total_w - 3 ))
  [ "$_l4_trail" -gt 0 ] && print_bridge_end "$_l4_trail"
fi
