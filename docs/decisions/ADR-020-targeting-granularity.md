# ADR-020: Audio Targeting Granularity — Per-Tab and Per-Window Out of Scope

## Status

Accepted (2026-05-29). Constrains the source model committed in ADR-001 and
described in `docs/specs/architecture.md`. Sets the granularity the source
picker in `docs/specs/ui.md` is allowed to expose. Strengthens ADR-001's
rejection of ScreenCaptureKit.

## Context

A V0.2 planning pass asked whether tap-n-filter could target audio more
finely than a whole application — for example, capturing one Safari tab
(a single YouTube video) while leaving the rest of Safari alone, or running
different effect chains on different tabs. The desired hierarchy was
`computer (all audio) → app → window → tab`. This ADR records the answer,
because the result reframes a headline product goal and because the source
picker design depends on it.

The question was investigated against current documentation (Safari 18/26,
macOS 15 Sequoia and macOS 26 Tahoe) across four independent angles: the
Core Audio API surface, browser audio process models, native macOS capture
APIs (ScreenCaptureKit, automation), and shipping prior art. The four angles
converged with no substantive contradiction.

**Core Audio process taps are PID-granular.** ADR-001 commits V1 to
`AudioHardwareCreateProcessTap` with `CATapDescription`. The finest unit that
API can address is a process object (one PID). `CATapDescription` selects a
set of process objects to include or exclude; it has no sub-process scope.
No window-level or tab-level audio object exists anywhere in the HAL.

**Browsers consolidate every tab's audio into one shared process.** A tab's
content runs in a per-tab renderer (`WebContent` for WebKit), but the audio
output unit lives one level down in a single shared process that mixes all
tabs before any tap can reach it:

- Safari/WebKit renders output through the single `com.apple.WebKit.GPU`
  process — the one this project's own enumerator already surfaces as
  "Safari Graphics and Media" (see `2026-05-audio-pipeline.md:3738`,
  `source=Safari Graphics and Media (pid 77880)`).
- Chrome routes all renderer audio through one `audio.mojom.AudioService`
  utility process.
- Firefox outputs through a cubeb server in the parent process.

A tap on a browser therefore captures all of its tabs already mixed. Tapping
a per-tab renderer PID instead yields nothing, because that process never
owns the output unit.

**ScreenCaptureKit captures audio at the app level even when filtered to one
window.** SCK is the most window-aware capture API Apple ships, so it is the
likeliest place a per-window audio path could hide. Apple closes that door
explicitly, using Safari as the example, in the WWDC22 session "Take
ScreenCaptureKit to the next level": with a single-window content filter,
"all the audio content from the application that contains the window will be
captured, even from those windows that are not present in the video output,"
and "excluding audio from a single Safari window is the equivalent to
removing audio tracks for all Safari [windows]." The macOS 15/26 additions to
SCK add audio sources (microphone capture, recording output), not finer
scoping. This finding strengthens ADR-001: SCK offers no audio granularity
finer than the process tap already provides, so it is not even a fallback for
this goal.

**Prior art confirms the wall.** No shipping macOS tool (Rogue Amoeba Audio
Hijack / Loopback / SoundSource, eqMac, BackgroundMusic) offers per-tab or
per-window audio. Rogue Amoeba — the category-leading macOS audio vendor —
documents the boundary in the same terms: "when multiple pages are playing
audio in the same web browser, it's not possible to isolate the sound output
from a specific page."

The investigation is recorded in full in
`docs/investigations/2026-05-audio-pipeline.md` follow-ups and the V0.2
roadmap research. The one residual uncertainty (whether WebKit coalesces two
same-origin web-app renderers into a shared process) is undocumented and does
not change the verdict, because the shared-output-process consolidation holds
regardless.

## Decision

The addressable targeting hierarchy for tap-n-filter is:

```
System (all audio)  →  App-group (all PIDs of one app)  →  Single process
```

Per-window and per-tab targeting are **out of scope** for the process-tap
architecture, in V0.1 and for any tap-based version. The product goal "filter
one browser tab" is reframed to "filter the whole app." The source picker
must present granularity honestly and must not render any affordance that
implies tab-level or window-level capture.

A user who wants to isolate one **site** (not one tab) can do so by splitting
that site into its own OS process, which the existing process tap then
captures as a distinct source. The cleanliness of that path is
browser-specific:

- **Safari** — `File → Add to Dock` turns a site into a standalone web app
  with its own process. One click, built-in. The web app is scoped to the
  site, so it isolates "the YouTube app" from the rest of Safari, but not one
  video from another within it.
- **Chrome** — a separate instance launched with its own `--user-data-dir`
  (optionally `--app=URL`) gets its own private audio service. Documented
  flags, no third-party software, but not discoverable without a launcher.
  The built-in "Install as app" / PWA does not isolate audio; it shares the
  one audio service.
- **Firefox** — a separate profile launched with `-no-remote` gets its own
  parent process and cubeb server. macOS has no built-in install-as-app
  feature. The app-like third-party route (PWAsForFirefox) carries a
  patched-runtime trust burden and is not recommended to general users.

The source picker surfaces this as guidance (a "how to isolate a site"
explainer). The app does **not** automate the process-splitting in V0.1.

## Alternatives considered

### Browser extension (in-page Web Audio interception)

The only path to true per-tab filtering. An extension captures the tab's
audio inside the page (Chrome `tabCapture`, or a content script wrapping
media elements in a Web Audio graph) and applies effects in JavaScript.
Rejected as a direction for the tap-based product:

- It works on cooperating browsers only. `tabCapture` is Chromium-only;
  Safari and Firefox lack it, leaving the fragile per-element route.
- It cannot touch native apps (Spotify desktop, Music, games) at all.
- It goes silent on DRM-protected media (Netflix, Disney+, Spotify Web
  Player via Widevine/FairPlay) because the protected media path is walled
  off from capture APIs. The OS-level tap, by contrast, captures
  DRM-protected audio fine, since it reads decrypted PCM at the output —
  a capability the extension route would regress.
- It reimplements the effect chain in Web Audio, discarding the Swift
  `AVAudioEngine` DSP, and adds per-browser maintenance plus store review.

Parked as a separate, explicitly out-of-scope product surface. It would get
its own ADR and would only open after a pre-registered feasibility spike
proves a distinct per-tab audio PID exists and a tap on it isolates that tab
(predicted result: it does not).

### In-app per-site launcher

tap-n-filter could automate the process-splitting above — spawn the dedicated
Safari web app, Chrome `--user-data-dir`/`--app` instance, or Firefox
`-P`/`-no-remote` instance, then capture the spawned PID as its own source.
That turns the manual workaround into a one-click feature on all browsers.
Deferred, not rejected: it carries real complexity (per-site profile-directory
management, browser launching, instance lifecycle) and is a feature rather
than a scoping decision. Filed as a long-horizon candidate; it would get its
own ADR if committed.

### Pre-registered negative-result spike

Run an in-house experiment (two tabs playing two tones, FFT the captured
stream to show both tones present) to positively demonstrate the
shared-process mixing before cutting per-tab. Considered and not run: the
finding is documentation-confirmed three independent ways and already matches
this project's own observation (`Safari Graphics and Media (pid 77880)`), so a
spike would add in-house confirmation of a settled fact at the cost of a
session. The resurrection condition is a future macOS that splits browser tab
audio into distinct output processes; if that is ever observed, the spike
becomes worth running.

## Consequences

**Enabled:**

- An honest source picker: System audio, app-group (all PIDs of an app, with
  a process count), and single process, with an explainer where users look
  for tabs ("macOS captures audio per app; browser tabs share one process").
- A clear foundation for the V0.2 app-group and system-wide capture work,
  which widen the existing tap to a PID set rather than reaching for a finer
  granularity that does not exist.
- A documented, evidence-backed scope so the per-tab question is not
  re-litigated each session.

**Precluded or constrained:**

- The app cannot offer per-tab or per-video capture. "Filter this one YouTube
  video" is not a product capability and will not become one on the tap
  architecture.
- Per-site isolation requires the user to split the site into its own process
  themselves (Safari Add to Dock is the clean path; Chrome and Firefox need a
  separate instance). The app guides but does not perform this in V0.1.
- The product's honest positioning is per-application audio shaping, not
  per-tab or per-window control. Marketing and the first-run copy follow from
  this.

**Risks:**

- A future macOS or browser change could split tab audio into separate
  output processes, reopening the question. The resurrection condition is
  recorded above; the source picker copy is written so that widening
  granularity later is an additive change.

## References

- `docs/investigations/2026-05-audio-pipeline.md` — `:3738`
  (`Safari Graphics and Media (pid 77880)`), the project's own observation of
  WebKit audio-process consolidation.
- ADR-001 — capture API (Core Audio process taps, PID-granular). This ADR
  records why ScreenCaptureKit is not even a granularity fallback.
- ADR-003 — no sandbox in V1; the unsandboxed model does not unlock any finer
  audio targeting.
- `docs/specs/architecture.md`, `docs/specs/ui.md` — updated for the
  targeting hierarchy and the source-picker explainer.
- Apple, WWDC22 session 10155, "Take ScreenCaptureKit to the next level" —
  app-level audio capture policy (Safari window example).
- Rogue Amoeba knowledge base, "Capturing Web App Audio" — per-page isolation
  not possible; Add-to-Dock / site-as-app workaround.
- WebKit `GPUProcess` (RemoteAudioDestinationManager); Chromium
  `audio.mojom.AudioService`; Mozilla `audioipc` (cubeb) — the three browser
  shared-audio-process models.
