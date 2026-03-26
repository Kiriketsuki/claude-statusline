#!/usr/bin/env bash
# export-cost.sh — Stop hook: persist session SGD cost to vault log + daily note.
# Reads /tmp/.chrysaki_cost_cache written by statusline-command.sh on each render.
# Skips silently if cache missing, stale (>24h), or cost is zero.

set -euo pipefail

COST_CACHE="/tmp/.chrysaki_cost_cache"

# --- guard: cache must exist and be fresh ---
[ -f "$COST_CACHE" ] || exit 0
_cache_age=$(( $(date +%s) - $(stat -c %Y "$COST_CACHE" 2>/dev/null || stat -f %m "$COST_CACHE" 2>/dev/null || echo 0) ))
[ "$_cache_age" -gt 86400 ] && exit 0

# --- read cache (6 lines: model, cost_usd, cost_sgd, duration, session_id, cwd) ---
model=$(sed -n '1p' "$COST_CACHE")
_raw_usd=$(sed -n '2p' "$COST_CACHE")
cost_usd=$(printf "%.2f" "$_raw_usd")
cost_sgd=$(sed -n '3p' "$COST_CACHE")
duration=$(sed -n '4p' "$COST_CACHE")
session_id=$(sed -n '5p' "$COST_CACHE")
cwd=$(sed -n '6p' "$COST_CACHE")

# --- guard: skip zero-cost sessions ---
_usd_zero=$(echo "$_raw_usd" | awk '{printf "%.0f", $1 * 100}')
[ "${_usd_zero:-0}" -eq 0 ] && exit 0

# --- find vault root: walk up from cwd looking for .obsidian/ ---
vault_root=""
_dir="$cwd"
while [ "$_dir" != "/" ]; do
  if [ -d "$_dir/.obsidian" ]; then
    vault_root="$_dir"
    break
  fi
  _dir=$(dirname "$_dir")
done
# Fallback: env var
[ -z "$vault_root" ] && vault_root="${CHRYSAKI_VAULT_ROOT:-}"
[ -z "$vault_root" ] && exit 0

# --- workspace name (basename of cwd) ---
workspace=$(basename "$cwd")

# --- timestamp ---
now_date=$(date "+%Y-%m-%d %H:%M")
short_session="${session_id:0:8}"

# =============================================
# 1. Persistent cost log
# =============================================
COST_LOG="$vault_root/000-System/Logs/session-costs.md"
mkdir -p "$(dirname "$COST_LOG")"

if [ ! -f "$COST_LOG" ]; then
  cat > "$COST_LOG" <<'HEADER'
# Session Costs

| Date | Session | Model | Duration | USD | SGD | Workspace |
|:-----|:--------|:------|:---------|:----|:----|:----------|
HEADER
fi

printf "| %s | %s | %s | %s | \$%s | \$%s | %s |\n" \
  "$now_date" "$short_session" "$model" "$duration" "$cost_usd" "$cost_sgd" "$workspace" \
  >> "$COST_LOG"

# =============================================
# 2. Daily note
# =============================================
_year=$(date "+%Y")
_month_day=$(date "+%b-%d")
DAILY_NOTE="$vault_root/500-Chronological-Logs/510-Personal/${_year}/${_month_day}.md"

[ -f "$DAILY_NOTE" ] || exit 0

_cost_line="- ${model} | ${duration} | \$${cost_sgd} SGD (\$${cost_usd} USD) | ${workspace}"

if grep -q "^## Session Costs" "$DAILY_NOTE" 2>/dev/null; then
  # Append after existing section content (before next ## or end of file)
  # Find the line number of "## Session Costs", then find the next section or EOF
  _section_line=$(grep -n "^## Session Costs" "$DAILY_NOTE" | head -1 | cut -d: -f1)
  _total_lines=$(wc -l < "$DAILY_NOTE")
  _next_section=$(awk "NR > $_section_line && /^## /{print NR; exit}" "$DAILY_NOTE")

  if [ -n "$_next_section" ]; then
    # Insert before the next section
    _insert_at=$(( _next_section - 1 ))
    sed -i "${_insert_at}a\\${_cost_line}" "$DAILY_NOTE"
  else
    # No next section — append at end (before --- footer if present)
    _footer_line=$(grep -n "^---$" "$DAILY_NOTE" | tail -1 | cut -d: -f1)
    if [ -n "$_footer_line" ]; then
      sed -i "${_footer_line}i\\${_cost_line}" "$DAILY_NOTE"
    else
      echo "$_cost_line" >> "$DAILY_NOTE"
    fi
  fi
else
  # Create the section — insert before --- footer if present, otherwise append
  _footer_line=$(grep -n "^---$" "$DAILY_NOTE" | tail -1 | cut -d: -f1)
  if [ -n "$_footer_line" ]; then
    sed -i "${_footer_line}i\\\\n## Session Costs\\n${_cost_line}" "$DAILY_NOTE"
  else
    printf "\n## Session Costs\n%s\n" "$_cost_line" >> "$DAILY_NOTE"
  fi
fi
