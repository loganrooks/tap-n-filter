# Changelog

Notable changes to tap-n-filter. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Build history before the first release is recorded per phase under
`docs/orchestration/state.json` and per decision under `docs/decisions/`.

## [Unreleased]

Work toward v0.1.0. Nothing has been tagged or released yet.

### Added

- Audio capture from a chosen application via Core Audio process taps, with a
  direct IOProc reader and a lock-free ring buffer (ADR-018).
- Configurable effect graph: parametric EQ, convolution reverb, and gain, each
  with bypass and per-node wet/dry mixing (ADR-007).
- Always-on output safety limiter, not user-defeatable, so a boosted gain
  cannot produce a headphone blowout (ADR-021).
- Menubar control panel: source picker, chain editor with button-based reorder
  (ADR-013), power toggle, status pill, and a debug log panel.
- Preset save and load as `.tnf` JSON files, plus the bundled `distant-engines`
  and `dry` factory presets.
- "Preserve Bluetooth quality during capture" setting (ADR-019, Layer A).
- Release bundler producing an ad-hoc-signed `.app` and a compressed `.dmg`.
- Accessibility labels, values, and hints across every control, with a
  committed accessibility-tree artifact and tests enforcing label discipline
  (ADR-011).

### Fixed

- Menu panel collapsed on macOS 27, taking the effect list with it. The chain
  editor's `ScrollView` was constrained only by `maxHeight` inside a window
  that sizes to its content's fitting height; height floors now keep the panel
  usable across OS versions (ADR-022).
- Interleaved tap buffers were mishandled, corrupting captured audio.
- Source resolution preferred bundle identifier over pid, so with several
  instances of one app running it could capture the wrong process.

### Known limitations

- **Not notarized.** v0.1.0 will ship ad-hoc signed, so Gatekeeper blocks the
  first open. The README documents the right-click-Open workaround. Developer
  ID signing is deferred (ADR-017).
- **Process granularity only.** Targeting is per-application; per-tab and
  per-window filtering are not achievable through process taps (ADR-020).
- **Bluetooth headsets may drop to HFP.** Capture can cause macOS to switch a
  Bluetooth device to the call profile, degrading audio to phone quality. The
  Layer A setting is shipped; the Layer B auto-switch mitigation is under
  active investigation (`docs/investigations/2026-05-audio-pipeline.md`).
- **No macOS 27 CI coverage.** GitHub Actions offers no macOS 27 runner, so
  the newest-OS check is a manual pre-merge step on the maintainer's machine
  (ADR-022).

[Unreleased]: https://github.com/rookslog/tap-n-filter/commits/main
