#!/usr/bin/env bash
# export-cost.sh — Stop hook: persist session SGD cost to vault log + daily note.
# Reads the /tmp/.chrysaki_cost_cache.<session_short> file written by statusline-command.sh
# for THIS session only. Processes no other sessions' cache files.
# Sweeps orphaned cache files older than 24h after export (no log writes for orphans).

set -euo pipefail

# --- read this session's ID from stdin JSON (Stop hook contract) ---
_input=$(cat)
_session_id=$(echo "$_input" | jq -r '.session_id // empty' 2>/dev/null)
_session_short="${_session_id:0:8}"

# No session_id → nothing to process
[ -z "$_session_short" ] && exit 0

COST_CACHE="/tmp/.chrysaki_cost_cache.${_session_short}"

_export_one_cache() {
  local COST_CACHE="$1"

  # --- guard: must be fresh ---
  local _cache_mtime
  _cache_mtime=$(stat -c %Y "$COST_CACHE" 2>/dev/null || stat -f %m "$COST_CACHE" 2>/dev/null || echo 0)
  local _cache_age=$(( $(date +%s) - _cache_mtime ))
  [ "$_cache_age" -gt 86400 ] && { rm -f "$COST_CACHE"; return 0; }

  # --- read cache (7 lines: model, cost_usd, cost_sgd, duration, session_id, cwd, timestamp) ---
  local model
  local _raw_usd
  local cost_usd
  local cost_sgd
  local duration
  local session_id
  local cwd
  local cached_ts
  model=$(sed -n '1p' "$COST_CACHE")
  _raw_usd=$(sed -n '2p' "$COST_CACHE")
  cost_usd=$(printf "%.2f" "$_raw_usd")
  cost_sgd=$(sed -n '3p' "$COST_CACHE")
  duration=$(sed -n '4p' "$COST_CACHE")
  session_id=$(sed -n '5p' "$COST_CACHE")
  cwd=$(sed -n '6p' "$COST_CACHE")
  cached_ts=$(sed -n '7p' "$COST_CACHE")

  # --- guard: skip zero-cost sessions (but still clean up the cache) ---
  local _usd_zero
  _usd_zero=$(echo "$_raw_usd" | awk '{printf "%.0f", $1 * 100}')
  [ "${_usd_zero:-0}" -eq 0 ] && { rm -f "$COST_CACHE"; return 0; }

  # --- find vault root: walk up from cwd looking for .obsidian/ ---
  local vault_root=""
  if [ -n "$cwd" ]; then
    local _dir="$cwd"
    while [ "$_dir" != "/" ]; do
      if [ -d "$_dir/.obsidian" ]; then
        vault_root="$_dir"
        break
      fi
      _dir=$(dirname "$_dir")
    done
  fi
  # Fallback: env var
  [ -z "$vault_root" ] && vault_root="${CHRYSAKI_VAULT_ROOT:-}"
  # No vault found — clean up cache but skip logging
  [ -z "$vault_root" ] && { rm -f "$COST_CACHE"; return 0; }

  # --- workspace name (basename of cwd) ---
  local workspace
  workspace=$(basename "$cwd")

  # --- timestamp: use cached timestamp if available, else current time ---
  local now_date="${cached_ts:-$(date '+%Y-%m-%d %H:%M:%S')}"
  local short_session="${session_id:0:8}"

  # --- acquire lock: serialise writes to shared vault files ---
  (
    flock -x 200

    # =============================================
    # 1. Persistent cost log
    # =============================================
    local COST_LOG="$vault_root/000-System/Logs/session-costs.md"
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
    local _year
    local _month_day
    local DAILY_NOTE
    _year=$(date "+%Y")
    _month_day=$(date "+%b-%d")
    DAILY_NOTE="$vault_root/500-Chronological-Logs/510-Personal/${_year}/${_month_day}.md"

    [ -f "$DAILY_NOTE" ] || return 0

    local _cost_line="- ${model} | ${duration} | \$${cost_sgd} SGD (\$${cost_usd} USD) | ${workspace}"

    if grep -q "^## Session Costs" "$DAILY_NOTE" 2>/dev/null; then
      local _section_line
      _section_line=$(grep -n "^## Session Costs" "$DAILY_NOTE" | head -1 | cut -d: -f1 || true)
      local _next_section=""
      if [ -n "$_section_line" ]; then
        _next_section=$(awk "NR > ${_section_line} && /^## /{print NR; exit}" "$DAILY_NOTE" || true)
      fi

      if [ -n "$_next_section" ]; then
        local _insert_at=$(( _next_section - 1 ))
        sed -i "${_insert_at}a\\${_cost_line}" "$DAILY_NOTE"
      else
        local _footer_line
        _footer_line=$(grep -n "^---$" "$DAILY_NOTE" | tail -1 | cut -d: -f1 || true)
        if [ -n "$_footer_line" ]; then
          sed -i "${_footer_line}i\\${_cost_line}" "$DAILY_NOTE"
        else
          echo "$_cost_line" >> "$DAILY_NOTE"
        fi
      fi
    else
      # Find footer --- (must be AFTER frontmatter, i.e., after line 10)
      local _footer_line
      _footer_line=$(awk 'NR > 10 && /^---$/ {print NR; exit}' "$DAILY_NOTE" || true)
      if [ -n "$_footer_line" ]; then
        sed -i "${_footer_line}i\\\\n## Session Costs\\n${_cost_line}" "$DAILY_NOTE"
      else
        # No footer found — append before authorship line or at end
        local _author_line
        _author_line=$(grep -n "^\*Authored by:" "$DAILY_NOTE" | tail -1 | cut -d: -f1 || true)
        if [ -n "$_author_line" ]; then
          sed -i "${_author_line}i\\\\n## Session Costs\\n${_cost_line}\\n---" "$DAILY_NOTE"
        else
          printf "\n## Session Costs\n%s\n" "$_cost_line" >> "$DAILY_NOTE"
        fi
      fi
    fi

  ) 200>/tmp/.export-cost.lock

  # --- cleanup: remove this session's cache after successful export ---
  rm -f "$COST_CACHE"
}

# --- process this session's cache only ---
[ -f "$COST_CACHE" ] || exit 0
_export_one_cache "$COST_CACHE"

# --- sweep: delete orphaned cache files older than 24h (no log writes) ---
find /tmp -maxdepth 1 -name '.chrysaki_cost_cache.*' -mtime +1 -delete 2>/dev/null || true
