# PR #7 review-journal backfill — loganrooks/tap-n-filter

Generated 2026-05-22 21:26:10 UTC.

Each thread below has an inferred verdict. Confirm by checking the box and either re-running `extract-pr.sh <N> --accept-inferred` to flip the source to `manual`, or by hand-editing the journal JSON.

## coderabbitai

- [ ] **ACCEPTED_MODIFIED** — commit `814a751` — `Sources/ViewModel/AppViewModel.swift` (thread `PRRT_kwDOSjmLjM6D9r4M`)
    - finding: _⚠️ Potential issue_ | _🟠 Major_ | _⚡ Quick win_

**Prevent nil bundle-ID fallback from selecting an unrelated source.**

On Line 354, the fallback compares optional bundle IDs directly. If the select
    - inference: Inferred from auto-resolution marker citing commit 814a751.

- [ ] **ACCEPTED_MODIFIED** — commit `d97fd20` — `docs/decisions/ADR-013-reorder-via-buttons-not-drag.md` (thread `PRRT_kwDOSjmLjM6D9tfu`)
    - finding: _⚠️ Potential issue_ | _🟡 Minor_ | _⚡ Quick win_

**Replace aphoristic phrasing with neutral declarative wording.**

“Two regressions to gain one feature.” reads like an aphoristic closer; please rest
    - inference: Inferred from CodeRabbit auto-resolve pattern citing commit d97fd20.

- [ ] **ACCEPTED_MODIFIED** — commit `d97fd20` — `docs/decisions/dissent-log.md` (thread `PRRT_kwDOSjmLjM6D9tfv`)
    - finding: _⚠️ Potential issue_ | _🟡 Minor_ | _⚡ Quick win_

**Use affirmative declarative wording in decision statements.**

These lines use contrastive phrasing (“not …”, “rather than …”). Please rewrite them 
    - inference: Inferred from CodeRabbit auto-resolve pattern citing commit d97fd20.

- [ ] **ACCEPTED_MODIFIED** — commit `d97fd20` — `docs/governance/review-protocol.md` (thread `PRRT_kwDOSjmLjM6D9tfw`)
    - finding: _⚠️ Potential issue_ | _🟡 Minor_ | _⚡ Quick win_

**Avoid repeated “Sometimes …” sentence openers in this list item.**

Line 84 uses an anaphoric pattern (“Sometimes …” repeated), which hurts readabil
    - inference: Inferred from CodeRabbit auto-resolve pattern citing commit d97fd20.

- [ ] **ACCEPTED_MODIFIED** — commit `d97fd20` — `Sources/AccessibilityDump/main.swift`:110 (thread `PRRT_kwDOSjmLjM6D9tf0`)
    - finding: _⚠️ Potential issue_ | _🟠 Major_ | _⚡ Quick win_

**Keep the committed accessibility artifact deterministic.**

`generatedAt` and `operatingSystemVersionString` change on every run, so the regenerated
    - inference: Inferred from CodeRabbit auto-resolve pattern citing commit d97fd20.

- [ ] **ACCEPTED_MODIFIED** — commit `d97fd20` — `Sources/Capture/CoreAudioInterface.swift` (thread `PRRT_kwDOSjmLjM6D9tf3`)
    - finding: _⚠️ Potential issue_ | _🟠 Major_ | _⚡ Quick win_

<details>
<summary>🧩 Analysis chain</summary>

🏁 Script executed:

```shell
#!/bin/bash
set -euo pipefail

# Locate the file and print relevant sectio
    - inference: Inferred from CodeRabbit auto-resolve pattern citing commit d97fd20.

- [ ] **ACCEPTED_MODIFIED** — commit `a8ea11e` — `Sources/UI/ControlPanelView.swift` (thread `PRRT_kwDOSjmLjM6D9tf7`)
    - finding: _⚠️ Potential issue_ | _🟡 Minor_ | _⚡ Quick win_

**Doc comment should mention the conditional DebugPanel and 820pt max height.**

The doc comment states the view is "Composed of `HeaderView`, `Source
    - inference: Inferred from CodeRabbit auto-resolve pattern citing commit a8ea11e.

