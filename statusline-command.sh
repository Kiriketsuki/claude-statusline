#!/usr/bin/env bash
# Platform-specific PATH augmentation
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    # Windows Git Bash: ensure WinGet-installed tools (jq, etc.) are on PATH
    WINGET_LINKS="/c/Users/Kidriel/AppData/Local/Microsoft/WinGet/Links"
    [ -d "$WINGET_LINKS" ] && export PATH="$PATH:$WINGET_LINKS"
    ;;
esac

input=$(cat)

# --- model ---
model=$(echo "$input" | jq -r '.model.display_name // ""')

# --- folder ---
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir_name=$(basename "$dir")

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

  i=0
  while [ "$i" -lt 8 ]; do
    case "${BAR_STYLE:-hex}" in
      diamond)
        if [ "$i" -lt "$filled" ]; then printf "\033[38;2;%d;%d;%dm\xe2\x97\x86" "$fr" "$fg" "$fb"   # ◆
        else printf "%b\xe2\x97\x87" "$C_HEX_EMPTY"; fi ;;                                             # ◇
      circle)
        if [ "$i" -lt "$filled" ]; then printf "\033[38;2;%d;%d;%dm\xe2\x97\x8f" "$fr" "$fg" "$fb"   # ●
        else printf "%b\xe2\x97\x8b" "$C_HEX_EMPTY"; fi ;;                                             # ○
      wave)
        # Alternating ▲▼ / △▽ creates tiling trapezoid / triangle effect
        if [ $(( i % 2 )) -eq 0 ]; then
          if [ "$i" -lt "$filled" ]; then printf "\033[38;2;%d;%d;%dm\xe2\x96\xb2" "$fr" "$fg" "$fb"  # ▲
          else printf "%b\xe2\x96\xb3" "$C_HEX_EMPTY"; fi                                              # △
        else
          if [ "$i" -lt "$filled" ]; then printf "\033[38;2;%d;%d;%dm\xe2\x96\xbc" "$fr" "$fg" "$fb"  # ▼
          else printf "%b\xe2\x96\xbd" "$C_HEX_EMPTY"; fi                                              # ▽
        fi ;;
      block)
        if [ "$i" -lt "$filled" ]; then printf "\033[38;2;%d;%d;%dm\xe2\x96\x88" "$fr" "$fg" "$fb"   # █
        else printf "%b\xe2\x96\x91" "$C_HEX_EMPTY"; fi ;;                                             # ░
      *)  # hex (default)
        if [ "$i" -lt "$filled" ]; then printf "\033[38;2;%d;%d;%dm\xe2\xac\xa2" "$fr" "$fg" "$fb"   # ⬢
        else printf "%b\xe2\xac\xa1" "$C_HEX_EMPTY"; fi ;;                                             # ⬡
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
five_h_color="$C_EMERALD_LT"
if [ -n "$five_h" ]; then
  if   [ "$five_h" -ge 75 ] 2>/dev/null; then five_h_color="$C_ERROR"
  elif [ "$five_h" -ge 50 ] 2>/dev/null; then five_h_color="$C_WARN"
  fi
fi

# 7d usage: Secondary (normal) / Blonde (>=50%) / Ruby (>=75%)
seven_d_color="$C_SEC"
if [ -n "$seven_d" ]; then
  if   [ "$seven_d" -ge 75 ] 2>/dev/null; then seven_d_color="$C_ERROR"
  elif [ "$seven_d" -ge 50 ] 2>/dev/null; then seven_d_color="$C_WARN"
  fi
fi

# --- animation phase (shared across all gradient_text calls this render) ---
# 6 units/second, 400-unit full cycle ~67s.
grad_phase=$(( ($(date +%s) * 6) % 400 ))

# --- terminal width ---
COLS=$(tput cols 2>/dev/null || echo 80)

# --- bar style (override via CHRYSAKI_BAR_STYLE env var) ---
BAR_STYLE="${CHRYSAKI_BAR_STYLE:-wave}"

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
dir_len=${#dir_name}

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
gradient_text_off " ━━  ⬢ " "$goff" "$total_grad";     goff=$(( goff + L1_PREFIX_LEN ))
gradient_text_off "$model"   "$goff" "$total_grad";     goff=$(( goff + model_len ))
gradient_text_off "  "       "$goff" "$total_grad";     goff=$(( goff + 2 ))
gradient_text_off "$bridge_str" "$goff" "$total_grad";  goff=$(( goff + bridge_n ))
gradient_text_off "  "       "$goff" "$total_grad";     goff=$(( goff + 2 ))
gradient_text_off "$dir_name" "$goff" "$total_grad";    goff=$(( goff + dir_len ))
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

# ==========================================================================
# Line 2: Usage Metrics
# Layout:  " ▰ 5h   [bar] %2d%  (delta)    ▰ 7d   [bar] %2d%  (delta)"
# Label field is 3 chars wide (5h→"5h ", 7d→"7d ", ctx→"ctx") so all
# progress bars start in the same terminal column across lines 2 and 3.
# ==========================================================================
printf "\n"
if [ -n "$five_h" ]; then
  five_h_marker=$(section_marker "$five_h" 50 75)
  printf "%b %s 5h   %b" "$five_h_color" "$five_h_marker" "$R"
  progress_bar "$five_h" 26 138 106 50 184 160 56 75 192 64 80
  printf " %b%2d%%%b" "$five_h_color" "$five_h" "$R"
  if [ -n "$five_h_reset" ]; then
    delta=$(compute_delta "$five_h_reset")
    [ -n "$delta" ] && printf " %b%b(%s)%b" "$DIM" "$C_MUTED" "$delta" "$R"
  fi
fi
if [ -n "$seven_d" ]; then
  [ -n "$five_h" ] && printf "    "
  seven_d_marker=$(section_marker "$seven_d" 50 75)
  printf "%b %s 7d   %b" "$seven_d_color" "$seven_d_marker" "$R"
  progress_bar "$seven_d" 160 164 184 50 184 160 56 75 192 64 80
  printf " %b%2d%%%b" "$seven_d_color" "$seven_d" "$R"
  if [ -n "$seven_d_reset" ]; then
    delta=$(compute_delta "$seven_d_reset")
    [ -n "$delta" ] && printf " %b%b(%s)%b" "$DIM" "$C_MUTED" "$delta" "$R"
  fi
fi

# ==========================================================================
# Line 3: Context + Status
# Layout:  " ▰ ctx  [bar] %2d%  (tokens)    ◈ issues: N    ◇ inbox: N"
# ==========================================================================
printf "\n"
if [ -n "$ctx_str" ]; then
  printf "%b %s ctx  %b" "$ctx_color" "$ctx_marker" "$R"
  progress_bar "$used_int" 30 136 152 50 200 120 56 80 192 64 80
  printf " %b%2d%%%b" "$ctx_color" "$used_int" "$R"
  [ -n "$ctx_tokens_str" ] && printf " %b%b(%s)%b" "$DIM" "$C_MUTED" "$ctx_tokens_str" "$R"
  if [ "$handoff_warn" -eq 1 ]; then
    printf " %b\xe2\xac\xa2 \xe2\x86\x92 handoff soon%b" "$C_WARN" "$R"   # ⬢ → handoff soon
  fi
fi
if [ -n "$issue_count" ] && [ "$issue_count" -gt 0 ] 2>/dev/null; then
  printf "    %b\xe2\x97\x88 issues: %s%b" "$C_TEAL" "$issue_count" "$R"        # ◈
fi
if [ "$inbox_depth" -gt 0 ] 2>/dev/null; then
  printf "    %b\xe2\x97\x87 inbox: %s%b" "$C_EMERALD_LT" "$inbox_depth" "$R"  # ◇
fi
