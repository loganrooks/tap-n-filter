# Roadmap

The durable plan for tap-n-filter beyond the V0.1 phase build. The phase system
in `../orchestration/plan.md` drove the initial build (Phases -1 through 4) and
terminates at v0.1.0. This file is the layer above it: the milestones and epics
that organize work after the linear build, so post-V1 work is tracked rather than
landing ad hoc.

## Model

- **Milestone** — a shippable version target (v0.1, v0.2, and so on).
- **Epic** — a coherent unit of work under a milestone, sized to a PR or a short
  series of PRs. Each epic carries a goal, a rationale, a status, exit criteria,
  and links to the ADRs, PRs, and investigations that realize it.
- **Status vocabulary** — `planned | in_progress | blocked | done`.

Epics decompose into PR-sized increments. Each PR is independently reviewable and
gated per `../governance/review-tiers.md`, which sets the review weight a PR gets
as a function of blast radius and reversibility. Epics marked **heavyweight**
additionally get the ceremony the phase system used: a framing audit, a
verification subagent, and an investigation notebook.

`state.json` remains the canonical status file. A proposed extension adds a
`milestones` object mirroring this file so the evaluator and future sessions read
epic status from one place. Until that schema lands as a separate, user-blessed
change, this file is the source of truth for roadmap status.

## Right-sizing ceremony

The Phase -1 through 4 build wrapped every change in a framing audit plus a
per-phase verification subagent. That was correct for a high-stakes greenfield
build. Applying it uniformly to a three-line fix over-provisions. The post-V1
default is a PR, the review tier the change warrants, and targeted verification.
The full ceremony is reserved for epics marked heavyweight below.

## M1 — Public-facing (v0.1 / v0.2)

Goal: a stranger can download, install, and use the app without hitting a broken
UI, phone-quality Bluetooth audio, or a Gatekeeper wall.

| Epic | Goal | Status | Notes |
|---|---|---|---|
| E1 Cross-version UI robustness | UI cannot collapse across macOS versions; regression-guarded | in_progress | PR #17 (height floors) + the no-dependency layout-contract test + ADR-022. The XCUITest smoke lane and CI matrix follow within M1. |
| E2 Bluetooth reliability | AirPods users keep A2DP quality during capture | planned | Layer A: the "Preserve Bluetooth quality" Settings toggle (ADR-019). Layer B: the HFP default-input auto-switch — the EXP-037 intervention; **heavyweight** (area under active investigation). |
| E3 Release prep (Phase 4) | Signed, notarized DMG; GitHub release; v0.1.0 tag; README + screenshots; CHANGELOG | planned | Gatekeeper is the biggest external blocker. ADR-017 deferred Developer ID for v0.1.0 — revisit here. The DMG bundler already exists (PR #14). |

Why M1 comes first: these are table stakes. A UI that vanishes on the current
macOS, phone-quality audio on the most common headphones, and an unsigned
download that Gatekeeper blocks each independently prevent "public-facing."

## M2 — Polish and depth (v0.2)

Goal: the app feels like a polished native tool and does meaningfully more without
feeling more complex.

| Epic | Goal | Status | Notes |
|---|---|---|---|
| E4 Native glass redesign | macOS 26+ materials; a cohesive native aesthetic | planned | Decide raise-min-target versus `#available` (the floor is macOS 14.4). Pairs with the design-critique work. |
| E5 Multi-app, same session | Filter several apps through one shared chain | planned | One aggregate device wrapping multiple sub-taps, one engine, one graph. Needs a multi-select source picker. |
| E6 Profiles | Named, switchable configurations; optional app-binding | planned | Extends `GraphPreset` with a profile store and UI. |
| E7 More effects | Delay and Distortion | planned | Already protocol-scaffolded (`AVAudioUnitDelay` / `AVAudioUnitDistortion`); low effort via the `EffectNode` protocol and registry. |

## M3 — Architecture horizon (v0.3 / v2)

Goal: independent concurrent sessions and third-party extensibility.

| Epic | Goal | Status | Notes |
|---|---|---|---|
| E8 Multi-app, different sessions | Independent chains per app, running concurrently | planned | N taps, N engines and graphs, N output mixes, and a session-management UI. **Heavyweight**: framing audit plus an investigation notebook. Bounded by ADR-020 (process-granularity floor; no per-tab). |
| E9 Distribution and extensibility | AUv3 hosting, Sparkle auto-update, Homebrew tap | planned | Sparkle and Homebrew were already named V0.2-out in the Phase 4 spec. |

## Constraints carried from V1

- ADR-020 fixes the targeting floor at process granularity; per-tab and
  per-window targeting are out of scope. The honest unlock for "finer than an
  app" is per-app multi-session plus the Add-to-Dock site-isolation path.
- No new top-level dependency without an ADR.
- Every change goes through a PR; no direct pushes to `main`.
