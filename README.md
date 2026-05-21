# tap-n-filter

A macOS app that captures audio from a specific application and routes it through a customizable chain of audio effects before playing back. Apply a lowpass and reverb to a YouTube tab while you work. Layer your own audio underneath. Save chains as presets and share them.

> **Status: in active development.** V1 is being built via an agentic workflow described under `docs/orchestration/`. This README will be revised once V1 ships.

## What it does

tap-n-filter sits between a source application (Safari, Chrome, Music, anything) and your audio output. It captures that application's audio via Core Audio process taps, runs the stream through a configurable graph of effects, and plays the processed result to your default output device. The original application is unaware of the interception.

The V1 effect graph includes:

- High-pass and low-pass filters (parametric, with adjustable cutoff and resonance)
- Convolution-style reverb (Apple's factory IRs in V1; custom IR support planned)
- Wet/dry mixing per effect
- Per-graph output gain

Effect chains are saved as `.tnf` files — Codable JSON describing the graph and parameter values. Presets travel as plain text. Share them via gist, GitHub, Discord, or however else you move files.

## Requirements

- macOS 14.4 or later (required for the Core Audio process tap API)
- Apple Silicon or Intel Mac
- About 50 MB of disk space

## Installation

V1 ships as a notarized `.dmg`. Drag-to-Applications install. The first run will prompt for audio capture permission — grant it, and tap-n-filter can route audio from any application you select.

A Homebrew cask formula is planned for V1.1.

## Usage

Once installed, tap-n-filter lives in your menubar.

1. Click the menubar icon to open the control panel.
2. Pick a source application from the dropdown (e.g., Safari).
3. Add effects to the chain. Adjust their parameters with the sliders.
4. Click the power toggle to start routing.

You'll hear the source application's audio with the chain applied, instead of its raw output.

To stop, click the power toggle again. tap-n-filter restores the source's normal output.

## Presets

Save the current chain as a preset via the File menu. Load a preset via the same menu. Presets are `.tnf` files — open one in a text editor and you'll see plain JSON. They're meant to be edited, forked, and shared.

A starter set of presets ships with the app:

- **distant-engines** — heavy lowpass at 800Hz, large hall reverb at 70% wet. The original ambient-engine-noise preset that drove the project.
- **submerged** — lowpass at 500Hz, plate reverb, slight modulation.
- **next-room** — gentle lowpass at 2.5kHz, small room reverb at 30% wet.
- **dry** — passthrough with a small gain trim. Useful as a baseline.

## For developers

tap-n-filter is a public project and contributions are welcome. The architecture is documented under `docs/`:

- `docs/specs/architecture.md` — system overview
- `docs/specs/audio-graph.md` — the effect graph model
- `docs/specs/effect-node-protocol.md` — how to add new effect types
- `docs/specs/capture.md` — how the Core Audio tap layer works

A future plugin format will let third-party developers ship effects as separate bundles. The V1 architecture supports this path but does not implement it. See `docs/decisions/ADR-002-plugin-architecture.md`.

## Building from source

```sh
git clone https://github.com/loganrooks/tap-n-filter.git
cd tap-n-filter
open Package.swift  # opens in Xcode
```

You'll need Xcode 16 or later and macOS 14.4 SDK.

To build a release `.app`:

```sh
xcodebuild -scheme tap-n-filter -configuration Release archive
```

## Project governance

This project is being developed with structured agent assistance. Decisions are documented as ADRs under `docs/decisions/`. Ongoing uncertainty and dissent are tracked in the logs in the same directory. Phase-by-phase build progress lives under `docs/orchestration/state.json`.

If you're reviewing a PR, see `docs/governance/review-protocol.md` for how automated review (CodeRabbit, Codex) and human review interact in this repo.

## License

MIT. See `LICENSE`.

## Acknowledgments

- The capture layer is built on the API documented by [insidegui/AudioCap](https://github.com/insidegui/AudioCap), which remains the best public reference for `AudioHardwareCreateProcessTap` and the broader Core Audio process tap surface added in macOS 14.4.
- The aesthetic that drove the original design — F1 onboards drowned in long reverb, layered under ambient — owes obvious debts to hauntological music and to a long lineage of slowed-and-reverb audio communities. tap-n-filter is a tool for making that kind of thing, not a claim of inventing it.
