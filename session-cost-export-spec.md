# Feature: Session Cost Export

## Overview

**User Story**: As a Claude Code user, I want my session's SGD cost automatically logged when the session ends, so that I can track spending over time in both a persistent cost log and my daily note.

**Problem**: Session cost is displayed in the statusline but lost when the session ends. There is no persistent record for aggregation, trend analysis, or daily review.

**Out of Scope**:
- Monthly/weekly cost aggregation views (downstream of the log)
- Automated alerts or budget caps
- Cost breakdown by tool or agent (not available in the JSON)

---

## Success Condition

> This feature is complete when: ending a Claude Code session automatically appends the SGD cost to both `000-System/Logs/session-costs.md` and today's daily note under a `## Session Costs` section.

---

## Open Questions

| # | Question | Raised By | Resolved |
|:--|:---------|:----------|:---------|
| 1 | Stop hooks don't receive cost data -- how to bridge? | Design | [x] Statusline writes cost cache; Stop hook reads it |

---

## Scope

### Must-Have
- Statusline writes cost cache file on each render: model, cost USD, cost SGD, duration, session ID, CWD
- New `export-cost.sh` script in the statusline repo, triggered as a Stop hook
- Append a markdown table row to `000-System/Logs/session-costs.md` (create file with header if missing)
- Append a line under `## Session Costs` in today's daily note (create section if missing)
- Clean up stale `fetch-usage.sh` reference in the Stop hook config in `~/.claude/settings.json`
- Skip export if cost is 0 or cache is missing (avoids logging empty sessions)

### Should-Have
- Configurable vault root detection (not hardcoded) via `git rev-parse --show-toplevel` or env var

### Nice-to-Have
- `CHRYSAKI_NO_COST_EXPORT=1` env var to disable the hook

---

## Technical Plan

**Affected Components**:
- `statusline-command.sh` -- add cost cache write (2-3 lines at end of script)
- `export-cost.sh` -- new file, Stop hook script (~60 lines)
- `~/.claude/settings.json` -- add export-cost.sh to Stop hooks, remove stale fetch-usage.sh reference
- `000-System/Logs/session-costs.md` -- created on first run (vault file)

**Data Flow**:
```
statusline-command.sh (each render) --> /tmp/.chrysaki_cost_cache  (model, USD, SGD, duration, session_id, cwd)
Stop hook --> export-cost.sh --> reads cache --> appends to:
  1. {vault}/000-System/Logs/session-costs.md  (persistent log table)
  2. {vault}/500-Chronological-Logs/510-Personal/YYYY/MMM-DD.md  (daily note)
```

**Cost cache format** (`/tmp/.chrysaki_cost_cache`):
```
model_name
cost_usd
cost_sgd
duration_str
session_id
cwd
```

Written by `statusline-command.sh` at the end of each render (overwrite, not append). `chmod 600` for safety.

**session-costs.md format**:
```markdown
# Session Costs

| Date | Session | Model | Duration | USD | SGD | Workspace |
|:-----|:--------|:------|:---------|:----|:----|:----------|
| 2026-03-26 14:30 | abc123 | Opus 4.6 | 1hr 23m | $1.23 | $1.66 | statusline |
```

**Daily note entry**:
```markdown
## Session Costs
- Opus 4.6 | 1hr 23m | $1.66 SGD ($1.23 USD) | statusline
```

**Vault root detection**: `export-cost.sh` reads `cwd` from the cache, then walks up to find `.obsidian/` directory (standard Obsidian vault marker). Fallback: `CHRYSAKI_VAULT_ROOT` env var.

**Dependencies**: None beyond existing (`bash`, `date`, `jq`)

**Risks**:
| Risk | Likelihood | Mitigation |
|:-----|:-----------|:-----------|
| Cost cache stale if statusline never rendered | Low | Stop hook checks cache mtime; skips if older than 24h |
| Daily note doesn't exist yet | Medium | Skip daily note append if file missing (don't create it) |
| Race between statusline final render and Stop hook | Low | statusline writes cache atomically (write to tmp, mv) |
| Multiple sessions writing to same log concurrently | Low | Append-only with `>>` is atomic for single lines on Linux |

---

## Acceptance Scenarios

```gherkin
Feature: Session Cost Export
  As a Claude Code user
  I want session costs logged when sessions end
  So that I can track spending over time

  Background:
    Given export-cost.sh is configured as a Stop hook
    And the statusline has rendered at least once this session

  Rule: Cost cache written by statusline

    Scenario: Statusline writes cost cache on each render
      Given the statusline receives JSON with cost.total_cost_usd = 1.23
      When the statusline renders
      Then /tmp/.chrysaki_cost_cache contains the model, costs, and duration
      And the file permissions are 600

  Rule: Persistent cost log updated on session end

    Scenario: First session creates log file with header
      Given 000-System/Logs/session-costs.md does not exist
      When the Stop hook fires
      Then the file is created with a markdown table header
      And a row with today's date, session ID, model, duration, USD, SGD, and workspace

    Scenario: Subsequent sessions append rows
      Given 000-System/Logs/session-costs.md exists with a header and rows
      When the Stop hook fires
      Then a new row is appended (not overwriting existing rows)

  Rule: Daily note updated on session end

    Scenario: Daily note gets Session Costs section
      Given today's daily note exists but has no Session Costs section
      When the Stop hook fires
      Then a "## Session Costs" section is created
      And a cost line is appended under it

    Scenario: Daily note already has Session Costs section
      Given today's daily note has a "## Session Costs" section with entries
      When the Stop hook fires
      Then a new cost line is appended under the existing section

    Scenario: Daily note doesn't exist
      Given today's daily note file does not exist
      When the Stop hook fires
      Then the daily note is not created (skip silently)

  Rule: Zero-cost sessions are skipped

    Scenario: No cost logged for empty sessions
      Given the cost cache shows cost_usd = 0.00
      When the Stop hook fires
      Then nothing is appended to either file

  Rule: Stale fetch-usage.sh reference removed

    Scenario: Settings.json Stop hook is clean
      Given the feature is deployed
      When inspecting ~/.claude/settings.json Stop hooks
      Then no reference to fetch-usage.sh exists
```

---

## Task Breakdown

| ID   | Task | Priority | Dependencies | Status  |
|:-----|:-----|:---------|:-------------|:--------|
| T1   | Add cost cache write to `statusline-command.sh` (model, USD, SGD, duration, session_id, cwd) | High | None | pending |
| T2   | Create `export-cost.sh` -- read cache, append to cost log and daily note | High | T1 | pending |
| T3   | Remove stale `fetch-usage.sh` from Stop hooks in `~/.claude/settings.json` | High | None | pending |
| T4   | Add `export-cost.sh` to Stop hooks in `~/.claude/settings.json` | High | T2 | pending |
| T5   | Manual test: run a session, verify both files get entries | High | T1-T4 | pending |

---

## Exit Criteria

- [ ] `statusline-command.sh` writes `/tmp/.chrysaki_cost_cache` on each render
- [ ] `export-cost.sh` exists and is executable
- [ ] Stop hook in `settings.json` includes `export-cost.sh` and does not reference `fetch-usage.sh`
- [ ] After a session with cost > 0, `session-costs.md` has a new row
- [ ] After a session with cost > 0, today's daily note has a `## Session Costs` entry
- [ ] A session with cost = 0 produces no log entries
- [ ] Missing daily note does not cause an error

---

## References

- Chrysaki v2.1 spec: `chrysaki-v2.1-spec.md` (cost_sgd calculation)
- Claude Code hook docs: [code.claude.com/docs/en/statusline](https://code.claude.com/docs/en/statusline)
- Stop hook input: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `reason` (no cost data)

---
*Authored by: Clault KiperO 4.6*
