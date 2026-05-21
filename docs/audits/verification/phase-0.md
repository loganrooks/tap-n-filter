# Phase 0 Verification

**Verifier**: Claude (verification subagent, cold context)
**Date**: 2026-05-21
**Phase**: 0 — Repo and Tooling Init
**Verdict**: FAIL

## Gate criteria assessment

### Criterion 1: The repo at `github.com/loganrooks/tap-n-filter` exists, is public, and has the description and topics set.

**Status**: Met

**Evidence**: `gh repo view loganrooks/tap-n-filter --json name,description,visibility,url,defaultBranchRef,repositoryTopics` returns:

```json
{
  "name": "tap-n-filter",
  "visibility": "PUBLIC",
  "description": "A macOS app that captures audio from a chosen application and routes it through a customizable chain of audio effects.",
  "repositoryTopics": ["audio","audio-effects","core-audio","macos","menubar","swift","swiftui"],
  "url": "https://github.com/loganrooks/tap-n-filter"
}
```

Description matches the spec exactly. All seven topics from the spec are present.

---

### Criterion 2: `main` branch protection is configured per 0.3.

**Status**: Not met

**Evidence**: `gh api repos/loganrooks/tap-n-filter/branches/main/protection` returns HTTP 404 with message `"Branch not protected"`.

**Gap**: Branch protection has not been configured on `main`. The spec requires: pull request before merge, at least one approving review, CI status checks pass, no direct pushes, linear history. None of these are currently enforced.

---

### Criterion 3: CI passes on `main` (per the merged no-op PR).

**Status**: Not met

**Evidence**: The PR (#1, "phase-0: repo and tooling init") is still open — `mergedAt` is null, `state` is `OPEN`. No no-op PR has been merged. Additionally, CI on the current `main` tip commit is failing: `gh api repos/loganrooks/tap-n-filter/commits/<main-sha>/check-runs` shows the "Build and test" job concluded `failure`. The failure log shows `xcodebuild: error: The directory does not contain an Xcode project, workspace or package` — the CI yaml on `main` still uses `xcodebuild -scheme tap-n-filter` (the pre-ADR-009 commands), while `Package.swift` is not yet on `main`. The new `swift build` CI yaml exists only on `phase-0-init`.

**Gap**: (a) No no-op PR has been opened and merged. The open PR contains the full Phase 0 feature work, not a no-op change. (b) CI on `main` is broken at the current tip because the `xcodebuild` invocation in the committed `ci.yml` references a scheme that does not exist; this predates the PR and indicates the initial commit introduced a broken CI state on `main`. (c) Even after the PR merges, this criterion requires a separately-merged no-op PR that confirmed the pipeline end-to-end.

---

### Criterion 4: CodeRabbit reviewed the no-op PR.

**Status**: Not met

**Evidence**: The shared root cause with criterion 3 is that no no-op PR was opened. PR #1 has zero review comments (from `gh api repos/loganrooks/tap-n-filter/pulls/1/reviews` returning `[]` and `gh api repos/loganrooks/tap-n-filter/pulls/1/comments` returning zero inline comments). Additionally, no `.coderabbit.yaml` file exists in the repository root; the Phase 0 spec (section 0.5) requires this file be committed. Without it, CodeRabbit may not have the configuration to comment automatically.

**Gap**: No CodeRabbit review comment on any PR. No `.coderabbit.yaml` in the repo. The spec requires CodeRabbit to comment within five minutes of the no-op PR opening; no such response is observable.

---

### Criterion 5: Codex reviewed the no-op PR (via `@codex review` comment).

**Status**: Not met

**Evidence**: Same root cause as criterion 4: no no-op PR was opened. On PR #1, the owner posted `@codex review` (comment IC_kwDOSjmLjM8AAAABDIOsDg, 2026-05-21T04:53:42Z). No response comment from any bot account follows it; the only comment on the PR is the `@codex review` invocation itself.

**Gap**: No Codex response observed. Possible causes: the Codex GitHub App is not installed on this repo, or the app did not respond within the observation window. The phase spec documents the correct escalation path: `[ESCALATION: codex-app-not-responding]`. The orchestrator should surface this escalation and await confirmation before proceeding.

---

### Criterion 6: The app shell builds (`swift build` returns 0, per ADR-009).

**Status**: Met

**Evidence**: ADR-009 (`docs/decisions/ADR-009-spm-only-project-structure.md`) formally documents the deviation from `xcodebuild` to `swift build`. Running `swift build -c debug` from the working directory on the `phase-0-init` branch returns exit code 0 with output `Build complete! (0.19s)`. The PR's CI also shows `Build and test` passing with conclusion `success` on the `phase-0-init` branch tip.

---

### Criterion 7: `Info.plist` contains `NSAudioCaptureUsageDescription`.

**Status**: Met

**Evidence**: `Sources/tap-n-filter/Resources/Info.plist` is present in the diff and on disk. It contains both required keys from the spec:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>tap-n-filter needs permission to capture audio from other applications so you can route their output through your effect chain.</string>
<key>LSUIElement</key>
<true/>
```

The string text matches the spec exactly.

---

### Criterion 8: `state.json` has phase `0` status `passed`, with `pr_url` pointing to the merged no-op PR.

**Status**: Not met

**Evidence**: `docs/orchestration/state.json` on `phase-0-init` shows:

```json
"0": {
  "status": "pending",
  "pr_url": null
}
```

**Gap**: This is expected at verification time per the task description — the orchestrator correctly defers marking phase `0` as `passed` until verification returns PASS. However, `pr_url` must also point to a merged no-op PR for this criterion to be met. No no-op PR exists and PR #1 is not merged.

---

## Framing audit-lite

**Question**: Did this phase's implementation introduce reasoning or assumptions that weren't in the spec? If so, were those additions sound?

**Answer**:

The most significant deviation is the switch from `xcodebuild` to `swift build` documented in ADR-009. The spec section 0.1 explicitly allows "Use `xcodebuild -create` or generate via `swift package init --type executable`" and the gate criterion 6 says "`xcodebuild build` returns 0." ADR-009 substitutes `swift build` and updates CI accordingly. The reasoning in the ADR is sound: the local build machine lacks Xcode.app, SPM-only layout produces simpler diffs, and the CI runners still get a full Xcode via `setup-xcode`. The ADR correctly identifies the trade-offs (no Interface Builder, no asset catalog, Phase 4 bundling script responsibility) and none of those trade-offs affect V1 scope. The audit-lite does not flag this deviation as unsound; it is the kind of grounded, well-documented adaptation the ADR format is designed to record.

The multi-module `Package.swift` layout — Capture, Graph, Effects, Presets as separate library targets with stub implementations — was not specified in the Phase 0 scope. The spec says "basic app shell: app entry point, empty `MenuBarExtra`, Info.plist." The orchestrator chose to pre-declare the V1 module structure in `Package.swift` and stub each target with a placeholder enum. This is a forward-looking addition. It is not harmful: the stubs compile cleanly, the module names match the architecture spec, and no implementation was written. The addition is arguably low-cost scaffolding that future phases will fill in rather than scope creep. However, it does introduce assumptions about the final module decomposition before Phase 1-2 work has begun. A verifier reading strictly would note this as unspec'd addition. Calibrated against the audit protocol's posture ("which decisions are load-bearing"), the module pre-declaration is low-risk because it mirrors the architecture spec and can be restructured in any later phase without a major refactor.

One concern worth recording: the `Package.swift` declares a `.copy("Resources")` rule on the executable target. This is correct for ensuring `Info.plist` is included in builds. However, SPM's handling of Info.plist in executable (non-app-bundle) targets is advisory at `swift build` time; the plist is not embedded in the built binary or a `.app` bundle by `swift build` alone. The ADR acknowledges this (`App bundling for release is performed by a shell script in Build/`), but the bundling script does not yet exist. At Phase 0, this is appropriate — the bundling script is a Phase 4 deliverable. However, the consequence is that criterion 7 ("Info.plist contains NSAudioCaptureUsageDescription") is satisfied in file-presence terms but the plist is not yet exercised by any runtime. No runtime test validates that the permission string surfaces correctly to the OS. This is in scope for later phases and is not a Phase 0 failure, but it is worth noting.

## Verdict reasoning

Five of eight gate criteria are not met. The three unmet criteria that do not share a single root cause are: branch protection (criterion 2) is simply not configured; CI on `main` is broken at the tip (criterion 3) because the old `xcodebuild` CI yaml references a non-existent scheme; and both bot review criteria (4, 5) are unmet because no `.coderabbit.yaml` was committed and neither CodeRabbit nor Codex responded to the `@codex review` invocation on PR #1. The most structurally significant gap is that the spec calls for a no-op PR to verify the pipeline end-to-end; the open PR #1 is the full feature work, not a no-op.

FAIL. Criteria 2, 3, 4, 5, and 8 are not met. The orchestrator should: (1) configure branch protection on `main`; (2) merge the feature PR to fix CI on `main`, or open and merge a no-op PR first to confirm the pipeline; (3) commit `.coderabbit.yaml` per spec section 0.5 or surface `[ESCALATION: coderabbit-config-access]`; (4) confirm Codex App installation and obtain a response to `@codex review` or surface `[ESCALATION: codex-app-not-responding]`; (5) update `state.json` once a no-op PR is merged and all criteria are met.
