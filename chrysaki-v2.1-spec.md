# Feature: Chrysaki v2.1 -- Jewel Pool, Native Rate Limits, Visual Polish

## Overview

**User Story**: As a Claude Code user, I want a statusline that looks polished when static (no frozen gradient artefacts), uses native rate limit data (no background fetcher), and has a richer colour palette that shifts between renders, so that the statusline is visually clean, architecturally simpler, and ready for future animation support.

**Problem**: The current gradient rendering (`gradient_text` / `gradient_text_off`) produces a frozen colour smear between renders because Claude Code only re-renders the statusline on assistant messages, not on a timer. The `fetch-usage.sh` background fetcher is now redundant since Claude Code natively provides `rate_limits.*` in the statusline JSON. And when there are no git changes, the changes column is blank instead of showing `+0 -0`, causing visual inconsistency.

**Out of Scope**:
- Implementing actual real-time animation (blocked on [anthropics/claude-code#5685](https://github.com/anthropics/claude-code/issues/5685))
- Changes to `fetch-stats.sh` (issues/PR fetcher -- still needed)
- Changes to column alignment logic
- Changes to progress bar styles or section markers

---

## Success Condition

> This feature is complete when: (1) no gradient functions exist in the codebase, (2) `fetch-usage.sh` is deleted and rate limits are read from JSON stdin, (3) bridges and branch use the 9-colour jewel pool with per-render colour shifting, and (4) the git changes column always shows `+0 -0` when there are no changes.

---

## Open Questions

| # | Question | Raised By | Resolved |
|:--|:---------|:----------|:---------|
| 1 | When `refreshIntervalSeconds` ships, should gradient be re-enabled automatically or require `CHRYSAKI_ANIMATE=1`? | Design | [x] Behind env flag |

---

## Scope

### Must-Have
- Remove `gradient_text()` and `gradient_text_off()` functions: no per-character colour interpolation remains in the codebase
- Add 9-colour Chrysaki jewel tone array (`JEWEL_COLORS`): Emerald Lt, Jade, Deep Teal, Royal Blue Lt, Sapphire, Indigo, Amethyst Lt, Twilight, Storm
- Replace all `gradient_text_off` calls on Line 1 with solid-colour `printf` (Emerald Lt for model/badge, random jewel for bridges, Secondary for version)
- Replace `gradient_text` calls on Line 4 branch with solid jewel tone
- Expand `_BR_COLORS` from 3 to 9 entries using the jewel pool (dimmed variants for bridges)
- Add `_jewel_seed` with prime-based selection so each line gets a different colour and colours shift per render
- Delete `fetch-usage.sh` entirely
- Remove OAuth token caching, per-account usage cache file logic, and background fetch trigger from `statusline-command.sh`
- Read `rate_limits.five_hour` and `rate_limits.seven_day` from JSON stdin
- Simplify `compute_delta()` to accept Unix epoch seconds directly (no ISO 8601 parsing)
- Show `+0 -0` in muted colour when `git_insertions` and `git_deletions` are both 0
- Update `_l4_mc_w` column width calculation to account for always-present `+0 -0`
- Update `CLAUDE.md` architecture docs

### Should-Have
- Keep `CHRYSAKI_NO_ANIMATE` flag functional (freezes `_jewel_seed` to 0 when set)
- Preserve `grad_phase` variable for future re-use behind `CHRYSAKI_ANIMATE` flag

### Nice-to-Have
- Add `CHRYSAKI_JEWEL_STATIC` env var to pin a specific jewel index (useful for screenshots / demos)

---

## Technical Plan

**Affected Components**:
- `statusline-command.sh` (1077 lines -- major edits)
- `fetch-usage.sh` (76 lines -- delete)
- `CLAUDE.md` (doc updates)

**Data Model Changes**:
- New bash array: `JEWEL_COLORS` (9 ANSI escape sequences)
- New bash array: `JEWEL_COLORS_DIM` (9 dimmed variants for bridges)
- New variable: `_jewel_seed` (integer, from `date +%s`)
- Removed variables: `CACHE_FILE`, `_config_dir` (usage-specific), `_acct` (usage-specific)
- Changed: `five_h_reset` / `seven_d_reset` from ISO 8601 strings to Unix epoch integers

**API Contracts**: N/A (shell script, no HTTP API)

**Dependencies**:
- Claude Code >= version that provides `rate_limits.*` in statusline JSON (confirmed in current docs)
- `jq` for JSON parsing (already a dependency)

**Risks**:
| Risk | Likelihood | Mitigation |
|:-----|:-----------|:-----------|
| `rate_limits.*` absent on older Claude Code versions | Low | Graceful fallback: existing `// empty` jq pattern handles missing fields -- bars show blank, same as before cache was populated |
| `rate_limits.*` absent for non-subscriber accounts | Medium | Already handled: the script checks for empty values before rendering usage sections |
| Jewel colour contrast issues on light terminal themes | Low | All 9 colours are mid-saturation jewel tones (not pastels); `NO_COLOUR` mode already disables all ANSI |

---

## Acceptance Scenarios

```gherkin
Feature: Chrysaki v2.1 -- Jewel Pool, Native Rate Limits, Visual Polish
  As a Claude Code user
  I want a polished static statusline with native data and rich colours
  So that it looks intentional between renders and has no redundant fetchers

  Background:
    Given the statusline is configured in ~/.claude/settings.json
    And Claude Code pipes JSON to statusline-command.sh on stdin

  Rule: No gradient rendering

    Scenario: Line 1 renders with solid colours instead of gradient
      Given the model is "Claude Opus 4.6 (1M context)"
      When the statusline renders
      Then the model name and badge are solid Emerald Lt
      And the version is solid Secondary colour
      And each bridge segment is a single jewel tone (not per-character gradient)

    Scenario: Line 4 branch renders with solid colour
      Given the branch is "feat/issue-4-statusline-v2"
      When the statusline renders
      Then the branch name is bold with a single jewel tone
      And no per-character colour interpolation is applied

  Rule: Jewel colours shift between renders

    Scenario: Adjacent lines have different bridge colours
      When the statusline renders at timestamp T
      Then L1, L2, L3, L4 bridges each use a different jewel colour
      And no two adjacent lines share the same bridge colour

    Scenario: Colours change on next render
      Given the statusline rendered at timestamp T
      When the statusline renders at timestamp T+1
      Then at least some bridge colours have changed

  Rule: Native rate limits replace background fetcher

    Scenario: Rate limits read from JSON when available
      Given the JSON stdin contains rate_limits.five_hour.used_percentage = 42
      And rate_limits.five_hour.resets_at = 1774520000
      When the statusline renders
      Then the 5h section shows 42%
      And the reset countdown is computed from epoch 1774520000

    Scenario: Rate limits gracefully absent
      Given the JSON stdin has no rate_limits field
      When the statusline renders
      Then the 5h and 7d sections are blank (no error)

    Scenario: fetch-usage.sh no longer exists
      When listing files in the statusline directory
      Then fetch-usage.sh does not exist

  Rule: Git changes always show +N -M

    Scenario: No changes shows +0 -0
      Given git reports 0 insertions and 0 deletions
      When the statusline renders Line 4
      Then the changes column shows "+0 -0" in muted colour

    Scenario: Changes show coloured counts
      Given git reports 15 insertions and 3 deletions
      When the statusline renders Line 4
      Then the changes column shows "+15" in green and "-3" in red
```

---

## Task Breakdown

| ID   | Task | Priority | Dependencies | Status  |
|:-----|:-----|:---------|:-------------|:--------|
| T1   | Add 9-colour `JEWEL_COLORS` and `JEWEL_COLORS_DIM` arrays + `_jewel_seed` selection logic | High | None | pending |
| T2   | Remove `gradient_text()` and `gradient_text_off()` functions | High | None | pending |
| T3   | Replace Line 1 gradient calls with solid-colour printf (model=Emerald, version=Secondary, bridges=jewel) | High | T1, T2 | pending |
| T4   | Replace Line 4 `gradient_text` branch calls with solid jewel tone | High | T1, T2 | pending |
| T5   | Expand `_BR_COLORS` from 3 to 9 entries using `JEWEL_COLORS_DIM` | High | T1 | pending |
| T6   | Migrate rate limits: read `rate_limits.*` from JSON stdin, replace cache file reads | High | None | pending |
| T7   | Simplify `compute_delta()` to accept Unix epoch directly | High | T6 | pending |
| T8   | Remove usage cache logic (account resolution, CACHE_FILE, background fetch trigger) | High | T6 | pending |
| T9   | Delete `fetch-usage.sh` | High | T8 | pending |
| T10  | Show `+0 -0` in muted colour when no git changes + fix `_l4_mc_w` | High | None | pending |
| T11  | Update `CLAUDE.md` architecture docs | Med | T1-T10 | pending |
| T12  | Manual test: pipe mock JSON, verify all 4 lines render correctly | High | T1-T10 | pending |

---

## Exit Criteria

- [ ] `grep -c gradient_text statusline-command.sh` returns 0
- [ ] `fetch-usage.sh` does not exist
- [ ] `JEWEL_COLORS` array has exactly 9 entries
- [ ] Mock JSON with `rate_limits.five_hour.used_percentage` renders correctly
- [ ] Mock JSON without `rate_limits` renders without error
- [ ] No two adjacent lines share bridge colour (visual inspection at 3 different timestamps)
- [ ] Git changes column shows `+0 -0` when no changes present
- [ ] `CHRYSAKI_NO_ANIMATE=1` freezes jewel seed to index 0
- [ ] No regressions: all existing elements (bars, markers, badges, OSC8 links) still render

---

## References

- Feature request for refresh interval: [anthropics/claude-code#5685](https://github.com/anthropics/claude-code/issues/5685)
- Official statusline docs: [code.claude.com/docs/en/statusline](https://code.claude.com/docs/en/statusline)
- Native rate_limits fields: confirmed in official JSON schema (March 2026 docs)
- PR: [#7 feat: statusline v2](https://github.com/Kiriketsuki/claude-statusline/pull/7)

---
*Authored by: Clault KiperO 4.6*
