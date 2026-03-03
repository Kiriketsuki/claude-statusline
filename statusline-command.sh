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
# NO_COLOR (https://no-color.org/): when set and non-zero, disable all ANSI colour
if [ -n "${NO_COLOR-}" ] && [ "${NO_COLOR}" != "0" ]; then
  NO_COLOUR=1
else
  NO_COLOUR=0
fi
# CHRYSAKI_NO_ANIMATE: when set and non-zero, freeze all animation phases
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

# --- git branch + unsynced ---
branch=""
unsynced=0
if [ -d "${dir}/.git" ] || git -C "$dir" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$dir" rev-parse --short HEAD 2>/dev/null)
  unsynced=$(git -C "$dir" log '@{u}..HEAD' --oneline 2>/dev/null | wc -l | tr -d ' ')
fi

# --- stats cache (issues, per-repo) ---
issue_count=""
remote=$(git -C "$dir" remote get-url origin 2>/dev/null)
if [ -n "$remote" ]; then
  repo_slug=$(echo "$remote" | sed 's|.*github.com[:/]||' | sed 's|\.git$||' | tr '/' '_')
  STATS_CACHE="/tmp/.claude_stats_cache_${repo_slug}"
  [ -f "$STATS_CACHE" ] && issue_count=$(sed -n '1p' "$STATS_CACHE")
fi

# --- inbox depth (obKidian only) ---
inbox_depth=0
SCRATCH="$dir/001-Inbox/Scratch Book.md"
if [ -f "$SCRATCH" ]; then
  inbox_depth=$(awk '/^## Ramblings/{found=1; next} /^## /{found=0} found && /^- /{c++} END{print c+0}' "$SCRATCH")
fi

# --- usage stats (5h / 7d) from cache ---
CACHE_FILE="/tmp/.claude_usage_cache"
five_h=""
seven_d=""
five_h_reset=""
seven_d_reset=""
if [ -f "$CACHE_FILE" ]; then
  five_h=$(sed -n '1p' "$CACHE_FILE")
  seven_d=$(sed -n '2p' "$CACHE_FILE")
  five_h_reset=$(sed -n '3p' "$CACHE_FILE")
  seven_d_reset=$(sed -n '4p' "$CACHE_FILE")
else
  bash ~/.claude/statusline/fetch-usage.sh > /dev/null 2>&1 &
fi

# --- compute_delta: ISO timestamp -> human-readable time until reset ---
compute_delta() {
  local clean reset_epoch now_epoch diff days hours minutes
  clean=$(echo "$1" | sed 's/\.[0-9]*//' | sed 's/[+-][0-9][0-9]:[0-9][0-9]$//' | sed 's/Z$//')
  reset_epoch=$(TZ=UTC date -d "$clean" "+%s" 2>/dev/null)
  if [ -z "$reset_epoch" ]; then
    reset_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null)
  fi
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

# --- gradient_text: Chrysaki Jewel animated gradient (left-to-right flow) ---
# 4-stop seamless loop: Emerald Lt -> Royal Blue Lt -> Amethyst Lt -> Royal Blue Lt -> Emerald Lt
# Characters span 200 of the 400-unit cycle; phase shifts the window each render.
# grad_phase must be set before calling. Caller must reset when done.
gradient_text() {
  local text="$1" len i t s r g b span
  len="${#text}"
  [ "$len" -eq 0 ] && return
  if [ "$NO_COLOUR" -eq 1 ]; then printf "%s" "$text"; return; fi
  local r1=26  g1=138 b1=106   # #1a8a6a Emerald Lt
  local r2=28  g2=61  b2=122   # #1c3d7a Royal Blue Lt
  local r3=88  g3=48  b3=144   # #583090 Amethyst Lt
  span=$(( len > 1 ? len - 1 : 1 ))
  i=0
  while [ "$i" -lt "$len" ]; do
    t=$(( (i * 200 / span + grad_phase) % 400 ))
    if [ "$t" -lt 100 ]; then
      r=$(( r1 + (r2 - r1) * t / 100 )); g=$(( g1 + (g2 - g1) * t / 100 )); b=$(( b1 + (b2 - b1) * t / 100 ))
    elif [ "$t" -lt 200 ]; then
      s=$(( t - 100 ))
      r=$(( r2 + (r3 - r2) * s / 100 )); g=$(( g2 + (g3 - g2) * s / 100 )); b=$(( b2 + (b3 - b2) * s / 100 ))
    elif [ "$t" -lt 300 ]; then
      s=$(( t - 200 ))
      r=$(( r3 + (r2 - r3) * s / 100 )); g=$(( g3 + (g2 - g3) * s / 100 )); b=$(( b3 + (b2 - b3) * s / 100 ))
    else
      s=$(( t - 300 ))
      r=$(( r2 + (r1 - r2) * s / 100 )); g=$(( g2 + (g1 - g2) * s / 100 )); b=$(( b2 + (b1 - b2) * s / 100 ))
    fi
    printf "\033[38;2;%d;%d;%dm%s" "$r" "$g" "$b" "${text:$i:1}"
    i=$(( i + 1 ))
  done
}

# --- gradient_text_off: continuous gradient across multiple Line-1 segments ---
# OFFSET: absolute char position within the full gradient span
# TOTAL:  total gradient chars on the line (determines scale)
gradient_text_off() {
  local text="$1" offset="$2" total="$3"
  local len i t s r g b span
  len="${#text}"
  [ "$len" -eq 0 ] && return
  if [ "$NO_COLOUR" -eq 1 ]; then printf "%s" "$text"; return; fi
  local r1=26  g1=138 b1=106
  local r2=28  g2=61  b2=122
  local r3=88  g3=48  b3=144
  [ "$total" -le 1 ] && total=2
  span=$(( total - 1 ))
  i=0
  while [ "$i" -lt "$len" ]; do
    t=$(( ((offset + i) * 200 / span + grad_phase) % 400 ))
    if [ "$t" -lt 100 ]; then
      r=$(( r1 + (r2 - r1) * t / 100 )); g=$(( g1 + (g2 - g1) * t / 100 )); b=$(( b1 + (b2 - b1) * t / 100 ))
    elif [ "$t" -lt 200 ]; then
      s=$(( t - 100 ))
      r=$(( r2 + (r3 - r2) * s / 100 )); g=$(( g2 + (g3 - g2) * s / 100 )); b=$(( b2 + (b3 - b2) * s / 100 ))
    elif [ "$t" -lt 300 ]; then
      s=$(( t - 200 ))
      r=$(( r3 + (r2 - r3) * s / 100 )); g=$(( g3 + (g2 - g3) * s / 100 )); b=$(( b3 + (b2 - b3) * s / 100 ))
    else
      s=$(( t - 300 ))
      r=$(( r2 + (r1 - r2) * s / 100 )); g=$(( g2 + (g1 - g2) * s / 100 )); b=$(( b2 + (b1 - b2) * s / 100 ))
    fi
    printf "\033[38;2;%d;%d;%dm%s" "$r" "$g" "$b" "${text:$i:1}"
    i=$(( i + 1 ))
  done
}

# --- progress_bar: 8-position progress bar with threshold colours and configurable shape ---
# Usage: progress_bar PERCENT NR NG NB WARN_T WR WG WB CRIT_T CR CG CB
# Shape controlled by CHRYSAKI_BAR_STYLE env var (default: hex).
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
    case "${BAR_STYLE:-hex}" in
      diamond)
        if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x97\x86" "$cfill"           # ◆
        else printf "%b\xe2\x97\x87" "$C_HEX_EMPTY"; fi ;;                          # ◇
      circle)
        if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x97\x8f" "$cfill"           # ●
        else printf "%b\xe2\x97\x8b" "$C_HEX_EMPTY"; fi ;;                          # ○
      wave)
        # Alternating ▲▼ tiling trapezoid effect.
        # wave_shift (global, 0-3) creates 4-phase scroll for smoother motion.
        # wpos % 2 selects glyph: 0 = up triangle, 1 = down triangle.
        local wpos=$(( (i + wave_shift) % 4 ))
        if [ $(( wpos % 2 )) -eq 0 ]; then
          if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x96\xb2" "$cfill"         # ▲ bright
          else printf "%b\xe2\x96\xb2" "$C_HEX_EMPTY"; fi                           # ▲ dim
        else
          if [ "$i" -lt "$filled" ]; then printf "%s\xe2\x96\xbc" "$cfill"         # ▼ bright
          else printf "%b\xe2\x96\xbc" "$C_HEX_EMPTY"; fi                           # ▼ dim
        fi ;;
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

# --- Chrysaki colour palette ---
if [ "$NO_COLOUR" -eq 1 ]; then
  R="" DIM="" BOLD=""
  C_BLONDE_LT="" C_TEAL="" C_EMERALD_LT="" C_ORANGE=""
  C_SEC="" C_MUTED="" C_WARN="" C_ERROR="" C_HEX_EMPTY=""
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

# --- animation phase (shared across all gradient_text calls this render) ---
# 6 units/second, 400-unit full cycle ~67s.
if [ "$CHRYSAKI_NO_ANIMATE" != "0" ]; then
  grad_phase=0
  wave_shift=0
  badge_tick=0
else
  grad_phase=$(( ($(date +%s) * 6) % 400 ))
  wave_shift=$(( ($(date +%s) / 2) % 4 ))   # 0-3, 4-phase wave scroll for smoother motion
fi

# --- threshold pulse: sine-wave brightness modulation for warning/critical sections ---
# 8-step sine lookup (scaled -100..+100); 1 step/sec = ~8s full cycle
sine8=(0 71 100 71 0 -71 -100 -71)
if [ "$CHRYSAKI_NO_ANIMATE" != "0" ]; then
  pulse_scale=100
else
  pulse_idx=$(( $(date +%s) % 8 ))
  pulse_scale=$(( 85 + 15 * ${sine8[$pulse_idx]} / 100 ))   # range ~70-100
fi

# pulse_color: apply pulse_scale to an RGB colour, emit ANSI escape
# Usage: pulse_color R G B -> prints \033[38;2;r;g;bm (scaled)
pulse_color() {
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
COLS=$(tput cols 2>/dev/null || echo 80)

# --- bar style (override via CHRYSAKI_BAR_STYLE env var) ---
BAR_STYLE="${CHRYSAKI_BAR_STYLE:-wave}"

# Pre-compute deltas and section widths for cross-line | alignment
delta5="" delta7=""
[ -n "$five_h_reset" ] && delta5=$(compute_delta "$five_h_reset")
[ -n "$seven_d_reset" ] && delta7=$(compute_delta "$seven_d_reset")

five_h_sec_w=0
if [ -n "$five_h" ]; then
  five_h_pct_str=$(printf "%2d%%" "$five_h")
  five_h_sec_w=$(( 8 + 8 + 2 + ${#five_h_pct_str} ))
  [ -n "$delta5" ] && five_h_sec_w=$(( five_h_sec_w + 2 + 1 + ${#delta5} + 1 ))
fi

ctx_sec_w=0
if [ -n "$ctx_str" ]; then
  ctx_pct_str=$(printf "%2d%%" "$used_int")
  ctx_sec_w=$(( 8 + 8 + 2 + ${#ctx_pct_str} ))
  [ -n "$ctx_tokens_str" ] && ctx_sec_w=$(( ctx_sec_w + 2 + 1 + ${#ctx_tokens_str} + 1 ))
fi

if   [ "$five_h_sec_w" -gt 0 ] && [ "$ctx_sec_w" -gt 0 ]; then
  first_w=$(( five_h_sec_w > ctx_sec_w ? five_h_sec_w : ctx_sec_w ))
elif [ "$five_h_sec_w" -gt 0 ]; then first_w="$five_h_sec_w"
elif [ "$ctx_sec_w"    -gt 0 ]; then first_w="$ctx_sec_w"
else                                  first_w=0
fi

# --- model badge: shape encodes model tier, pulses solid/outline every 2 seconds ---
# Haiku = ▲/△ (triangle, 3)  Sonnet = ⬟/⬠ (pentagon, 5)  Opus = ⬢/⬡ (hexagon, 6)
# badge_tick already set in animation-phase block (frozen or live)
[ -z "$badge_tick" ] && badge_tick=$(( ($(date +%s) / 2) % 2 ))
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

# ==========================================================================
# Line 1: Brand Bar
# Layout:  " ━━  ⬢ $model  [━━━ bridge ━━━]  $dir  ◆  $branch ↑N  ━━"
# Gradient flows continuously across all ━ and text segments.
# Fixed display-column widths (Unicode chars counted as 1 col each):
#   prefix " ━━  ⬢ " = 7   bridge-pad "  " + "  " = 4   suffix " ━━" = 3
#   sep " ◆ " = 3 (muted, not in gradient)
# ==========================================================================
L1_PREFIX_LEN=7
L1_SUFFIX_LEN=3
L1_SEP_LEN=3
L1_BRIDGE_PAD=4

model_len=${#model}
dir_len=${#dir_display}    # use smart CWD display length

if [ -n "$branch" ]; then
  branch_len=${#branch}
  if [ "$unsynced" -gt 0 ] 2>/dev/null; then
    unsync_display_len=$(( 2 + ${#unsynced} ))   # " ↑" + digit(s)
  else
    unsync_display_len=0
  fi
  total_fixed=$(( L1_PREFIX_LEN + model_len + L1_BRIDGE_PAD + dir_len + L1_SEP_LEN + branch_len + unsync_display_len + L1_SUFFIX_LEN ))
else
  branch_len=0
  unsync_display_len=0
  total_fixed=$(( L1_PREFIX_LEN + model_len + L1_BRIDGE_PAD + dir_len + L1_SUFFIX_LEN ))
fi

bridge_n=$(( COLS - total_fixed ))
[ "$bridge_n" -lt 1 ] && bridge_n=1

# Total gradient chars (determines scale for continuous gradient)
if [ -n "$branch" ]; then
  total_grad=$(( L1_PREFIX_LEN + model_len + L1_BRIDGE_PAD + bridge_n + dir_len + branch_len + L1_SUFFIX_LEN ))
else
  total_grad=$(( L1_PREFIX_LEN + model_len + L1_BRIDGE_PAD + bridge_n + dir_len + L1_SUFFIX_LEN ))
fi
[ "$total_grad" -le 1 ] && total_grad=2

# Build bridge string
bridge_str=""
bi=0
while [ "$bi" -lt "$bridge_n" ]; do
  bridge_str="${bridge_str}━"
  bi=$(( bi + 1 ))
done

# Render Line 1 with continuous gradient flowing across all segments
printf "%b" "$BOLD"
goff=0
l1_prefix=$(printf " ━━  %b " "$model_badge")   # dynamic badge, still 7 display cols
gradient_text_off "$l1_prefix" "$goff" "$total_grad";   goff=$(( goff + L1_PREFIX_LEN ))
gradient_text_off "$model"   "$goff" "$total_grad";      goff=$(( goff + model_len ))
gradient_text_off "  "       "$goff" "$total_grad";      goff=$(( goff + 2 ))
gradient_text_off "$bridge_str" "$goff" "$total_grad";   goff=$(( goff + bridge_n ))
gradient_text_off "  "       "$goff" "$total_grad";      goff=$(( goff + 2 ))
gradient_text_off "$dir_display" "$goff" "$total_grad";  goff=$(( goff + dir_len ))
printf "%b" "$R"

if [ -n "$branch" ]; then
  printf "%b \xe2\x97\x86 %b" "$C_MUTED" "$R"          # muted ◆ separator
  printf "%b" "$BOLD"
  gradient_text_off "$branch" "$goff" "$total_grad";    goff=$(( goff + branch_len ))
  printf "%b" "$R"
  if [ "$unsynced" -gt 0 ] 2>/dev/null; then
    printf "%b \xe2\x86\x91%s%b" "$C_BLONDE_LT" "$unsynced" "$R"   # ↑N
  fi
fi

printf "%b" "$BOLD"
gradient_text_off " ━━" "$goff" "$total_grad"
printf "%b" "$R"

# Muted vertical divider used between all sections on lines 2 and 3
# "  │  " = 2 spaces + │ (U+2502) + 2 spaces, rendered in muted colour
DIV="  %b\xe2\x94\x82%b  "   # printf template: pass C_MUTED and R as args

# ==========================================================================
# Line 2: Usage Metrics
# Layout:  " ▰ 5h   [bar]  27%  (3h 59m)  [pad]  │  ▰ 7d   [bar]  52%  (4d 18h)"
# First section padded to first_w (max of 5h/ctx section widths) for │ alignment.
# Delta and percentage use the same colour as the section's usage indicator.
# ==========================================================================
printf "\n"
if [ -n "$five_h" ]; then
  five_h_marker=$(section_marker "$five_h" 50 75)
  printf "%b %s 5h   %b" "$five_h_color" "$five_h_marker" "$R"
  progress_bar "$five_h" 26 138 106 50 184 160 56 75 192 64 80
  printf "  %b%s%b" "$five_h_color" "$five_h_pct_str" "$R"
  [ -n "$delta5" ] && printf "  %b(%s)%b" "$five_h_color" "$delta5" "$R"
  five_h_pad=$(( first_w - five_h_sec_w ))
  [ "$five_h_pad" -gt 0 ] && printf "%*s" "$five_h_pad" ""
fi
if [ -n "$seven_d" ]; then
  [ -n "$five_h" ] && printf "$DIV" "$C_MUTED" "$R"
  seven_d_marker=$(section_marker "$seven_d" 50 75)
  printf "%b %s 7d   %b" "$seven_d_color" "$seven_d_marker" "$R"
  progress_bar "$seven_d" 160 164 184 50 184 160 56 75 192 64 80
  printf "  %b%2d%%%b" "$seven_d_color" "$seven_d" "$R"
  [ -n "$delta7" ] && printf "  %b(%s)%b" "$seven_d_color" "$delta7" "$R"
fi

# ==========================================================================
# Line 3: Context + Status
# Layout:  " ▰ ctx  [bar]  77%  (154k/200k)  [pad]  │  [⬢→handoff]  │  v2.1.63  │  ◈ N  │  ◇ N"
# ctx section padded to first_w; all right-side elements share │ dividers.
# ==========================================================================
printf "\n"
if [ -n "$ctx_str" ]; then
  printf "%b %s ctx  %b" "$ctx_color" "$ctx_marker" "$R"
  progress_bar "$used_int" 30 136 152 50 200 120 56 80 192 64 80
  printf "  %b%s%b" "$ctx_color" "$ctx_pct_str" "$R"
  [ -n "$ctx_tokens_str" ] && printf "  %b(%s)%b" "$ctx_color" "$ctx_tokens_str" "$R"
  ctx_pad=$(( first_w - ctx_sec_w ))
  [ "$ctx_pad" -gt 0 ] && printf "%*s" "$ctx_pad" ""
  if [ "$handoff_warn" -eq 1 ]; then
    printf "$DIV" "$C_MUTED" "$R"
    # Handoff beacon: alternates solid/outline hexagon + bright/dim every 2s
    if [ "$badge_tick" -eq 0 ]; then
      printf "%b\xe2\xac\xa2 \xe2\x86\x92 handoff%b" "$C_WARN" "$R"             # ⬢ solid, bright
    elif [ "$NO_COLOUR" -eq 1 ]; then
      printf "\xe2\xac\xa1 \xe2\x86\x92 handoff"                                 # ⬡ outline, no colour
    else
      printf "\033[38;2;110;96;34m\xe2\xac\xa1 \xe2\x86\x92 handoff%b" "$R"      # ⬡ outline, dim
    fi
  fi
  if [ -n "$ver_current" ]; then
    printf "$DIV" "$C_MUTED" "$R"
    if [ -n "$ver_latest" ] && [ "$ver_current" != "$ver_latest" ]; then
      printf "%bv%s \xe2\x86\x92 %s%b" "$C_WARN" "$ver_current" "$ver_latest" "$R"
    else
      printf "%bv%s%b" "$C_MUTED" "$ver_current" "$R"
    fi
  fi
  if [ -n "$issue_count" ] && [ "$issue_count" -gt 0 ] 2>/dev/null; then
    printf "$DIV" "$C_MUTED" "$R"
    printf "%b\xe2\x97\x88 issues: %s%b" "$C_TEAL" "$issue_count" "$R"
  fi
  if [ "$inbox_depth" -gt 0 ] 2>/dev/null; then
    printf "$DIV" "$C_MUTED" "$R"
    printf "%b\xe2\x97\x87 inbox: %s%b" "$C_EMERALD_LT" "$inbox_depth" "$R"
  fi
fi
