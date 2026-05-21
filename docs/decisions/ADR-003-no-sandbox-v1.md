# ADR-003: No App Sandbox in V1

## Status

Accepted

## Context

macOS apps can be sandboxed (the App Sandbox) or unsandboxed. Sandbox status affects:

- **Distribution.** Mac App Store requires sandboxing. Direct distribution (signed and notarized) allows either.
- **Capabilities.** Sandboxed apps need explicit entitlements for capabilities (file system access outside the container, network, hardware access). Unsandboxed apps have free reign within macOS's user-level permissions.
- **AUv3 plugin hosting.** Many AUv3 plugins expect their host to be sandboxed and either refuse to load in non-sandboxed hosts or behave incorrectly.
- **User trust signals.** Sandboxed apps get a slightly better install experience on first run; macOS shows a less alarming Gatekeeper dialog.

For tap-n-filter V1:
- Distribution is via signed/notarized DMG, not the App Store. The user has not indicated interest in App Store distribution for V1.
- Capabilities needed: audio capture permission (via `NSAudioCaptureUsageDescription`), file open/save via standard panels (these work either way), no network, no other special hardware.
- AUv3 hosting is deferred to V2 (ADR-002).

## Decision

V1 ships **without the App Sandbox enabled**. The app uses the hardened runtime (required for notarization) and signs with the user's Developer ID Application certificate.

V1 is distributed as a signed, notarized DMG via GitHub Releases. Mac App Store distribution is not in V1's plan.

## Alternatives considered

### Sandbox the V1 app

Possible. Required entitlements would include:

- `com.apple.security.app-sandbox` (the sandbox toggle itself).
- `com.apple.security.device.audio-input` (for capture).
- `com.apple.security.files.user-selected.read-write` (for `.tnf` save/load via panels).

Rejected because:

1. Sandboxing introduces edge cases with the Core Audio process tap API. The API's interaction with sandboxed contexts is less well-documented; some references suggest the API still works in sandboxed apps with the right entitlements, but the orchestrator would need to verify. Adding this verification work to V1's scope risks delays.

2. The V2 AUv3 hosting plan needs careful thought about sandboxing semantics, and committing to a sandbox model in V1 locks in choices that V2 might need to revisit. Staying unsandboxed in V1 keeps more options open.

3. The V1 audience does not need Mac App Store distribution. Direct download is fine for the target user.

### Sandbox V1 AND ship to the App Store

Would require all of the above plus additional App Store review compliance work. Definitively out of scope for V1.

### Use a XPC helper for the unsandboxed parts

A pattern where the main app is sandboxed but a helper XPC service is unsandboxed for the parts that need it (audio capture). Rejected as overengineered for V1 — adds an XPC layer for negligible benefit.

## Consequences

**Enabled:**
- Simpler V1 implementation. No entitlement debugging, no sandbox-specific testing.
- Full access to system APIs without per-capability entitlement files.
- V2's AUv3 hosting story has more flexibility (sandbox-incompatible plugins can be hosted).
- Direct development cycle: build, sign, notarize, ship.

**Precluded or constrained:**
- No Mac App Store distribution in V1. The user has confirmed this is acceptable.
- First-launch Gatekeeper dialog is slightly more cautious than for sandboxed App Store apps. The README install instructions cover this.
- Users who specifically want App Store apps (some enterprise environments, some users with strong policies) won't be able to install V1. This audience is small for the V1 use case.

**Risks:**
- A future V1.x might want to sandbox for some reason (e.g., a user requests App Store distribution). The migration cost is moderate but real: entitlements, behavior testing, possibly some refactoring around file paths. Mitigation: code is written in a sandbox-friendly style as a default (no writes outside Application Support and user-selected files), so a future sandbox transition is mostly a configuration change.

- A future App Store reviewer might require sandboxing if V1 is later submitted. That would be a V1.x ADR overriding this one.

## V1 → V2 sandbox transition (if pursued)

If V2 decides to sandbox for App Store distribution:

1. Add `com.apple.security.app-sandbox` to entitlements.
2. Audit file I/O paths; ensure all writes go to Application Support or user-selected files.
3. Verify Core Audio process tap behavior in sandboxed context. May require additional entitlements (Apple's documentation will be the source of truth at that time).
4. Decide on AUv3 hosting compatibility — some plugins may refuse to load, requiring a curated allowlist or a hosted-helper architecture.
5. Submit to App Store with appropriate metadata.

The V1 → V2 transition is not blocked by this decision; this decision specifically preserves the option to make the transition without painting V2 into a corner.

## References

- `docs/specs/architecture.md` — sandbox section.
- `docs/decisions/ADR-002-plugin-architecture.md` — AUv3 hosting plan.
- Apple's "App Sandbox" documentation: https://developer.apple.com/documentation/security/app_sandbox
- `docs/orchestration/phases/04-polish-release.md` — Phase 4, where signing and notarization happen.
