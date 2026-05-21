# Phase 0: Repo and Tooling Init

Bootstrap the project's GitHub repository, build system, CI, review tooling, and signing infrastructure. The deliverable is an empty but fully equipped repository: clean build of an empty app shell, CI green, review apps responding to PRs.

## Scope

In:
- `swift package init` or Xcode project for a SwiftUI menubar app targeting macOS 14.4+.
- Basic app shell: app entry point, empty `MenuBarExtra`, Info.plist with `NSAudioCaptureUsageDescription` placeholder text.
- GitHub repo creation under `loganrooks/tap-n-filter`.
- `.github/workflows/ci.yml` running `xcodebuild` build and `swift test` on PR.
- CodeRabbit configuration in repo root, copied/adapted from `loganrooks/coderabbit`.
- Codex GitHub App verification (no in-repo config file required; app is installed at user level).
- Branch protection on `main` requiring CI pass and at least one review-bot approval.
- A no-op PR opened against `main` to verify the full pipeline. Merged after passing.

Out:
- Signing and notarization (deferred to Phase 4).
- App icon (deferred to Phase 4).
- Any audio code (Phase 1).
- Any UI beyond a stub menubar item.

## Tasks

### 0.1 Initialize the Swift package / Xcode project

Use `xcodebuild -create` or generate via `swift package init --type executable`, then add a macOS app target with SwiftUI lifecycle. Minimum deployment target: macOS 14.4. Bundle ID: `com.loganrooks.tap-n-filter`.

The app entry point is a SwiftUI `App` struct with a single `MenuBarExtra` scene displaying a static title (e.g. "tap-n-filter").

The Info.plist must include:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>tap-n-filter needs permission to capture audio from other applications so you can route their output through your effect chain.</string>
<key>LSUIElement</key>
<true/>
```

`LSUIElement=true` makes this a menubar-only app with no Dock icon.

### 0.2 Create the GitHub repo

Use `gh repo create loganrooks/tap-n-filter --public --source=. --remote=origin --push`. The repo will already contain the scribed bundle from this initial commit. Set the description and topics:

```
Description: A macOS app that captures audio from a chosen application and routes it through a customizable chain of audio effects.
Topics: macos, audio, swift, swiftui, core-audio, audio-effects, menubar
```

### 0.3 Configure branch protection

Via `gh api` calls or the GitHub web UI: protect `main`. Require:
- Pull request before merge.
- At least 1 approving review (counts toward CodeRabbit/Codex bot approvals if configured to grant them, otherwise human).
- CI status checks pass.
- No direct pushes.
- Linear history (rebase or squash merges only).

### 0.4 Set up CI

Write `.github/workflows/ci.yml` triggered on `pull_request` and `push` to `main`. Steps:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  build-and-test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - name: Build
        run: xcodebuild -scheme tap-n-filter -configuration Debug build
      - name: Test
        run: xcodebuild -scheme tap-n-filter -configuration Debug test
```

(`macos-14` runners come with Xcode 16+ in 2026. Verify availability and pin to a specific version if needed.)

### 0.5 Configure CodeRabbit

Reference `loganrooks/coderabbit` for the canonical config and instructions. The orchestrator clones that repo into `/tmp/coderabbit-template` (read-only), copies the local config template, adapts it for this project, and commits the resulting `.coderabbit.yaml` to the repo root.

If `loganrooks/coderabbit` is not accessible (private), the orchestrator surfaces `[ESCALATION: coderabbit-config-access]` and waits for the user to either grant access or provide the config inline.

Before committing the adapted `.coderabbit.yaml`, the orchestrator scans the file for references to private repositories, internal services, API keys, internal service URLs, or any identifiers that should not appear in a public repo. The `loganrooks/coderabbit` template is described as canonical config and instructions copied across the user's repos; while the base rate of secrets in such files is low, the adaptation step is the only guard. Any private-context references are removed or replaced with public-safe equivalents before the file is committed.

The CodeRabbit GitHub App must be installed and authorized on the new repo. Verify by opening the no-op PR (step 0.7) and confirming a CodeRabbit comment appears within five minutes.

### 0.6 Verify Codex review path

The Codex GitHub App is installed at the user level. No repo-level config is required. Verify by commenting `@codex review` on the no-op PR and confirming Codex responds.

If `@codex review` does not produce a response within five minutes, surface `[ESCALATION: codex-app-not-responding]` and wait for the user to verify their Codex installation.

### 0.7 No-op verification PR

Open a PR titled `chore: verify CI and review tooling` containing a no-op change (add a trailing newline to README.md, for example). Confirm:

- CI runs and passes.
- CodeRabbit comments within five minutes.
- `@codex review` invokes Codex and produces a response.
- Branch protection enforces the review requirement.

Merge after all checks pass. Delete the feature branch.

## Gate criteria

Phase 0 PASSES when the verification subagent confirms all of the following:

1. The repo at `github.com/loganrooks/tap-n-filter` exists, is public, and has the description and topics set.
2. `main` branch protection is configured per 0.3.
3. CI passes on `main` (per the merged no-op PR).
4. CodeRabbit reviewed the no-op PR.
5. Codex reviewed the no-op PR (via `@codex review` comment).
6. The app shell builds (`xcodebuild build` returns 0).
7. `Info.plist` contains `NSAudioCaptureUsageDescription`.
8. `state.json` has phase `0` status `passed`, with `pr_url` pointing to the merged no-op PR.

The verification subagent reads the relevant artifacts (repo metadata via `gh`, the merged PR's checks, the file contents) to confirm each point.

## Failure modes

- **CodeRabbit or Codex misconfigured.** Surface escalation. Do not advance.
- **CI runner unavailable.** macOS runners on GitHub Actions occasionally have queue delays. Wait. If a job has been queued for more than 30 minutes, surface `[ESCALATION: ci-runner-stalled]`.
- **Existing repo with the same name.** Surface `[ESCALATION: repo-name-collision]` and ask the user whether to rename, archive the existing repo, or abort.

## Outputs

- A live public GitHub repo with the scribed bundle plus the empty app shell.
- Merged no-op PR demonstrating the review pipeline works.
- `state.json` updated: phase `0` → `passed`, `current_phase` → `1`.
- An ADR if any task surfaced a real decision (e.g., Xcode version pin choice).
