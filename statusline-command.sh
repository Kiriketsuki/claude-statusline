#!/bin/sh
# Ensure winget-installed tools (jq) are on PATH in non-interactive shells
[ -d "/c/Users/Kidriel/AppData/Local/Microsoft/WinGet/Links" ] && export PATH="$PATH:/c/Users/Kidriel/AppData/Local/Microsoft/WinGet/Links"
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

# --- inbox depth (obKidian only: only present when $dir is the vault) ---
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
  clean=$(echo "$1" | sed 's/\.[0-9]*//' | sed 's/[+-][0-9][0-9]:[0-9][0-9]$//' | sed 's/Z$//')
  reset_epoch=$(TZ=UTC date -d "$clean" "+%s" 2>/dev/null)
  if [ -z "$reset_epoch" ]; then
    reset_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null)
  fi
  if [ -z "$reset_epoch" ]; then return; fi
  now_epoch=$(date -u "+%s")
  diff=$(( reset_epoch - now_epoch ))
  if [ "$diff" -le 0 ]; then echo "now"; return; fi
  days=$(( diff / 86400 ))
  hours=$(( (diff % 86400) / 3600 ))
  minutes=$(( (diff % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then
    echo "${days}d ${hours}h"
  elif [ "$hours" -gt 0 ]; then
    echo "${hours}h ${minutes}m"
  else
    echo "${minutes}m"
  fi
}

# --- gradient_text: Chrysaki Jewel animated gradient (left-to-right flow) ---
# 4-stop seamless loop: Emerald Lt -> Royal Blue Lt -> Amethyst Lt -> Royal Blue Lt -> Emerald Lt
# Characters span 200 of the 400-unit cycle; phase shifts the window each render.
# Compute grad_phase once before calling (shared across all fields for in-sync animation).
# Full cycle: 400 units / 6 units per second ≈ 67s. Colors flow left-to-right.
# To reverse direction: replace (... + grad_phase) with (... + 400 - grad_phase).
# Caller must reset (\033[0m) when done.
gradient_text() {
  local text="$1"
  local len="${#text}"
  [ "$len" -eq 0 ] && return
  local r1=26  g1=138 b1=106   # #1a8a6a Emerald Lt
  local r2=28  g2=61  b2=122   # #1c3d7a Royal Blue Lt
  local r3=88  g3=48  b3=144   # #583090 Amethyst Lt
  local span=$(( len > 1 ? len - 1 : 1 ))
  local i=0 t s r g b
  while [ "$i" -lt "$len" ]; do
    t=$(( (i * 200 / span + grad_phase) % 400 ))
    if [ "$t" -lt 100 ]; then
      # Emerald Lt -> Royal Blue Lt
      r=$(( r1 + (r2 - r1) * t / 100 ))
      g=$(( g1 + (g2 - g1) * t / 100 ))
      b=$(( b1 + (b2 - b1) * t / 100 ))
    elif [ "$t" -lt 200 ]; then
      # Royal Blue Lt -> Amethyst Lt
      s=$(( t - 100 ))
      r=$(( r2 + (r3 - r2) * s / 100 ))
      g=$(( g2 + (g3 - g2) * s / 100 ))
      b=$(( b2 + (b3 - b2) * s / 100 ))
    elif [ "$t" -lt 300 ]; then
      # Amethyst Lt -> Royal Blue Lt
      s=$(( t - 200 ))
      r=$(( r3 + (r2 - r3) * s / 100 ))
      g=$(( g3 + (g2 - g3) * s / 100 ))
      b=$(( b3 + (b2 - b3) * s / 100 ))
    else
      # Royal Blue Lt -> Emerald Lt
      s=$(( t - 300 ))
      r=$(( r2 + (r1 - r2) * s / 100 ))
      g=$(( g2 + (g1 - g2) * s / 100 ))
      b=$(( b2 + (b1 - b2) * s / 100 ))
    fi
    printf "\033[38;2;%d;%d;%dm%s" "$r" "$g" "$b" "${text:$i:1}"
    i=$(( i + 1 ))
  done
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
  ctx_used=$(echo "$input" | jq -r '(.context_window.current_usage.cache_read_input_tokens + .context_window.current_usage.cache_creation_input_tokens + .context_window.current_usage.input_tokens + .context_window.current_usage.output_tokens) // empty' 2>/dev/null)
  ctx_total=$(echo "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
  if [ -n "$ctx_used" ] && [ -n "$ctx_total" ]; then
    ctx_used_k=$(( ctx_used / 1000 ))
    ctx_total_k=$(( ctx_total / 1000 ))
    ctx_tokens_str="${ctx_used_k}k/${ctx_total_k}k"
  fi
fi

# --- Chrysaki colour palette ---
# Escape codes stored as variables; used in printf format strings (shell expands before printf sees \033).
R="\033[0m"                              # reset
DIM="\033[2m"
BOLD="\033[1m"
NOBOLD="\033[22m"

# Static identity colours
C_ORANGE="\033[38;5;208m"               # Terminal orange         -- model name
C_TEAL_LT="\033[38;2;42;170;184m"       # #2aaab8 Teal Light      -- folder / navigation
C_PURPLE="\033[38;2;192;103;222m"       # Display purple*         -- branch (* brighter than Chrysaki Amethyst Lt for terminal readability)
C_BLONDE_LT="\033[38;2;208;184;80m"    # #d0b850 Blonde Light     -- unsynced commits
C_TEAL="\033[38;2;30;136;152m"          # #1e8898 Teal             -- issue count
C_EMERALD_LT="\033[38;2;26;138;106m"   # #1a8a6a Emerald Light    -- inbox depth

# Text hierarchy
C_PRI="\033[38;2;224;226;234m"          # #e0e2ea Primary text     -- (reserved, not used inline yet)
C_SEC="\033[38;2;160;164;184m"          # #a0a4b8 Secondary text   -- 7d, normal stats
C_MUTED="\033[38;2;106;110;130m"        # #6a6e82 Muted text       -- separators, reset timers

# Alert thresholds (Chrysaki semantic)
C_WARN="\033[38;2;184;160;56m"          # #b8a038 Blonde           -- 50% 5h usage warning
C_ERROR="\033[38;2;192;64;80m"          # #c04050 Error            -- 75% 5h / 128k ctx critical

# --- threshold colour logic ---
# ctx: orange >= 50%, red >= 128k tokens absolute
ctx_color="$C_SEC"
if [ -n "$ctx_used" ] && [ "$ctx_used" -ge 128000 ] 2>/dev/null; then
  ctx_color="$C_ERROR"
elif [ -n "$used_int" ] && [ "$used_int" -ge 50 ] 2>/dev/null; then
  ctx_color="$C_ORANGE"
fi

# handoff reminder: warn at 100k tokens
handoff_warn=0
if [ -n "$ctx_used" ] && [ "$ctx_used" -ge 100000 ] 2>/dev/null; then
  handoff_warn=1
fi

# 5h usage: yellow >= 50%, red >= 75%
five_h_color="$C_SEC"
if [ -n "$five_h" ]; then
  if [ "$five_h" -ge 75 ] 2>/dev/null; then
    five_h_color="$C_ERROR"
  elif [ "$five_h" -ge 50 ] 2>/dev/null; then
    five_h_color="$C_WARN"
  fi
fi

# --- animation phase (shared across all gradient_text calls this render) ---
# 6 units/second, 400-unit full cycle ≈ 67s. All fields animate in lockstep.
grad_phase=$(( ($(date +%s) * 6) % 400 ))

# --- assemble output ---
SEP="${C_MUTED} • ${R}"
PIPE="${C_MUTED} | ${R}"

# line 1: model | folder • branch ↑N  (Chrysaki Jewel gradient)
printf "${BOLD}"; gradient_text "$model"; printf "${R}"
printf "${PIPE}"
printf "${BOLD}"; gradient_text "$dir_name"; printf "${R}"
if [ -n "$branch" ]; then
  printf "${SEP}"
  printf "${BOLD}"; gradient_text "$branch"; printf "${R}"
  if [ "$unsynced" -gt 0 ] 2>/dev/null; then
    printf " ${C_BLONDE_LT}↑%s${R}" "$unsynced"
  fi
fi

# line 2: 5h • 7d | ctx | issues • inbox
printf "\n"
if [ -n "$five_h" ]; then
  printf "${five_h_color}5h %s%%${R}" "$five_h"
  if [ -n "$five_h_reset" ]; then
    delta=$(compute_delta "$five_h_reset")
    [ -n "$delta" ] && printf " ${DIM}${C_MUTED}(%s)${R}" "$delta"
  fi
fi
if [ -n "$seven_d" ]; then
  [ -n "$five_h" ] && printf "${SEP}"
  printf "${C_SEC}7d %s%%${R}" "$seven_d"
  if [ -n "$seven_d_reset" ]; then
    delta=$(compute_delta "$seven_d_reset")
    [ -n "$delta" ] && printf " ${DIM}${C_MUTED}(%s)${R}" "$delta"
  fi
fi
if [ -n "$ctx_str" ]; then
  printf "${PIPE}"
  printf "${ctx_color}ctx %s${R}" "$ctx_str"
  [ -n "$ctx_tokens_str" ] && printf " ${DIM}${C_MUTED}(%s)${R}" "$ctx_tokens_str"
  if [ "$handoff_warn" -eq 1 ] 2>/dev/null; then
    printf " ${C_WARN}→ handoff soon${R}"
  fi
fi
if [ -n "$issue_count" ] && [ "$issue_count" -gt 0 ] 2>/dev/null; then
  printf "${PIPE}"
  printf "${C_TEAL}issues: %s${R}" "$issue_count"
fi
if [ "$inbox_depth" -gt 0 ] 2>/dev/null; then
  printf "${SEP}"
  printf "${C_EMERALD_LT}inbox: %s${R}" "$inbox_depth"
fi
