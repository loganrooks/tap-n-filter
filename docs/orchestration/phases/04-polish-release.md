# Phase 4: Polish and Release Prep

Take the working app from Phase 3 and prepare it for release. Signing, notarization, packaging, README polish, screenshots, the v0.1.0 release tag. This phase ends with the second human-in-loop gate: user acceptance.

## Scope

In:
- App icon (1024px source plus all required `.icns` sizes).
- Code signing with the user's Developer ID Application certificate.
- Notarization via `notarytool`.
- DMG packaging.
- README updates: install instructions, screenshots, GIF demo if feasible.
- Release notes for v0.1.0.
- A `CHANGELOG.md` following Keep a Changelog conventions.
- A GitHub release with the DMG attached.
- The `v0.1.0` git tag pushed to GitHub.
- A final cleanup pass: remove TODOs that haven't been addressed, ensure all ADRs are up to date, ensure the uncertainty log entries have either been resolved into ADRs or marked as `deferred to V0.2`.

Out:
- Sparkle update integration (planned V0.2).
- A Homebrew tap (planned V0.2).
- Internationalization beyond English (deferred indefinitely unless requested).

## Tasks

### 4.1 App icon

Generate a 1024×1024 PNG icon and the matching `.icns` containing all required sizes (16, 32, 64, 128, 256, 512, 1024 @1x and @2x).

The orchestrator does not generate icons via image-generation tools without user input. Instead, it surfaces `[ESCALATION: icon-asset]` and asks the user to either provide an icon, accept a placeholder SF Symbols glyph wrapped in an icon template, or commission one separately. A simple placeholder is acceptable for V1.

### 4.2 Signing identity

The orchestrator runs `security find-identity -v -p codesigning` and reports available signing identities. If the user has a Developer ID Application certificate, the orchestrator uses it. If not, the orchestrator surfaces `[ESCALATION: signing-identity-missing]` and asks the user to either obtain a certificate or proceed with ad-hoc signing (the latter would limit distribution to users willing to bypass Gatekeeper, which is acceptable but limiting).

The signing identity name is stored in `Build/signing-identity.txt` (gitignored, machine-local).

### 4.3 Code signing

Sign the app using `codesign --deep --force --options=runtime --entitlements ... --sign "<identity>" ...`.

Entitlements:
- Hardened runtime is enabled (required for notarization).
- App Sandbox is not enabled (ADR-003).
- No additional capability entitlements are added by default. The audio capture flow for process taps in an unsandboxed app is governed by `NSAudioCaptureUsageDescription` in `Info.plist`, not by an entitlement. `com.apple.security.device.audio-input` is the microphone-hardware entitlement for sandboxed apps; adding it to an unsandboxed app has no documented effect and may produce notarization or Gatekeeper surprises that are hard to diagnose after the fact.

The orchestrator verifies the exact entitlement requirements against current Apple documentation at the start of Phase 4. If current Apple documentation requires a process-tap-specific entitlement for unsandboxed apps with hardened runtime (none is documented as of the bundle's scribing date), the orchestrator adds it and writes a brief ADR. If no entitlement is required, the orchestrator commits the entitlements file (an empty `<dict/>` inside the plist, or omitted entirely) and records the verification in U-008.

The orchestrator writes `Build/sign.sh` containing the exact `codesign` invocation, committed to the repo. Phase 4 PRs include this script.

### 4.4 Notarization

Submit the signed app via `xcrun notarytool submit --keychain-profile <profile> --wait`. The keychain profile name is stored in `Build/notary-profile.txt` (gitignored). On success, staple the notarization ticket: `xcrun stapler staple <path>`.

If notarization fails, the orchestrator reads the notary log, surfaces the relevant errors, and addresses them. Common causes include unsigned helper binaries, missing entitlements, hardened runtime disabled. Each is documented in the script as a comment.

### 4.5 DMG packaging

Use `create-dmg` (Homebrew package) or `hdiutil` to produce `tap-n-filter-v0.1.0.dmg` with the app and an Applications-folder shortcut. The DMG is itself signed.

Output path: `Build/Release/tap-n-filter-v0.1.0.dmg`.

### 4.6 README and screenshots

Update README with:
- A screenshot of the menubar UI in use (orchestrator opens the app, captures via `screencapture -i`, but the user can also provide).
- A short GIF showing source selection → effect addition → audible result (described in caption rather than embedded if GIF capture is non-trivial).
- The corrected install instructions (link to DMG release).
- The factory preset list (already in template README; verify).

### 4.7 CHANGELOG.md

```markdown
# Changelog

All notable changes to tap-n-filter are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-XX-XX

### Added
- Initial release.
- Core Audio process tap–based capture from a chosen application.
- Parametric EQ with high-pass and low-pass bands.
- Reverb using AVAudioUnitReverb factory presets.
- `.tnf` preset save/load.
- Two bundled presets: distant-engines (the motivating preset) and dry (a baseline).
- MenuBarExtra-based UI.
- macOS 14.4+ support.
```

### 4.8 Final doc pass

The orchestrator does a sweep of all docs:
- Every ADR has a clear status (Accepted / Superseded / Deprecated).
- The uncertainty log: every entry is either resolved (with link to the resolving ADR), deferred to V0.2 (clearly marked), or escalated to user.
- The dissent log is complete: every option-between-options choice during build has a corresponding entry.
- README and CLAUDE.md reflect the actual built state.

### 4.9 Tag and release

```sh
git tag -a v0.1.0 -m "v0.1.0 - initial release"
git push origin v0.1.0
gh release create v0.1.0 Build/Release/tap-n-filter-v0.1.0.dmg \
  --title "v0.1.0" \
  --notes-file CHANGELOG.md \
  --latest
```

### 4.10 Surface acceptance request

The orchestrator surfaces:

```
PHASE 4 GATE: AWAITING acceptance
[RC_READY: Build/Release/tap-n-filter-v0.1.0.dmg]

The release candidate is built, signed, notarized, and posted as a GitHub release at <URL>. Please:

1. Download and install.
2. Run for a full listening session (suggest: a longer YouTube tab through the distant-engines preset).
3. Confirm the app does what you expect.

Reply [ACCEPT] to complete the build, or [REVISE: <what>] to request changes.
```

Then wait.

## Gate criteria

Phase 4 PASSES when ALL of the following are true:

1. Verification subagent confirms:
   a. `Build/Release/tap-n-filter-v0.1.0.dmg` exists and is signed + notarized (verified via `codesign --verify` and `stapler validate`).
   b. The DMG installs and the resulting `.app` launches without Gatekeeper warnings on a clean machine (if the orchestrator can't verify on a clean machine, it documents the verification approach in the report).
   c. The GitHub release exists with the DMG attached.
   d. README and CHANGELOG are updated.
   e. Final doc sweep complete (every ADR, dissent entry, uncertainty entry has a clear final state).
2. The user has confirmed `[ACCEPT]` in transcript.
3. `state.json` shows phase `4` → `passed` and `release_candidate_path` set.

If the user replies `[REVISE: <what>]`, the orchestrator addresses the request (which may involve looping back to an earlier phase). After addressing, re-build the RC and re-surface the acceptance request.

## Failure modes

- **Notarization fails repeatedly.** Common in first-time releases. The orchestrator reads `notarytool log <submission-id>` and addresses each error iteratively. If three attempts fail with different errors, surface `[ESCALATION: notarization-stuck]`.
- **DMG opens with a Gatekeeper warning on a fresh machine.** Indicates signing or stapling problem. Re-run sign + notarize + staple.
- **User rejects with a structural issue.** The orchestrator returns to whichever phase covers the issue (likely 2 or 3) and re-runs that phase's work, then re-runs Phase 4.

## Outputs

- Signed, notarized DMG at `Build/Release/`.
- GitHub release with DMG attached.
- `v0.1.0` git tag pushed.
- README and CHANGELOG updates.
- Final clean state in all docs.
- `state.json` shows all phases `passed`, `release_candidate_path` set, `user_acceptance` recorded.
