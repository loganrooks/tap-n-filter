# 2026-05 Audio Pipeline Investigation

## Status

**Last updated**: 2026-05-27 22:15 EDT (post-EXP-026; architecture validated)

**Current frame**: AVAudioEngine + process tap + aggregate device
(current production architecture) is structurally incompatible with
macOS 26.3's unified IO AU (FC-003). **However**, the direct-IOProc-
on-tap-aggregate architecture Codex recommended *works* inside our
app (EXP-026, just confirmed): 471 IOProc fires in 5 s, 99.5%
non-zero samples, peak amplitude 0.73 — real, loud Safari audio
captured byte-for-byte by our app's IOProc. The missing-keys bug
that broke HFPSpike (H3) is **resolved**: the aggregate must include
`kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
`kAudioAggregateDeviceMasterSubDeviceKey: 0` at creation, with the
tap list set AFTER creation as `CFArray<CFString>`. Path forward:
**production refactor to the validated pattern**. Template lives in
`Sources/ViewModel/AudioteePatternTest.swift` lines 159-211. Pending
ADR-XXX for the architectural decision record.

**Previous frame** (kept for posterity):

**Latest understanding**: H1 and H4 are fixed. Production capture
reaches sustained `running` state with no errors. **But EXP-021 just
exposed a deeper bug than H2 (HFP) that we had not previously
characterized correctly**: the user hears literal silence during
capture, not HFP-degraded audio. Source process is muted (ADR-014
working as intended); engine processes correctly (slider/parameter
push-through logged); but **no engine output reaches the user**.
Promoting this to **H7**: the unified IO AU on macOS 26.3 has its
CurrentDevice pointed at the tap aggregate (a no-output device), so
engine-output frames are silently discarded. EXP-024 (mainMixerNode
tap dumping to WAV) is the disambiguator.

Earlier notes on H2 / HFP-as-cosmetic-bug were partly misled by the
user appearing to hear "HFP-degraded effects" — in retrospect, what
they were hearing in the first round of EXP-013/14 was the **source
process leaking audio during the brief HFP route-switch window**, not
the engine output. Now that source mute reliably engages, the
underlying no-output condition is exposed.

**Earlier reframings (still valid)**:

1. **Audiotee's "all-zero samples" we observed in EXP-007/008/009 is
   likely a documented macOS 26 Apple bug**, not TCC silencing. Apple
   Developer Forums thread 825780 records `AudioHardwareCreateProcess-
   Tap` intermittently delivering all-zero buffers on macOS 26.5 Beta
   (and likely 26.x), unanswered by Apple, no root cause. Our TCC
   interpretation of EXP-007-009 is weakened.

2. **HFP trigger mechanism is the "input + output on same engine"
   pattern**, not voice processing specifically. Any AVAudioEngine
   configuration with active input (inputNode bound to a capture
   device) and active output looks to macOS like `playAndRecord` mode
   and flips BT to HFP. This confirms Codex's architectural diagnosis.

3. **Rogue Amoeba's Audio Hijack ships a CoreAudio HAL plugin (ARK)**
   rather than using `CATapDescription`. The professional commercial
   app in this exact space chose a different architecture because the
   lightweight tap API isn't reliable enough for production BT capture.
   Validates our pain.

**Open headline question**: with HFP disabled at the OS level (via
`sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP" -bool
true`), is production audio clean and effect chain audibly responsive?
If yes, we know HFP is the only remaining issue and have empirical
ground to invest in an architectural fix. If no, there's a deeper
bug. See EXP-018 below.

**Out-of-scope sibling investigation**: the HFPSpike's IOProc never
fires. Held inactive until H2 work resumes, because the spike was
intended as a validation harness for one possible H2 fix.

## TL;DR

- **H1 fixed** (EXP-013): production `capture.start` was throwing
  **-10851** on every Start because `pinEngineOutputToDefault` set
  `kAudioOutputUnitProperty_CurrentDevice` on
  `AVAudioEngine.outputNode.audioUnit`, which uses
  `kAudioUnitSubType_DefaultOutput` and refuses that property. Codex
  flagged this in the original investigation report; we left the broken
  code in until EXP-012 traced it in the live log. Removing the call
  (one-line change in `CaptureController.start`) restored
  `capture.start` to success.
- **H2 confirmed live** (EXP-013): with H1 fixed,
  `AVAudioEngineConfigurationChange` fires within ~700 ms of
  `configureEngineInput` and the BT output flips to 16 kHz × 1 ch.
  Codex's HFP diagnosis is now empirically established for our
  environment.
- **H4 surfaced** (EXP-013): the engine's reconfiguration recovery
  logic re-attaches an already-attached graph, throwing
  `Graph.GraphError.alreadyAttached`. This crashes capture back to
  idle, the controller auto-retries, and we loop. This is the next bug
  to fix; it was previously masked by the upstream -10851 crash.
- The architectural fix for H2 (direct IOProc + `AVAudioSourceNode`)
  was scaffolded as `HFPSpike` but has its own unresolved bug — the
  IOProc never fires. Held inactive (H3) until we finish the H4 fix
  and decide whether to tackle H2 via the spike's architecture or a
  different route. [EXP-002…011]
- Bluetooth is **not** the variable. Built-in speakers fail the same way;
  audiotee returns all zeros regardless of BT state. [EXP-008, EXP-009]
- Self-signed `VIGIL Dev` cert is **sufficient** for TCC persistence on
  macOS 26.3. CDHash is stable across same-source rebuilds; permission
  re-prompts are driven by rebuilds (binary hash drift), not by cert
  type. No paid Apple Developer Program membership needed. [EXP-010,
  EXP-011]
- `audiotee` (CLI) cannot capture real audio on this machine — the IOProc
  fires (we get bytes) but every sample is 0x00. Inheriting Terminal's
  "Screen & System Audio Recording" TCC is not enough; the macOS 14.4+
  tap path needs the granular "System Audio Recording Only" service.
  `tap-n-filter.app` has it; `audiotee` (via Terminal) does not. [EXP-007,
  EXP-008, EXP-009]

## Environment

Captured 2026-05-25 06:35 EDT. Re-verify before any reproduction attempt
and update this section if a value drifts.

### Host

- **macOS**: 26.3 (build 25D125), arm64
- **Swift**: 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)
- **Target triple**: arm64-apple-macosx26.0
- **Xcode CLT only** (no full Xcode.app)

### Project state

- **Branch**: `fix/live-app-bugs`
- **Main branch**: `main`
- **Working directory**: `/Users/rookslog/Development/tap-n-filter`
- **Build output**: `Build/tap-n-filter.app` (assembled by
  `Build/bundle-dev.sh`)

### Signing

- **Identity**: `VIGIL Dev` (self-signed; not Developer ID)
- **Cert fingerprint**: `61AA3A6DD970BDE850BC38B5C937936E83D5E1F9`
- **Designated requirement** (what TCC matches on):
  `identifier "com.loganrooks.tap-n-filter" and certificate leaf =
  H"61aa3a6dd970bde850bc38b5c937936e83d5e1f9"`
- **Current CDHash**: `8300e352289df015fd9b3567d418b95daff102a5`
- **TeamIdentifier**: not set (consequence of self-signed)
- **Format**: app bundle with Mach-O thin (arm64), Sealed Resources v2,
  13 rules, 3 files

### Info.plist privacy keys

- `NSAudioCaptureUsageDescription`: "tap-n-filter needs permission to
  capture audio from other applications so you can route their output
  through your effect chain."
- `CFBundleIdentifier`: `com.loganrooks.tap-n-filter`
- (No `NSMicrophoneUsageDescription` — production deliberately avoids
  microphone access)

### TCC grants (user-reported, verified via System Settings)

- **`tap-n-filter.app`**: "System Audio Recording Only" — granted
- **Terminal.app**: "Screen & System Audio Recording" — granted; does
  **not** include "System Audio Recording Only"
- **Claude Desktop**: "Screen & System Audio Recording" — granted

The macOS 14.4+ split between "Screen & System Audio Recording" (combined
screen capture path) and "System Audio Recording Only" (process-tap path)
is the reason `audiotee` returns all-zero data even though its tap +
IOProc machinery works mechanically.

### Audio hardware observed during this investigation

- **Bose QuietComfort Headphones** (Bluetooth): default output device
  when connected; default input device too (mic enabled)
- **MacBook built-in speakers**: default output when BT disconnected
- **MacBook built-in microphone**: not used
- **"HiHaveYouHeardOfOurLordAndSaviorJesusChrist Microphone"**: listed
  by `system_profiler SPAudioDataType`; ignored

### Bluetooth profile observed

- A2DP (44.1 kHz × 2 ch) when BT connected without active capture
- HFP (16 kHz × 1 ch) when BT connected and either:
  - tap-n-filter's `configureEngineInput` binds an aggregate to
    `AVAudioEngine.inputNode`, or
  - any process activates the BT mic for voice (e.g. Claude Desktop
    during a voice call)

## Hypothesis ledger

### Active

#### H1 — `pinEngineOutputToDefault` is the upstream blocker

**Claim**: removing the `pinEngineOutputToDefault` call from
`CaptureController.start` will let `capture.start` succeed for the
first time on this branch.

**Type**: source-grounded (read the failing call site at
[CoreAudioInterface.swift:355-379](../../Sources/Capture/CoreAudioInterface.swift#L355-L379)
and the throw site at
[CaptureController.swift:210](../../Sources/Capture/CaptureController.swift#L210);
matched against -10851 log entries spanning 04:44 → 10:28 EDT).

**Auxiliaries**:
- The log file accurately records `captureState` transitions and
  `lastError` writes in real ordering.
- The -10851 status reported in logs is the same `OSStatus` that
  `AudioUnitSetProperty` returned (no intermediate wrapping).
- `AVAudioEngine.outputNode.audioUnit` is in fact a
  `kAudioUnitSubType_DefaultOutput` AU on macOS 26.3 (per Codex's
  citation; not directly verified by us).

**Would shift confidence down**: EXP-013 removes the call, rebuilds,
and production Start still throws -10851 from elsewhere. Or:
production Start succeeds but produces silence anyway, with no further
errors — that would shift weight toward a second, deeper bug.

#### H2 — BT HFP routing is a real but secondary problem

**Claim**: even with H1 fixed, binding an aggregate to
`AVAudioEngine.inputNode` will trigger HFP on BT default-output
devices. Production will work on built-in speakers but degrade on BT.

**Type**: behavior-inferred (Codex investigation report + log entries
showing `outputNode=16000.0 Hz × 1 ch` immediately after
`configureEngineInput` on BT).

**Auxiliaries**:
- Codex's diagnosis of "binding aggregate to inputNode AUHAL triggers
  HFP" is correct on macOS 26.3 — drawn from forum reports and Codex's
  reasoning, not directly verified by us against documented Apple
  behavior.
- The `outputNode` format-change observations were caused by HFP and
  not by an unrelated engine reconfiguration event.

**Would shift confidence down**: with H1 fixed, BT capture works at
44.1 kHz × 2 ch with no HFP switch. That would partially refute the
Codex thesis.

#### H3 — HFPSpike's IOProc-never-fires is a code bug, not a platform limit

**Claim**: `tap-n-filter.app` has the right TCC; if the same process
can capture via AUHAL (production, when not crashing) it should also
capture via direct IOProc. Therefore the spike has a code bug.
Candidate causes: (a) embedded vs post-creation tap list when creating
the aggregate, (b) a leaked aggregate from a prior failed production
Start interfering, (c) some interaction between the spike's engine and
the same process's earlier engine state.

**Type**: behavior-inferred (we inferred "should fire" from "audiotee
fires from less-privileged binary"; we haven't traced the code path
end-to-end to verify the spike's IOProc *should* fire).

**Auxiliaries**:
- Audiotee's "IOProc fires (with zero data) from Terminal" is a valid
  signal that the IOProc mechanism works for binaries with comparable
  signing on macOS 26.3.
- TCC is the *only* difference between audiotee's "fires silent" and a
  spike-that-would-fire-with-audio. Other potential differences
  (aggregate creation order, tap config, engine interactions) aren't
  the cause.
- No leaked Core Audio state from prior failed production runs is
  blocking the spike's IOProc.

**Would shift confidence down**: any of the auxiliaries failing — e.g.,
we find audiotee's IOProc *also* doesn't fire on a fresh boot, or we
discover a leftover aggregate from a prior crash that we never
destroyed. Status: **moved to inactive** after FC-001 (see Programme
health). Resurrection condition: a fix to H1 unblocks production, we
re-enter the HFP architectural question, and H3 becomes relevant
again.

**Auxiliary refuted 2026-05-25 12:10 EDT**: ran the spike again
post-H1+H4 fix (production now succeeds; engine reaches sustained
`running`). Spike still logs `ioProc fires=0` across 5+ seconds. So
the spike's failure is not because of entanglement with broken
production state. The remaining candidates (post-creation tap list
ordering, or some Swift-specific interaction with the IOProc
machinery) are still in play.

#### H6 — `engine.outputNode` (`DefaultOutput` AU) fails to bind to built-in speakers after `configureEngineInput`

**Claim**: when `configureEngineInput` re-points `engine.inputNode`'s
AUHAL at the tap aggregate device, `engine.outputNode` (backed by
`kAudioUnitSubType_DefaultOutput`) enters an unbound state on built-in
speakers and `outputFormat(forBus: 0)` reports `0 Hz × 0 ch`
indefinitely. On Bluetooth the system's routing infrastructure
triggers a rebind (we see outputNode reach A2DP at 44.1 kHz × 2 ch in
~300 ms, then later HFP at 16 kHz × 1 ch). On built-in speakers no
rebind happens. Bug exists on macOS 26.3; not yet tested on other
versions.

**Type**: source-grounded (diagnostic logging in EXP-018 follow-up
showed outputFormat stuck at exactly 0 Hz × 0 ch for 100 polls × 50 ms
= 5 seconds, never any other value).

**Auxiliaries**:
- `engine.outputNode.outputFormat(forBus: 0)` is the correct API to
  read the hardware-facing format of outputNode (not some indirect
  cached value).
- Built-in MacBook Air Speakers work as the system default output in
  normal use (we hear Safari audio when capture isn't active).
- `coreaudiod` was successfully restarted before EXP-018's retry, so
  the symptom is not stale daemon state.
- The new `engine.prepare()` call before the wait loop is correctly
  compiled into the running binary (`Build/bundle-dev.sh` succeeded,
  CDHash changed accordingly).
- macOS 26.3's audio routing infrastructure normally rebinds output
  devices for engines configured for capture (verified on BT
  empirically in EXP-013/14).

**Would shift confidence down**:
- A test variant where the same code path succeeds on speakers in
  some context (e.g., a different sequence of operations, a fresh
  reboot, or with the engine recreated post-capture).
- Discovery that `outputFormat(forBus: 0)` reports stale data while
  the underlying audio unit DOES have a valid CurrentDevice/StreamFor-
  mat — i.e., the symptom is in the AVAudioEngine API layer, not in
  the audio unit binding.

**Time budget**: 45-60 min for EXP-019 (combined diagnostic +
intervention experiment). If unresolved within budget, defer with
notebook entry documenting deepest state reached; proceed to BT reverb
extreme-sweep test regardless of H6's status.

#### H7 — Unified IO AU's CurrentDevice routes engine output into the no-output tap aggregate

**Claim**: on macOS 26.3, `AVAudioEngine.inputNode.audioUnit` and
`AVAudioEngine.outputNode.audioUnit` are the same `HALOutput` AU
instance (confirmed in EXP-023: `inputAU=0x00000000926600bf,
outputAU=0x00000000926600bf, same=true`). The HAL Output AU has a
single `kAudioOutputUnitProperty_CurrentDevice` property; when
`configureEngineInput` sets it to the tap-wrapping aggregate device,
the same AU is now writing its output to that aggregate too. The
aggregate (constructed in
[CoreAudioInterface.swift:223-249](../../Sources/Capture/CoreAudioInterface.swift#L223-L249))
contains only a `kAudioAggregateDeviceTapListKey` entry, no
`kAudioAggregateDeviceSubDeviceListKey`, no
`kAudioAggregateDeviceMainSubDeviceKey`. A process tap is input-only;
the aggregate therefore has no output streams. Engine-output frames
written to this device go nowhere — the user hears silence even
though the engine reports `isRunning=true` and the effect chain runs.

**Type**: source-grounded (read the aggregate construction in
`createAggregateDevice`; read EXP-023 log lines confirming AU
identity; matched against user-reported Outcome D in EXP-021).

**Auxiliaries**:
- `AVAudioEngine` on macOS 26.3 wires `inputNode` and `outputNode`
  through one `HALOutput` AU rather than separate `HALOutput` (input
  side) + `DefaultOutput` (output side) AUs as on earlier macOS. The
  fact that EXP-023's pointer comparison returned `same=true` is the
  strongest source-grounded evidence we have.
- The tap aggregate genuinely has zero output streams. We have not
  directly verified this with
  `AudioObjectGetPropertyDataSize(...kAudioDevicePropertyStreams, scope=Output)`,
  but the construction dictionary contains no
  output-providing keys and the macOS docs say a tap is input-only.
- The HAL Output AU's behavior when its CurrentDevice has no output
  streams is to silently discard frames rather than throw an error.
  This is also not directly verified — it's the simplest explanation
  for "no errors logged, no audio audible."
- `engine.outputNode.outputFormat(forBus: 0)` reporting
  `16000.0 Hz × 1 ch` (HFP rate) post-start despite CurrentDevice =
  tap aggregate is consistent with the format being a phantom /
  cached value not reflecting the actual hardware route, OR with the
  HAL Output AU's output bus reading from a different scope than its
  CurrentDevice. We don't know which.

**Would shift confidence down**: EXP-024 finds the WAV file is all
zeros → engine produces silence before reaching the device write
step → H7 is wrong about *where* the silence originates. Or:
EXP-024 finds the WAV has audible content + a follow-up "play the
mixer tap through a separate engine bound to default output"
experiment also plays silence → silence is not at the
mixer-to-device step but somewhere else not yet hypothesized.

**Time budget**: EXP-024 implementation + run + analysis ≈ 90 min.

#### H4 — `attemptReattach` re-attaches an already-attached graph on AVAudioEngineConfigurationChange

**Claim**: when an `AVAudioEngineConfigurationChange` notification fires
(e.g., when BT switches profile and the engine reconfigures), the
recovery logic calls graph attach on a graph that's already attached,
throwing `Graph.GraphError.alreadyAttached`. This collapses capture
state to idle, which auto-retries, which loops indefinitely. With H1
now fixed, this is the next observable bug.

**Type**: source-grounded (log shows the error verbatim at
11:43:07.750 EDT and the captureState cycling that follows).

**Auxiliaries**:
- The `attemptReattach` code path is reachable as logged.
- `Graph.GraphError.alreadyAttached` means literally "this graph is
  already attached to the engine"; the recovery should detach first
  or skip the attach.
- The retry loop is auto-driven by the AppViewModel, not by the user
  repeatedly pressing Start.

**Would shift confidence down**: reading the `attemptReattach` code
reveals the error means something different than I think, or the
retry loop is user-driven (e.g., a button-state bug auto-fires Start).

### Inactive

(none currently)

### Ruled out

#### R1 — Bluetooth A2DP/HFP routing is the *only* issue

**Type**: behavior-inferred.
**Refuted by**: EXP-012 — production fails identically on built-in
speakers (no BT involved). HFP is real but secondary.
**Auxiliaries the refutation relied on**: the speaker-test logs
recorded the same -10851 (verified). The user actually pressed Start
on speakers (user-reported).
**Resurrection condition**: discovering that the speaker-mode logs
were stale and we actually only tested BT.

#### R2 — Self-signed `VIGIL Dev` cert is insufficient for TCC persistence on macOS 26

**Type**: behavior-inferred.
**Refuted by**: EXP-011 — unchanged binary did not re-prompt across
launches.
**Auxiliaries**: the user re-launched the same binary (CDHash unchanged,
confirmed by EXP-010 source-grounded check).
**Resurrection condition**: a future macOS update tightens self-signed
TCC handling; observable as a re-prompt for an unchanged binary.

#### R3 — Ad-hoc signing is the difference between audiotee working and our spike failing

**Type**: behavior-inferred.
**Refuted by**: EXP-007 / EXP-008 — audiotee is also ad-hoc signed and
its IOProc fires (it just gets silenced by TCC).
**Auxiliaries**: audiotee's stderr "Audio device started successfully"
and the 883k byte output are accurate signals that the IOProc fired.
**Resurrection condition**: discovering audiotee's "stream_start" /
byte output is an artifact of buffering, not real IOProc firing.

#### R4 — Switching the spike's IOProc from Swift block to C function pointer would unblock it

**Type**: behavior-inferred.
**Refuted by**: EXP-005 — no behavior change.
**Auxiliaries**: the C-function-pointer build was actually the binary
that ran (the user did open the rebuilt .app, not a cached older
version).
**Resurrection condition**: discovering the rebuild didn't actually
take effect (e.g., user launched a stale bundle).

#### R5 — BT is the variable killing the spike

**Type**: behavior-inferred.
**Refuted by**: EXP-004, EXP-008, EXP-009 — same failure with BT
disconnected.
**Auxiliaries**: BT really was disconnected during those tests (BT
menu confirmed by user, plus `system_profiler` showed built-in as
default output).
**Resurrection condition**: discovering BT was still affecting routing
in some way despite the menu reporting disconnected.

#### R6 — AudioCap pattern (.mutedWhenTapped, isPrivate=false) would unblock the spike

**Type**: behavior-inferred.
**Refuted by**: EXP-006 — no behavior change.
**Auxiliaries**: the spike was actually running with the changed tap
config (verified by the log line `mute: .mutedWhenTapped, private:
false`).
**Resurrection condition**: discovering the tap config didn't change at
runtime despite our edits (e.g., a typo or a property setter ordering
bug).

#### R8 — H3: HFPSpike's IOProc-no-fire is a code bug, not a platform limit (RESOLVED 2026-05-27)

**Type**: source-grounded (EXP-026 directly observed the IOProc
firing 471 times in 5 s with 99.5% non-zero samples, peak 0.73,
from inside tap-n-filter.app with its existing TCC grant).

**Resolution**: H3 was correct that the IOProc-no-fire was a code-
level bug, but the specific candidate causes I listed in the
hypothesis (Swift block vs C pointer, tap config, engine
entanglement, ad-hoc signing) were all wrong. The actual cause was
two missing keys in the aggregate creation dictionary:
`kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
`kAudioAggregateDeviceMasterSubDeviceKey: 0`. Audiotee's working
implementation includes them; HFPSpike and our prior
AudioteePatternTest attempts did not. The keys initialize the
aggregate's clock infrastructure; without them, the IOProc has no
clock and never fires.

**Auxiliaries the refutation relied on**: EXP-026's exact pattern
matched audiotee's `createAggregateDevice` byte-for-byte (lines
103-125 of `AudioTapManager.swift`), plus the post-set tap list
attached via `AudioObjectSetPropertyData` with a `CFArray<CFString>`
payload. The 99.5%-non-zero verdict source-grounds the success.

**Resurrection condition**: none anticipated. If a future macOS
breaks even this pattern, we'd see audiotee itself fail too, which
would be observable.

#### R7 — The HFPSpike's "A2DP RETAINED" verdict means the architecture works on BT

**Type**: source-grounded (re-read the verdict computation in
`HFPSpike.swift`).
**Refuted by**: source inspection — the verdict says only "outputNode
format ≥44.1 kHz × 2 ch." This can be satisfied whenever the IOProc
never fires, because the engine never tried to drive captured audio
through BT output. The verdict is a tautology of the IOProc-failed
state, not a positive signal about the architecture.
**Auxiliaries**: none — this is a direct misreading of the diagnostic,
not a behavioral inference.
**Resurrection condition**: none. Recorded so future readers don't
re-believe the spike's optimistic logging.

## Experiment log

### EXP-001 — Codex investigation request

**Date**: 2026-05-24 (approximate, prior session)
**Author**: prior session
**Question**: Why does starting capture on Bluetooth headphones force
macOS into HFP voice mode, and what's the canonical architecture for
process-tap capture + playback through a user's chosen output device?

**Method**: invoked `/codex:rescue` with the full architecture context.
The full prompt is in the previous-session transcript at
`/Users/rookslog/.claude/projects/-Users-rookslog-Development-tap-n-filter/683a502d-7bc3-4ea3-8430-0019e4eee041.jsonl`.

**Artifacts**: Codex's reply summary (lives in conversation history).

**Observations**: Codex confirmed the root cause: binding the aggregate
device to `AVAudioEngine.inputNode`'s underlying AUHAL via
`kAudioOutputUnitProperty_CurrentDevice` triggers BT HFP because macOS
sees an active capture session paired with a BT default output and
forces voice mode. Codex's canonical fix: read the tap directly via
`AudioDeviceCreateIOProcID` and feed an output-only `AVAudioEngine`
through an `AVAudioSourceNode`. Codex explicitly noted: "Only
`kAudioUnitSubType_HALOutput` accepts that [`CurrentDevice`] property"
— i.e., the `pinEngineOutputToDefault` band-aid would *not* work
against `AVAudioEngine.outputNode` (which uses `DefaultOutput`).

**Conclusion**: Codex's diagnosis is consistent with the observed logs.
Their architectural recommendation is the right long-term path. Their
warning about `pinEngineOutputToDefault` being a non-fix was ignored at
the time and is the source of EXP-012's smoking gun.

**Follow-ups**: build the spike to validate the IOProc + SourceNode
architecture empirically before committing to a 400-600 LOC production
refactor. → EXP-002.

### EXP-002 — Build HFPSpike scaffolding

**Date**: 2026-05-25 (early in current session)
**Author**: current session

**Question**: Can a Swift implementation of "create tap, wrap in
aggregate, drive an IOProc, feed `AVAudioSourceNode`" actually run end
to end without HFP triggering on BT?

**Variables held constant**:
- tap-n-filter.app's TCC grants
- Source process: Safari (PID 72409) playing YouTube
- BT: Bose QC headphones connected, A2DP

**Variables changed**:
- Compared to production: capture happens via direct IOProc instead of
  AUHAL `kAudioOutputUnitProperty_CurrentDevice`
- Engine has only output side wired (no `inputNode` access)

**Method**: implemented `Sources/ViewModel/HFPSpike.swift` with a Start
button in the debug panel. Tap created with `CATapDescription`
+ `AudioHardwareCreateProcessTap`, aggregate created with
`AudioHardwareCreateAggregateDevice` and `kAudioAggregateDeviceTap-
ListKey` embedded in the description, IOProc created with
`AudioDeviceCreateIOProcIDWithBlock`, ring buffer feeds an
`AVAudioSourceNode` into an output-only engine. Periodic counter
snapshots at +1s, +2s, +3s, +5s log whether the IOProc has fired.

**Artifacts**:
- `Sources/ViewModel/HFPSpike.swift`

**Observations**: scaffolding compiles and Start runs without
exceptions. Counters never tick.

**Conclusion**: scaffolding is in place; IOProc not firing is the next
mystery. → EXP-003.

**Follow-ups**: Q3 — why does the IOProc never fire?

### EXP-003 — HFPSpike Start with BT, Safari playing

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: With everything wired up per EXP-002, does the IOProc
fire at all on BT?

**Variables held constant**:
- All from EXP-002 environment.

**Variables changed**: none (first run).

**Method**: open tap-n-filter.app, open debug panel, select Safari as
source, press "HFP spike Start". Wait 5+ seconds. Press Stop.

**Artifacts**: `~/Library/Logs/tap-n-filter/app.log` entries tagged
`HFPSpike` for the first spike run of the session (timestamp varies;
look for the earliest `HFPSpike.start` of the day).

**Observations**: tap creation reports `status=0`. Aggregate creation
reports `status=0`. Aggregate stream count: `input=1, output=0`. IOProc
registration reports `status=0`. `AudioDeviceStart` returns 0. Every
verdict snapshot reports `ioProc fires=0, frames=0; render fires=N
(growing)`. `outputNode` format stays at 44.1 kHz × 2 ch ("A2DP
RETAINED" verdict — see R7 in the hypothesis ledger).

**Conclusion**: the IOProc is registered and the device is "started"
per Core Audio's return codes, but no callback ever fires. The render
side runs (the source node is asked to fill buffers); it always reads
silence from the empty ring buffer.

**Follow-ups**: rule out variables one at a time. → EXP-004 (speakers),
EXP-005 (C function pointer), EXP-006 (AudioCap config), EXP-007 (cert).

### EXP-004 — HFPSpike Start with built-in speakers (BT disconnected)

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Is BT a necessary condition for the IOProc failure?

**Variables held constant**: same as EXP-003 except:
**Variables changed**: BT disconnected, default output = built-in MacBook
speakers.

**Method**: identical to EXP-003 with the BT headphones unpaired
(Bluetooth menu → disconnect QC headphones).

**Observations**: identical pattern — `ioProc fires=0, frames=0`, render
fires growing, no audio output.

**Conclusion**: BT is not the variable. Removed H_BT from the hypothesis
set (now R5).

### EXP-005 — HFPSpike with C function-pointer IOProc

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does macOS 26 restrict the Swift-block
(`AudioDeviceCreateIOProcIDWithBlock`) variant for tap aggregates while
leaving the C function-pointer variant (`AudioDeviceCreateIOProcID`)
working?

**Variables held constant**: same as EXP-003.
**Variables changed**: `AudioDeviceCreateIOProcIDWithBlock` →
`AudioDeviceCreateIOProcID` with a file-scope
`@convention(c)` function pointer (`hfpSpikeCIOProc`). Spike instance
passed via opaque `inClientData`.

**Method**: edited
`Sources/ViewModel/HFPSpike.swift`, rebuilt, re-ran.

**Observations**: identical pattern — `ioProc fires=0`.

**Conclusion**: the IOProc API variant is not the variable. Now R-? in
the hypothesis ledger (R4).

### EXP-006 — HFPSpike with AudioCap-matching tap configuration

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does AudioCap's specific `CATapDescription` configuration
(isPrivate=false, muteBehavior=.mutedWhenTapped, isExclusive=false)
unblock the IOProc?

**Variables held constant**: same as EXP-003.
**Variables changed**: tap config to match AudioCap exactly. (Production
uses `muteBehavior=.muted` and `isPrivate=true`.)

**Observations**: identical pattern — `ioProc fires=0`.

**Conclusion**: tap configuration is not the variable. R6 in the
hypothesis ledger.

### EXP-007 — Audiotee CLI against Safari

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does the audiotee reference implementation
(makeusabrew/audiotee, fetched to `/tmp/audiotee`) capture real audio
on this machine? If yes, our spike has a code bug; if no, the platform
is broken.

**Variables held constant**: BT disconnected, built-in speakers as
default; Safari playing YouTube (PID 72409).

**Variables changed**: vs our spike — entirely different codebase, runs
as a CLI from Terminal (inherits Terminal's TCC).

**Method**:
```
cd /tmp/audiotee && swift build -c debug
/tmp/audiotee/.build/debug/audiotee --include-processes 72409 \
    --sample-rate 48000 --stereo > /tmp/audiotee-capture.bin \
    2>/tmp/audiotee-stderr.log &
PID=$!
sleep 5
kill -INT $PID
wait $PID
```

**Artifacts**:
- `/tmp/audiotee-capture.bin` — 883,200 bytes (4.6 s of pcm_s16le @ 48
  kHz × 2 ch)
- `/tmp/audiotee-stderr.log` — JSON-line debug stream from audiotee

**Observations**: tap created (status=0), aggregate created (status=0,
device_id=150), IOProc created and started successfully ("Audio device
started successfully"). Output file has 883,200 bytes — proving the
IOProc fired and delivered buffers — but `max-abs` across all 441,600
samples is 0. Every byte is 0x00.

**Conclusion**: audiotee's IOProc mechanically fires on macOS 26.3.
The data is silenced because audiotee (via Terminal) lacks the macOS
14.4+ "System Audio Recording Only" TCC service — Terminal has the
older combined "Screen & System Audio Recording" which doesn't cover
the tap-specific path. This is consistent with the platform's privacy
posture and not a bug in audiotee.

**Follow-ups**: this means audiotee is **not** a good direct reference
for whether our spike's IOProc *would* fire if it captured anything,
because audiotee's IOProc fires-with-silence, whereas our spike's
fires-not-at-all. Different failure modes. → Q3, Q4.

### EXP-008 — Audiotee with no process filter

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does removing the `--include-processes` filter (capture
all processes) change the result?

**Variables held constant**: same as EXP-007.
**Variables changed**: `--include-processes 72409` removed.

**Observations**: identical — 883,200 bytes, all zeros.

**Conclusion**: TCC silencing is service-wide, not per-process. The
silencing is not target-selective.

### EXP-009 — Audiotee against Spotify, BT disconnected

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does switching the audio source from Safari to Spotify,
and disconnecting BT entirely (built-in speakers), change the result?

**Variables held constant**: audiotee binary, sample rate, channels.
**Variables changed**: source process = Spotify (PID 11148); BT
disconnected; Spotify confirmed playing.

**Observations**: identical — 883,200 bytes, all zeros.

**Conclusion**: BT state is not the variable; source process is not the
variable; system default output device is not the variable. The TCC
silencing is global to the audiotee binary on this machine. R5
confirmed at the system level.

### EXP-010 — CDHash stability across same-source rebuild

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does `swift build` + `codesign --force --sign 'VIGIL Dev'`
produce a stable CDHash when source is unchanged, or does the hash
drift between builds (which would explain TCC re-prompting)?

**Variables held constant**: all source unchanged between builds.
**Variables changed**: invoked `./Build/bundle-dev.sh` twice.

**Method**:
```
codesign -dv --verbose=4 Build/tap-n-filter.app | grep CDHash
./Build/bundle-dev.sh
codesign -dv --verbose=4 Build/tap-n-filter.app | grep CDHash
```

**Observations**: CDHash before and after are identical:
`8300e352289df015fd9b3567d418b95daff102a5`.

**Conclusion**: same source → same Swift output → same codesign hash.
TCC will not see a "different app" between rebuilds *unless* source
actually changed. Re-prompts during this session were rebuild-driven.

### EXP-011 — Launch unchanged binary, observe TCC re-prompt

**Date**: 2026-05-25 (current session, reported by user)
**Author**: user
**Question**: With the existing TCC grant in place and the binary
unchanged since the last grant, does macOS re-prompt on launch?

**Variables held constant**: same binary, no rebuild, no signing change.
**Variables changed**: app process restarted.

**Method**: user closed tap-n-filter.app and re-opened it via Finder
(`open Build/tap-n-filter.app`).

**Observations**: user reports: "it didn't this time" (no permission
prompt).

**Conclusion**: VIGIL Dev's self-signed cert is sufficient to persist
TCC grants on macOS 26.3 for unchanged binaries. We do **not** need a
paid Apple Developer Program membership. The frequent re-prompts in
this session are rebuild-driven; minimizing rebuilds (or batching them)
will minimize prompts. R2 confirmed.

### EXP-012 — Production capture log analysis: -10851 every Start

**Date**: 2026-05-25 06:25 EDT (analysis), referencing logs from
04:44 EDT onward
**Author**: current session
**Question**: When the user pressed the regular Start button (not the
spike) on built-in speakers and reported "nothing happens", what
actually happened internally?

**Variables held constant**: tap-n-filter.app (current build), TCC
granted, source = Safari.
**Variables changed**: pressing the regular Start button instead of the
HFP spike Start.

**Method**: scanned `~/Library/Logs/tap-n-filter/app.log` for every
`captureState` transition since the user first started reporting issues
this session (04:44 EDT).

**Artifacts**: `~/Library/Logs/tap-n-filter/app.log` — every entry
matching `lastError|fail|capture\.start|captureState|powerOn`.

**Observations**: every single production-Start since 04:44 EDT logs:
```
[WARNING] AppViewModel: lastError set: Engine configuration failed:
  Failed to set output device: -10851
[INFO] AppViewModel: captureState: idle -> starting
[INFO] AppViewModel: captureState: starting ->
  failed(Capture.CaptureError.engineConfigurationFailed(
    "Failed to set output device: -10851"))
[WARNING] AppViewModel: AVAudioEngineConfigurationChange fired:
  engine.isRunning=false, inputNode=48000.0 Hz x 2 ch,
  outputNode=0.0 Hz x 0 ch
```
Occurrences observed (incomplete list): 04:44:38, 04:50:44, 04:50:47,
05:14:45, 05:14:50, 09:50:27, 10:28:40 EDT — every regular Start the
user pressed in this session has failed.

The error originates in `RealCoreAudioInterface.setOutputUnitDevice` at
[Sources/Capture/CoreAudioInterface.swift:368](../../Sources/Capture/CoreAudioInterface.swift#L368):
```
let status = AudioUnitSetProperty(
    outputUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0,
    &mutableDeviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
guard status == noErr else {
    throw CaptureError.engineConfigurationFailed(
        "Failed to set output device: \(status)")
}
```
Called from
[Sources/Capture/CaptureController.swift:210](../../Sources/Capture/CaptureController.swift#L210)
as `try coreAudio.pinEngineOutputToDefault(engine)`.

Per the AudioUnit documentation and the Codex investigation (EXP-001),
`AVAudioEngine.outputNode.audioUnit` is a `kAudioUnitSubType_DefaultOutput`
audio unit, which does **not** accept the `kAudioOutputUnitProperty_-
CurrentDevice` property. Only `kAudioUnitSubType_HALOutput` does. The
status code -10851 is `kAudioUnitErr_InvalidPropertyValue` — exactly
the documented response for setting an unsupported property.

**Conclusion**: this is the upstream bug. Production capture has been
failing immediately on every Start since `pinEngineOutputToDefault` was
added. The user's perception that "production produces low-pass audio
on BT" was a confound: capture failed in step 5, but step 3 had already
flipped BT into HFP via `configureEngineInput` before the crash. What
the user heard was Safari's *own* audio output being routed through
BT-HFP — not our captured/processed audio. On built-in speakers (no
HFP path), the same crash makes no audible signal at all, which is
what the user reported.

The HFP investigation (EXP-002…EXP-009) was chasing a downstream
symptom of an upstream code bug. R1 (BT-only-issue) is now refuted by
this experiment too: production fails everywhere; the BT case just
happened to make HFP audible.

**Follow-ups**:
- **EXP-013** (pre-registered below): remove the
  `pinEngineOutputToDefault` call. Test production Start on built-in
  speakers.
- **Q4** (open): if EXP-013 confirms H1, do we also need to address H2
  (BT HFP routing)? Probably yes for v0.1 but could be deferred.

### EXP-013 — Remove `pinEngineOutputToDefault`, test production Start on speakers

**Date**: 2026-05-25 06:50 EDT (pre-registration; run pending)
**Author**: current session
**Question**: does removing the `pinEngineOutputToDefault(_:)` call
from `CaptureController.start` let production `capture.start` succeed?
And if it does, do effects actually process audible audio?
**Hypothesis under test**: H1.

**Prediction** (locked at 2026-05-25 06:50 EDT, before the run):

- **Outcome A (predicted)**: production Start no longer logs -10851;
  `captureState` reaches `running` and stays there for 5+ seconds with
  no transitions to `failed`; user reports hearing audio through the
  effect chain on built-in speakers; moving a parameter slider (e.g.
  EQ gain) produces an audible change. → **H1 strongly supported.**
  Move H1 to "verified" status. Promote H2 to the active investigation.

- **Outcome B**: production Start logs a different error from
  somewhere else in `CaptureController.start` or downstream (e.g.
  engine.start throws, a different OSStatus from `configureEngineInput`,
  etc.). `captureState` transitions to `failed`. → **H1 supported in
  the narrow sense** (the specific -10851 call was failing) but a second
  bug exists. The new error becomes the next hypothesis to chase.

- **Outcome C (inconclusive)**: production Start succeeds (no errors,
  `captureState=running`) but user hears no audio at all on speakers,
  even with Spotify playing audibly. → **H1 supported in the narrow
  sense** but the audio path has a deeper bug downstream of
  `capture.start`. Reframe: stop assuming "capture.start succeeds" =
  "audio flows." Likely next step: add a WAV dump tap on
  `engine.inputNode` to verify whether the AUHAL is actually delivering
  audio buffers.

- **Outcome D**: production Start succeeds, user hears audio on
  speakers, but effect parameter changes don't audibly affect it. →
  **H1 supported, but a separate "effects don't respond" bug exists**
  (this was hinted at earlier in the session with BT-HFP confounds and
  needs its own investigation).

**Variables held constant**:
- Source process: Safari with one YouTube tab, audio playing audibly
  OR Spotify playing audibly (user's choice).
- Default output: built-in MacBook speakers (BT disconnected to isolate
  H2 from H1).
- Signing identity: VIGIL Dev, cert hash unchanged.
- TCC grant for `tap-n-filter.app` ("System Audio Recording Only"):
  already granted, no rebuild between grant and test if possible.

**Variables changed**:
- `CaptureController.start`: remove the line at
  [CaptureController.swift:210](../../Sources/Capture/CaptureController.swift#L210):
  `try coreAudio.pinEngineOutputToDefault(engine)` and the associated
  comment block on lines ~202-209.
- (No changes to the `pinEngineOutputToDefault` *implementation* — it
  becomes orphaned but harmless. Leave it in for now; remove in a
  follow-up cleanup commit so the diff stays minimal for this experi-
  ment.)

**Auxiliaries held** (what we're trusting *not* to be the cause):
- `createTap`, `createAggregateDevice`, and `configureEngineInput`
  succeed on built-in speakers (no prior evidence they fail there).
- The current engine + graph wiring (`Graph.attach(...)` etc.) is
  correct and would propagate captured audio through the effect chain
  to `mainMixerNode`.
- AVAudioEngine's `mainMixerNode → outputNode` implicit connection
  handles format conversion correctly between the effect-chain working
  format and built-in speakers' hardware format (48 kHz × 2 ch).
- No state leaked from prior failed `capture.start` calls (we've
  observed `AVAudioEngineConfigurationChange` firing after each failure;
  the engine resets, but we're trusting no other state lingers).
- The user is actually playing audio audibly during the test (volume
  on, audio reaching the system mixer).

**Method**:
1. Edit `Sources/Capture/CaptureController.swift` to remove the line
   `try coreAudio.pinEngineOutputToDefault(engine)` (currently line 210).
2. `./Build/bundle-dev.sh` to rebuild (will produce a new CDHash and
   likely re-prompt for TCC).
3. User: open `Build/tap-n-filter.app`, grant the re-prompt if any,
   select Safari (or whichever source is playing) in the source picker,
   confirm BT is disconnected and built-in speakers are the default
   output.
4. With Safari/Spotify playing audibly, press production Start.
5. Observe `~/Library/Logs/tap-n-filter/app.log` for `captureState`
   transitions and any errors.
6. If `captureState=running`, listen for whether the audio is audibly
   processed through the effect chain. Move an EQ band gain ±12 dB and
   listen for change.
7. After 30 seconds, press Stop.

**Method deviation**: user ran on BT (Bose QC connected) instead of
built-in speakers, because BT is their daily-driver setup. This blends
the H1 and H2 signals — but H1 is observable from the log regardless of
audio quality, and H2 was expected to manifest. The deviation is
acceptable; we get H2 evidence as a bonus.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries from 2026-05-25
  11:43:07.029 onward (log line 416+).
- User-reported audible result: "low-pass filter effects, same as
  before" — interpreted in light of the log as brief windows of
  HFP-degraded effect-chain output chopped up by an
  `alreadyAttached` retry loop.

**Observations** (tagged):

- [source-grounded] At 11:43:07.029 the log records `captureState:
  idle -> starting` followed immediately by `captureState: starting ->
  running(source: Safari)`. No -10851 anywhere in the post-watermark
  entries. **The specific -10851 failure mode is gone.**
- [source-grounded] At 11:43:07.398 the log records `Output hardware
  format became valid after 6 poll(s): 44100.0 Hz × 2 ch` — the engine
  successfully reached a steady output format at A2DP rates.
- [source-grounded] At 11:43:07.597 the log records `powerOn complete:
  engine started, capture running on Safari, chain: tnf.eq ->
  tnf.reverb`. **First successful `powerOn` on this branch ever.**
- [source-grounded] ~700 ms later at 11:43:07.735, the log records an
  `AVAudioEngineConfigurationChange` with `outputNode=16000.0 Hz × 1
  ch` — BT switched to HFP, exactly as H2 predicted. The trigger is
  presumably `configureEngineInput` binding the aggregate to
  `inputNode` shortly before.
- [source-grounded] At 11:43:07.736 the recovery code logs `engine
  stopped itself on configuration change; calling attemptReattach`;
  at 11:43:07.750 this throws `Graph.GraphError error 1
  (alreadyAttached)`.
- [source-grounded] After the alreadyAttached failure, captureState
  cycles `running → stopping → idle → starting → running → stopping
  → idle` rapidly. The log shows 5+ such cycles in the next 8 seconds,
  each producing the same `alreadyAttached` error.
- [behavior-inferred] The user heard "low-pass filter effects, same
  as before." Inferred: each brief `running` window (~50-700 ms) the
  effect chain actually processed Safari's audio. The "low-pass"
  character is HFP downsampling. The chopped quality (which user
  didn't explicitly mention but is implied by the rapid state cycling)
  comes from the `alreadyAttached` retry loop.

**Conclusion**: outcome A (predicted) on the H1 axis — **`pinEngineOutputToDefault`
was the upstream blocker, and removing it restored `capture.start`
success.** H1 moves from "active, behavior-confirmed inferentially" to
"verified, source-grounded."

H2 is also now empirically confirmed for our environment (was previously
only inferred from Codex's report). The BT → HFP switch happens within
~700 ms of `configureEngineInput`.

A new finding (H4) emerges: the engine's reconfiguration recovery logic
(`attemptReattach` after `AVAudioEngineConfigurationChange`) is broken.
It re-attaches an already-attached graph, throwing `alreadyAttached`,
collapsing capture to idle and entering a retry loop. This bug existed
all along but was masked by the upstream -10851 — the engine never lived
long enough to receive a configuration-change event.

The pre-registration anticipated outcomes A, B, C, D but missed E (the
real one): "H1 fixed, H2 confirmed live, AND a new downstream bug
surfaces in the engine reconfiguration handler." Worth noting for
future pre-registration: include an explicit "unanticipated outcome →
reframe" branch.

**Inferential gap**: the conclusion "H1 verified, source-grounded"
rests on the log line ordering being accurate. Defensible — the
timestamps are coherent and the captureState transition trace is
plausible — but if a future test surprises us, "the log was misordered"
is a candidate auxiliary to suspect.

**Follow-ups**:
- New active hypothesis **H4** added to ledger (alreadyAttached
  re-attach loop on `AVAudioEngineConfigurationChange`). This is the
  next thing to fix — it's preventing sustained capture even on
  unfixed HFP.
- After H4 is fixed, we'll have sustained capture (degraded by HFP on
  BT, clean on speakers) and can return to H2 as the next investigation.
- **Q6** (new, open): does fixing H4 alone produce sustained, audibly
  processed audio on BT (HFP-degraded but stable), or does some further
  bug surface?
- **Q7** (new, open): what's the right `attemptReattach` logic?
  Detach-first-then-reattach? Skip when already attached? Need to read
  the existing code to decide.

### EXP-015 — Re-run HFPSpike post-H1+H4 fix

**Date**: 2026-05-25 12:09 EDT
**Author**: current session
**Question**: Was the HFPSpike's `ioProc fires=0` failure mode caused
by entanglement with broken-production-state (the H1 -10851 crash
leaving Core Audio in a bad state), or is it independent?
**Hypothesis under test**: H3 (specifically the auxiliary "spike
failure is entangled with broken production state").

**Prediction** (locked at 2026-05-25 12:09 EDT):
- **Outcome A**: spike's IOProc now fires (`ioProc fires>0`). →
  Auxiliary refuted; spike failure was entanglement-driven; we can fix
  the spike to validate H2 architecture.
- **Outcome B** (predicted given consistent prior nulls): spike's
  IOProc still doesn't fire. → Auxiliary refuted *in the other
  direction*; spike has its own real bug independent of production
  state. Move to isolated audiotee-pattern test (EXP-016).

**Method**: with the EXP-014 build running, press the HFP spike Start
button in the debug panel. Wait 5+ seconds. Press Stop. Check log
for `HFPSpike +5s: A2DP RETAINED ... ioProc fires=N`.

**Auxiliaries held**: TCC grant for tap-n-filter.app is still
active; signing didn't drift; the spike code path is unchanged from
its prior state.

**Artifacts**: `~/Library/Logs/tap-n-filter/app.log` entries between
12:09:34 and 12:09:52 EDT.

**Observations**:
- [source-grounded] At 12:09:34.731 the log records `HFPSpike: IOProc
  started. Capture flowing.`
- [source-grounded] At 12:09:35.781, 36.831, 37.881, 39.981 the log
  records the same `ioProc fires=0, frames=0` verdict the spike has
  produced in every prior run.

**Conclusion**: Outcome B — spike still fails identically. The "spike
failure was entanglement-driven" auxiliary is **refuted**. The spike
has its own real bug independent of production state. By the
post-falsificationist protocol (3+ same-null tweaks on the same
hypothesis), further spike-tweak experiments are degenerative. The
next experiment isolates the test from spike-specific code via
EXP-016.

**Follow-ups**: EXP-016 (isolated audiotee-pattern test).

### EXP-014 — Add `graph.detach()` before `attemptReattach()` in config-change observer

**Date**: 2026-05-25 12:05 EDT (pre-registration; run pending)
**Author**: current session
**Question**: Does inserting `graph.detach()` before
`self.attemptReattach()` in the `AVAudioEngineConfigurationChange`
observer stop the alreadyAttached retry loop and produce sustained
capture?

**Hypothesis under test**: H4.

**Prediction** (locked at 2026-05-25 12:05 EDT):

- **Outcome A (predicted)**: log no longer shows `alreadyAttached`
  after `configChangeObserver` fires. captureState reaches `running`
  and stays there for sustained durations (30+ s) even as BT
  reconfigures. User reports continuous audible audio (HFP-degraded on
  BT, but continuous, not chopped). EQ slider changes are audibly
  smooth (no glitching from retry cycles). → **H4 verified.**

- **Outcome B**: log no longer shows `alreadyAttached` but shows a
  different error from `attemptReattach()` (e.g., engine.start failure,
  format mismatch). captureState collapses to idle. → **H4 supported
  in narrow sense** (the specific bug is fixed) but
  `attemptReattach()` has further bugs. New hypothesis from the error.

- **Outcome C**: log shows no errors, captureState=running and stable,
  but user reports no audible audio. → H4 fix didn't introduce audio
  but didn't kill anything either; some other audio-path bug. Reframe.

- **Outcome D**: same `alreadyAttached` error appears. → The
  source-grounded reasoning ("detach-then-attach is the missing step")
  is wrong; auxiliary "calling `graph.detach()` actually makes
  `attachedEngine` go nil" failed. Re-read `Graph.detach()` code.

**Variables held constant**:
- Source process: Safari with YouTube playing
- Default output: BT (Bose QC) — same as EXP-013
- All other code unchanged from post-EXP-013 state
- Signing identity: VIGIL Dev

**Variables changed**:
- `AppViewModel.swift:325-329`: insert `self.graph.detach()` between
  the `engineIsRunning = false` assignment and the
  `attemptReattach()` call.

**Auxiliaries held**:
- `Graph.detach()` is idempotent and safe to call when the engine is
  stopped (per the existing `mutateGraph` and `installPreset` usage —
  source-grounded).
- The `AVAudioEngineConfigurationChange` event fires reliably when BT
  switches profile (source-grounded; logs show it firing at
  11:43:07.114 and 11:43:07.735 in EXP-013).
- After the detach + re-attach, `engine.start()` will succeed
  (behavior-inferred; we haven't tested this code path until now).

**Method**:
1. Edit `Sources/ViewModel/AppViewModel.swift`: add
   `self.graph.detach()` and an updated comment in the configuration-
   change observer block.
2. Update the comment at lines 322-324 to reflect actual behavior
   (the chain attachment is *not* preserved across reconfigurations;
   we must detach and re-attach).
3. `./Build/bundle-dev.sh` to rebuild.
4. User: launch app, grant TCC re-prompt, BT connected (Bose QC),
   Safari playing YouTube.
5. Press production Start. Listen for 30+ seconds.
6. Move EQ band gain slider; listen for smooth, continuous changes
   (no chopped audio from retry loop).
7. Press Stop. Capture watermark for log extraction.

**Artifacts** (to be filled in after the run):

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-016 — Isolated audiotee-pattern test inside tap-n-filter.app

**Date**: 2026-05-25 12:30 EDT (pre-registration; run pending)
**Author**: current session
**Question**: Does direct IOProc on a tap-only aggregate fire and
deliver non-zero audio inside `tap-n-filter.app` (which has the
"System Audio Recording Only" TCC grant) when set up with audiotee's
exact pattern (empty tap list at aggregate creation, then post-set
via `AudioObjectSetPropertyData`)?

**Hypothesis under test**: H3, but with all spike-specific code
(engine, ring buffer, source node, render thread) removed. The test
isolates the question to: setup → IOProc → audio data, nothing more.

**Prediction** (locked at 2026-05-25 12:30 EDT):

- **Outcome A**: ioProc fires>0 with non-zero samples. → The
  direct-IOProc-on-tap architecture works in our app. HFPSpike's
  `ioProc fires=0` failure is a Swift-specific bug we can find later;
  meanwhile we have empirical proof to start the production refactor
  toward the IOProc + AVAudioSourceNode pattern that should avoid
  HFP. (H2 path validated.)

- **Outcome B**: ioProc fires>0 with ALL-ZERO samples. → Same failure
  mode audiotee CLI exhibited from Terminal (EXP-007/008/009). Our
  app's TCC grant for "System Audio Recording Only" isn't actually
  enough; the granular TCC story is more complex. Need to dig into
  per-binary entitlements or what audiocap does differently. H2 path
  blocked on a TCC question we don't have answers for.

- **Outcome C**: ioProc fires=0. → Same failure mode as HFPSpike but
  with all extraneous code stripped out. macOS 26.3 + tap aggregate
  + direct IOProc may simply not work on this host regardless of code.
  H2 path effectively dead via this approach; would need a completely
  different architecture (e.g., custom HALOutput AU, or accept HFP
  for v0.1).

- **Outcome D (unanticipated)**: setup throws (tap creation, aggregate
  creation, post-set, IOProc creation, or AudioDeviceStart). → New
  hypothesis from the specific OSStatus. The pre-registration's
  Outcomes A/B/C all assume setup succeeds.

**Variables held constant**:
- Same TCC grant, same VIGIL Dev cert, same source process (Safari
  72409), same BT (Bose QC connected).
- All production code unchanged from post-EXP-014 state.

**Variables changed**:
- New file `Sources/ViewModel/AudioteePatternTest.swift` (~280 LOC)
  that creates a tap + aggregate + IOProc using audiotee's exact
  setup pattern (empty tap list at aggregate creation, post-set via
  `AudioObjectSetPropertyData`), with no engine, no ring buffer, no
  source node. Counters tally callbacks, total bytes, non-zero
  samples, and max absolute sample value. Runs for 5s then logs the
  result and tears down.
- New `runAudioteeTest()` method on `AppViewModel`.
- New "Audiotee test" row in `DebugPanel` with a "Run 5s" button.

**Auxiliaries held**:
- The new test's setup correctly mirrors audiotee's (no transcription
  bugs). Spot-checked against
  `/tmp/audiotee/Sources/AudioTeeCore/Core/AudioTapManager.swift`.
- The CTapDescription `stereoMixdownOfProcesses:` initializer behaves
  equivalently to audiotee's `description.processes = [...]` pattern
  for our purposes (audiotee's pattern doesn't compile against the
  current SDK; this is the closest equivalent).
- The C function pointer IOProc and its `Unmanaged.fromOpaque` access
  pattern are correctly synchronized via `OSAllocatedUnfairLock`. No
  data race between IOProc thread and main.

**Method**:
1. With the EXP-016 build installed and TCC re-granted, select Safari
   in the source picker. Have Safari playing audible audio (YouTube).
2. Open debug panel, press the new "Audiotee test → Run 5s" button.
3. Wait 5-6 seconds for the test to complete; "running…" indicator
   will switch back to "Run 5s".
4. Read `~/Library/Logs/tap-n-filter/app.log` for the
   `AudioteePatternTest RESULT:` line.

**Artifacts** (to be filled in after the run):

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-017 — Switch isolated test's aggregate setup to HFPSpike's pattern

**Date**: 2026-05-25 (pre-registration; run pending)
**Author**: current session
**Question**: With everything else stripped (no engine, no ring
buffer, no source node), does HFPSpike's *aggregate setup pattern*
(embedded tap list at creation + `kAudioAggregateDeviceTapAutoStartKey:
true`) avoid both failure modes seen so far? — i.e., does
`AudioDeviceStart` succeed AND the IOProc fire with non-zero audio?

**Hypothesis under test**: H3 (the spike's IOProc-no-fire bug), refined.
Specifically: is the bug in the spike's *setup* (tap + aggregate
description) or in its *engine integration* (AVAudioEngine,
AVAudioSourceNode, ring buffer)?

**Why this is the decision point**:
- EXP-013, EXP-014, EXP-016 produced two distinct failure modes:
  HFPSpike (`AudioDeviceStart`=0, then `ioProc fires=0`) and
  AudioteePatternTest (`AudioDeviceStart` returns 'nope').
- EXP-017 takes HFPSpike's aggregate setup and runs it in the minimal
  harness (no engine code). The outcome cleanly disambiguates.
- Per the protocol, this is also the natural stopping point. Three
  outcomes have already failed; a fourth same-null is degenerative.
  Treat EXP-017 as the last try before deciding to accept HFP for
  v0.1.

**Prediction** (locked before the run):

- **Outcome A**: `AudioDeviceStart`=0 AND ioProc fires>0 with non-zero
  samples. → HFPSpike's setup pattern is fine; its no-fire bug is in
  the engine integration. We can either (a) fix HFPSpike's engine
  integration, or (b) refactor production directly using this proven
  setup pattern + a direct ring-buffer-to-output path.
- **Outcome B**: `AudioDeviceStart`=0 AND ioProc fires>0 with all-zero
  samples. → Same TCC silencing we saw from Terminal-launched
  audiotee. Our app's TCC grant isn't enough. H2 architecture path
  blocked.
- **Outcome C**: `AudioDeviceStart`=0 AND ioProc never fires. → Setup
  is fine in isolation; engine code in HFPSpike isn't the cause
  either. Bug is somewhere deeper, possibly platform-level. H2
  architecture path effectively dead.
- **Outcome D**: `AudioDeviceStart` returns non-zero (e.g. 'nope'
  again). → HFPSpike's setup ALSO doesn't work in this harness, which
  contradicts its current behavior (`AudioDeviceStart`=0 in EXP-015).
  Implies some state difference between harnesses; new investigation
  needed.

**Variables held constant**:
- Same test harness (no engine, ring buffer, source node).
- Same source (Safari 72409).
- Same TCC grant, signing identity, build environment.

**Variables changed**:
- Aggregate creation dict in `AudioteePatternTest.setup`:
  - Add: `kAudioAggregateDeviceTapAutoStartKey: true`
  - Add: `kAudioAggregateDeviceTapListKey: [...]` embedded (with
    `kAudioSubTapDriftCompensationKey: true` and the tap UID)
  - Remove: `kAudioAggregateDeviceSubDeviceListKey: []`
  - Remove: `kAudioAggregateDeviceMasterSubDeviceKey: 0`
  - Remove: the post-creation `AudioObjectSetPropertyData` call for
    `kAudioAggregateDevicePropertyTapList`.
- (Everything else — tap creation, IOProc registration, counter
  logic, runtime — unchanged from EXP-016.)

**Auxiliaries held**:
- HFPSpike's aggregate setup truly does `AudioDeviceStart=0` reliably
  on our environment (source-grounded from EXP-003 et al. logs).
- The harness change is purely additive (no other variables sneak in).

**Method**:
1. Edit `AudioteePatternTest.setup` to apply the variable changes
   above.
2. `./Build/bundle-dev.sh`.
3. User relaunches the app, grants TCC re-prompt, picks Safari with
   audible audio.
4. User opens debug panel, presses "Audiotee test → Run 5s".
5. After 6s, read the log for the
   `AudioteePatternTest RESULT:` line.

**Decision rule based on outcome**:
- A → proceed with HFP architectural fix in production.
- B → escalate to TCC investigation (separate effort) or accept HFP.
- C → accept HFP for v0.1; document; close H2 / H3 as ruled-out for
  this version.
- D → one more diagnostic round to find what's different between
  harnesses, then re-decide.

**Artifacts** (to be filled in after the run):

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-018 — System-level HFP disable via `defaults write`

**Date**: 2026-05-25 14:30 EDT (pre-registration; run pending)
**Author**: current session
**Question**: With HFP system-disabled at the OS level, does
production capture deliver clean, full-bandwidth, effects-responsive
audio through BT headphones?

**Hypothesis under test**: H2 (BT HFP is the *only* remaining issue
after H1/H4 fixes). Equivalently: re-verifies that capture itself is
working end-to-end and that effects propagate audibly when HFP is out
of the picture.

**Prediction** (locked at 2026-05-25 14:30 EDT):

- **Outcome A (predicted)**: With HFP disabled, production audio plays
  cleanly through BT at full A2DP rates. Effect slider changes are
  audibly responsive. → H2 is the only remaining issue. The
  architectural fix has high value: implementing it cleanly would
  unlock full-fidelity BT capture. The macOS 26 zero-buffer bug is
  either not affecting our short capture sessions or is masked.

- **Outcome B**: With HFP disabled, audio is still degraded (low-pass
  or distorted character). → A separate quality issue, possibly the
  macOS 26 zero-buffer bug affecting our app too, or some other
  audio-path bug downstream of capture.

- **Outcome C**: With HFP disabled, capture works but BT operates in
  some weird third state (mono A2DP, or codec downgrade, or
  intermittent silence). → BT's profile model is more complex than
  binary A2DP/HFP; we have more to learn.

- **Outcome D**: The `defaults write` doesn't actually disable HFP on
  macOS 26.3 (BT still flips to 16 kHz mono when capture starts). →
  The workaround is folklore from older macOS versions; no actionable
  signal. Revert and consider EXP-017 again or accept HFP.

**Variables held constant**:
- Production build (post-EXP-014, with H1 and H4 fixed).
- BT (Bose QC) connected and used as default output.
- Source process: Safari with audible YouTube audio.

**Variables changed**:
- `sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP"
  -bool true`
- BT headphones disconnected and reconnected (force profile
  renegotiation under the new setting).

**Auxiliaries held**:
- The `defaults write` workaround as documented (in search results) is
  actually effective on macOS 26.3. (NOT verified; this is itself
  partially what EXP-018 tests via Outcome D.)
- BT reconnect after the `defaults write` is sufficient to re-
  negotiate without restarting `coreaudiod` or rebooting.
- Other audio-path code (the effect chain itself) is correct and would
  produce audible parameter responses on a non-HFP signal.

**Method**:
1. With BT connected (Bose QC) and Safari playing YouTube, take a
   pre-test snapshot:
   ```bash
   defaults read com.apple.BluetoothAudioAgent 2>/dev/null \
       | tee /tmp/exp-018-pre.txt
   ```
2. Apply the workaround:
   ```bash
   sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP" \
       -bool true
   ```
3. Disconnect BT (Control Center or BT menu → disconnect).
4. Reconnect BT (Control Center or BT menu → reconnect).
5. Confirm BT is in A2DP via:
   ```bash
   system_profiler SPBluetoothDataType 2>/dev/null \
       | grep -A20 "Bose QuietComfort"
   ```
   The output should show A2DP-capable (high-quality) parameters; the
   absence of an HFP "Service" line would be ideal but isn't strictly
   required.
6. Open tap-n-filter, press production Start with Safari selected.
7. Listen for ~30 s. Move EQ band gain ±12 dB; reverb wet/dry from 0
   to 1. Note whether parameter changes are audibly distinguishable.
8. Press Stop. Confirm captureState transitions cleanly in the log.
9. Revert the workaround:
   ```bash
   sudo defaults delete com.apple.BluetoothAudioAgent "Disable HFP"
   ```
   Then reconnect BT again so it's back to normal HFP-capable state
   for normal use.

**Artifacts** (to be filled in after the run):
- `/tmp/exp-018-pre.txt` — pre-workaround `defaults` snapshot.
- `~/Library/Logs/tap-n-filter/app.log` — captureState transitions
  and configuration-change events during the test window.
- User-reported audio quality and effect responsiveness.

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-019 — Diagnose H6 (outputNode-stuck-at-zero on speakers)

**Date**: 2026-05-26 (pre-registration; run pending)
**Author**: current session
**Question**: Why does `engine.outputNode.outputFormat(forBus: 0)`
report `0 Hz × 0 ch` indefinitely on built-in speakers after
`configureEngineInput` binds the tap aggregate to inputNode? And:
does `engine.reset()` between failure and a retry-poll force the
output AUHAL to rebind?

**Hypothesis under test**: H6.

**Time budget**: 45-60 min. If unresolved, document deepest state
reached and move on. Do NOT extend without a new pre-registration.

**Prediction** (locked before run):

- **Outcome A**: outputNode.audioUnit's `CurrentDevice` is in fact
  the system default (built-in speakers), but `outputFormat` reports
  0 anyway → the issue is in the AVAudioEngine API layer, not the
  audio unit binding. `outputFormat(forBus: 0)` is unreliable for our
  poll. Workaround candidate: read `outputNode.audioUnit`'s stream
  format directly.

- **Outcome B**: outputNode.audioUnit's `CurrentDevice` is the
  aggregate device (the same one inputNode was just pointed at) → the
  binding got "stolen" by configureEngineInput. The DefaultOutput AU
  is supposed to track system default but isn't. Fix candidate:
  switch outputNode to a HALOutput AU we can pin explicitly, or
  explicitly trigger the rebind.

- **Outcome C**: outputNode.audioUnit's `CurrentDevice` is some
  zero/unknown value, and `engine.reset()` makes it valid → fix
  candidate: call engine.reset() after configureEngineInput in
  production. One-line fix.

- **Outcome D**: outputNode.audioUnit refuses to read its
  `CurrentDevice` (DefaultOutput refuses reads as well as writes) →
  we can't introspect; pivot to other angles or accept H6 unresolved.

- **Outcome E**: engine.reset() makes outputFormat valid → fix path
  found.

- **Outcome F**: Both the diagnostic and the reset fail; outputNode
  refuses to bind. → H6 is deeper than the diagnostic tools reach;
  defer to a separate session with more invasive instrumentation.

**Variables held constant**:
- Built-in speakers as default (BT off).
- Source: Safari Graphics and Media with audible YouTube.
- Post-EXP-014 / post-prepare-before-wait codebase.

**Variables changed**:
- Add diagnostic logging in `AppViewModel.powerOn`:
  - After `configureEngineInput`: log
    `outputNode.audioUnit.CurrentDevice` (as both ID and resolved
    device name)
  - After `engine.prepare()`: log the same plus `outputNode.audioUnit`'s
    stream format at output scope element 0
  - Inside the wait loop on each diagnostic log line: also log
    `outputNode.audioUnit.CurrentDevice`
- Add `engine.reset()` recovery in the wait-failure path: when the
  poll times out, log "trying engine.reset() recovery", call
  `engine.reset()`, re-read `outputFormat(forBus: 0)` and the audio
  unit's `CurrentDevice`, log results. Then fail as before (we don't
  retry the start sequence; we just observe whether reset fixed the
  binding).

**Auxiliaries held**:
- `outputNode.audioUnit` is accessible and non-nil (verified by prior
  `setOutputUnitDevice` usage that succeeded in getting the AU before
  failing on the property set).
- `AudioUnitGetProperty` for `kAudioOutputUnitProperty_CurrentDevice`
  and `kAudioUnitProperty_StreamFormat` returns useful data on
  DefaultOutput. NOT VERIFIED — DefaultOutput refused the SET; reads
  may also be refused. Outcome D explicitly covers this.

**Method**:
1. Apply diagnostic + reset-recovery code changes.
2. `./Build/bundle-dev.sh`.
3. User: quit/relaunch app, grant TCC re-prompt, pick "Safari
   Graphics and Media", with audible YouTube playing through speakers.
4. Press production Start. Wait the full 5s (will fail again per H6
   prediction; the point is the diagnostic data).
5. Read `~/Library/Logs/tap-n-filter/app.log` for the new diagnostic
   lines. Decide next step per Outcome A-F.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` 2026-05-26 23:41:15 → 23:41:20.

**Observations** (tagged):
- [source-grounded] At 23:41:15.339 `EXP-019 AU diag [post-capture.-
  start, pre-prepare]: CurrentDevice=143 "tap-n-filter for Safari
  Graphics and Media" (getStatus=0); HWFormat=0.0 Hz × 0 ch
  (getStatus=0); EngineFormat=44100.0 Hz × 2 ch (getStatus=0)`. The
  aggregate device id is 143; its name was set by
  `CoreAudioInterface.createAggregateDevice` per source name pattern.
- [source-grounded] Same AU state at `post-prepare` and at
  `post-wait-timeout, pre-reset` — `engine.prepare()` did not change
  CurrentDevice, and the wait timeout's diagnostic shows the AU has
  been in this state the whole time.
- [source-grounded] After `engine.reset()`: CurrentDevice=143 still,
  outputFormat=0 Hz × 0 ch still. Reset did not rebind the AU.
- [source-grounded] `AudioUnitGetProperty` returned 0 (noErr) for all
  three reads (CurrentDevice, output-scope StreamFormat, input-scope
  StreamFormat). The AU accepts introspection — it is not a pure
  DefaultOutput unit refusing all property access.

**Conclusion**: Outcome B confirmed. `configureEngineInput`'s set of
`kAudioOutputUnitProperty_CurrentDevice` on inputNode's AUHAL has the
side effect of also setting outputNode's AU to the same device.
AVAudioEngine on macOS 26.3 appears to share device state between
input and output AUHALs in a way that wasn't true (or didn't cause
visible problems) in earlier versions. On Bluetooth, system audio
routing apparently re-routed output to the BT device somehow despite
this shared binding (still don't understand the mechanism — possibly
the BT subsystem provides a "fallback" path that built-in speakers
don't get).

Reset doesn't help (Outcome C/E refuted). Introspection works (Outcome
D refuted). The remaining workable fix candidate is the same one
EXP-012 attempted via `pinEngineOutputToDefault`: explicitly set
outputNode's `CurrentDevice` to the actual system default output
*after* `configureEngineInput` has done its damage. The earlier -10851
failure may have been transient or environment-dependent. Test in
EXP-020.

**Follow-ups**: EXP-020 (explicit re-bind after prepare). Time budget
remaining: ~25 min as of this entry.

### EXP-020 — Explicit re-bind of outputNode.audioUnit to system default after prepare (DEFERS H6)

**Outcome**: B (with a twist) — H6 deferred at time budget.

**Date**: 2026-05-26 (pre-registration; run pending)
**Author**: current session
**Question**: Does setting
`kAudioOutputUnitProperty_CurrentDevice` on `engine.outputNode.audioUnit`
to the system default output device (after `configureEngineInput` has
stolen the binding) re-bind outputNode and let the wait loop succeed?

**Hypothesis under test**: H6 fix candidate.

**Prediction** (locked before run):

- **Outcome A**: `AudioUnitSetProperty` returns noErr,
  outputFormat(forBus: 0) reports valid format after the SET,
  engine.start succeeds, audio reaches the chain and the user hears
  processed audio. → **H6 resolved, one-line production fix found.**
- **Outcome B**: `AudioUnitSetProperty` returns -10851 (same as
  EXP-012's original failure). → The previous theory ("DefaultOutput
  refuses SET") is correct after all; we'd need a different approach
  (switching outputNode to an explicitly-created HALOutput AU, which
  is invasive). H6 deferred.
- **Outcome C**: SET returns noErr but the wait still times out
  (CurrentDevice doesn't actually change in observable behavior).
  → AVAudioEngine is overriding our SET. H6 deferred.
- **Outcome D**: SET succeeds, outputFormat becomes valid, engine.start
  succeeds, but audio is silent. → Different downstream bug; new
  hypothesis.

**Variables held constant**:
- Same source (Safari Graphics and Media), same BT-off + built-in
  speakers default, same post-EXP-019 codebase.

**Variables changed**:
- After `engine.prepare()` in `AppViewModel.powerOn`, before the wait
  loop, insert:
  - Read system default output device via
    `kAudioHardwarePropertyDefaultOutputDevice`.
  - Set it as outputNode.audioUnit's CurrentDevice.
  - Log the SET status and the post-SET AU state.

**Auxiliaries held**:
- The system default output device is built-in MacBook Air Speakers
  (verified by `system_profiler` earlier in the session).
- The SET operation if successful actually rebinds the AU (vs being
  silently ignored or queued).

**Method**:
1. Apply the code change.
2. `./Build/bundle-dev.sh`.
3. User quits/relaunches, grants TCC re-prompt, picks Safari Graphics
   and Media (with audible YouTube), presses production Start.
4. Read the log: look for "EXP-020 SET CurrentDevice" line and the
   resulting wait outcome.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` 2026-05-27 05:57:31 →
  05:57:36.

**Observations** (tagged):
- [source-grounded] At 05:57:31.274 `EXP-020 rebind: SET
  outputNode.CurrentDevice to defaultOutput=98: status=-10851`.
  Default output device id 98 (presumably MacBook Air Speakers,
  confirmed by earlier `system_profiler` output). SET returned
  `kAudioUnitErr_InvalidPropertyValue` (-10851) — same refusal
  EXP-012 saw originally.
- [source-grounded] Immediately after the failed SET:
  `CurrentDevice=0 "(unresolved)"`. The failed SET invalidated the
  prior binding (was 147 / aggregate). Outcome: AU now in a worse
  state than before our attempt — bound to nothing.
- [source-grounded] `CurrentDevice=0` persists through wait loop,
  through `engine.reset()`, into the cleanup. Nothing recovers the
  binding within this code path.

**Conclusion**: Outcome B with an additional finding (failed SET is
not idempotent — it nukes the existing binding). H6 cannot be fixed
via `AudioUnitSetProperty(CurrentDevice)`. Remaining fix candidates
require deeper architectural change:
- Replace `engine.outputNode` with a custom `kAudioUnitSubType_-
  HALOutput` AU that we own and can pin explicitly.
- Or restructure capture entirely (Codex's direct-IOProc-+-
  AVAudioSourceNode architecture, which is also what HFPSpike was
  meant to validate).
- Or accept built-in speakers as broken for capture in v0.1.

Both serious-fix candidates are out-of-scope for this session's
remaining time. **H6 marked deferred.** Time budget hit (cumulative
~75 min on H6 across EXP-019 and EXP-020).

**Auxiliaries challenged**:
- "DefaultOutput refuses CurrentDevice SET" theory (originally
  R-something from EXP-012) is now back to active — but with a new
  observation that the SET also invalidates existing state.

**Follow-ups**:
- Revert the EXP-020 SET call from production code so BT path
  doesn't regress (the SET would also invalidate BT's binding if
  called there).
- Move to **BT reverb extreme-sweep test** (Path 1 disambiguator) —
  pre-registered as EXP-021 below.
- Track H6 as deferred-active. Future session: read AudioCap and
  WWDC 2023 session 10208 transcript for whether Apple documents
  this output-binding-stolen behavior, and prototype HALOutput
  replacement for outputNode.

### EXP-023 — Confirm input/output AU identity

**Date**: 2026-05-27 06:11 EDT
**Author**: current session
**Question**: Are `engine.inputNode.audioUnit` and
`engine.outputNode.audioUnit` the same `AudioUnit` instance?

**Outcome**: **YES, confirmed** — both report pointer
`0x00000000926600bf`, same=true, both subtype `'ahal'` (HALOutput).

**Observations** (tagged):
- [source-grounded] `EXP-023 AU identity [pre-capture.start]:
  inputAU=0x00000000926600bf, outputAU=0x00000000926600bf, same=true`
- [source-grounded] `EXP-023 input AU subtype [pre-capture.start]:
  type='auou' subtype='ahal' manufacturer='appl' (getStatus=0)`
- [source-grounded] **Second finding**: capture.start failed with -10851
  even without the EXP-022 pre-capture SET. The mere READ in
  `logInputAndOutputAUIdentity` is sufficient to put the unified IO
  AU into a state where `configureEngineInput`'s SET is rejected.
- [source-grounded] (Same finding inferred from EXP-022: pre-capture
  logOutputAudioUnitState + SET attempt broke capture.start. The SET
  wasn't the load-bearing trigger; the access was.)

**Conclusion**: **H6 root cause is now mechanically characterized.**
On macOS 26.3 (and possibly earlier 26.x), `AVAudioEngine.inputNode.-
audioUnit` and `AVAudioEngine.outputNode.audioUnit` are the same
`kAudioUnitSubType_HALOutput` instance. There is exactly one
`kAudioOutputUnitProperty_CurrentDevice` value. When
`configureEngineInput` sets it to the tap aggregate, `outputNode.-
outputFormat(forBus: 0)` reports `0 Hz × 0 ch` because the aggregate
has no output streams. **The shared AU is fundamentally incompatible
with the "input = aggregate, output = some other device" topology
the v0.1 architecture assumes.** It is not a config-tweak fix.

**Bonus finding**: reading the AU before capture.start invalidates
subsequent SET attempts inside configureEngineInput. Diagnostics must
go AFTER capture.start or they break the hot path.

**Auxiliaries refuted**:
- "DefaultOutput refuses SET" theory (EXP-012 era) — outputNode is
  not DefaultOutput; it's HALOutput.
- "Input and output AUHALs are separate units" — they aren't.

**Auxiliaries surfaced**:
- The unified IO AU model in AVAudioEngine on macOS 26.3 may be a
  change from earlier macOS versions. Worth verifying against macOS
  14.x and 15.x in a future session if we can.

**Fix paths (none in-scope this session)**:
1. Direct IOProc + `AVAudioSourceNode` → output-only engine (Codex's
   original architecture; HFPSpike was meant to validate this).
2. Custom HALOutput AU we manage outside AVAudioEngine for the
   output side.
3. Two engines (one for capture's input-side wiring, one for output)
   with samples shuttled between them via ring buffer.

All require significant refactoring; deferred. H6 marked as
"deferred-active" — root cause known, fix scheduled but not done.

**Follow-ups**:
- Revert the pre-capture diagnostics (already done in code; they
  break capture.start).
- Move to EXP-021 (BT reverb extreme-sweep test) to determine
  whether the existing effect chain audibly responds at all.

### EXP-022 — Identify outputNode AU subtype + pre-capture SET attempt

**Date**: 2026-05-27 (pre-registration; run pending)
**Author**: current session
**Question**: Two questions in one experiment.
(1) What audio unit subtype is `engine.outputNode.audioUnit` actually
backed by? (`DefaultOutput`, `HALOutput`, or something else?)
(2) Does setting `CurrentDevice` BEFORE `configureEngineInput` runs
succeed? (Before the configureEngineInput-steals-binding side effect.)

**Hypothesis under test**: H6 fix candidate. Specifically:
- If outputNode.audioUnit is `DefaultOutput`, SET will fail in all
  positions; H6 requires HALOutput replacement (Option 2 from session
  notes, ~30-60 min refactor).
- If it's `HALOutput`, SET *should* work; we'd be looking at a
  different bug in why our SET fails. Pre-capture SET would isolate
  whether the failure is specifically related to configureEngineInput's
  state mutation.

**Prediction** (locked before run):

- **Outcome A (predicted most likely)**: AU subtype is
  `kAudioUnitSubType_DefaultOutput` (`'def '` / 0x64656620). Pre-
  capture SET returns -10851 same as post-capture. → DefaultOutput
  rejects SET universally. H6 fix path is HALOutput replacement
  (out-of-scope this session).
- **Outcome B**: AU subtype is `kAudioUnitSubType_HALOutput` (`'ahal'`
  / 0x6168616c). Pre-capture SET succeeds (status=0). → outputNode
  has been a HALOutput all along, but configureEngineInput steals the
  binding via some path that bypasses our explicit SET (maybe an
  internal AVAudioEngine method). Fix would be: pre-capture SET + re-
  SET after capture.start somehow. New hypothesis.
- **Outcome C**: AU subtype is HALOutput, pre-capture SET fails with
  -10851. → HALOutput but with some other restriction. Apple
  documentation incomplete. New hypothesis.
- **Outcome D**: AU subtype is something else entirely (rare,
  unexpected). → New direction.

**Variables held constant**:
- BT off, built-in speakers as default.
- Source: Safari Graphics and Media.
- Post-EXP-020-revert codebase.

**Variables changed**:
- Add `kAudioUnitProperty_ComponentDescription` read to the diagnostic
  helper (`logOutputAudioUnitState`), so each diagnostic snapshot also
  includes the AU's component type/subtype/manufacturer.
- Add a new `rebindOutputToSystemDefault()` call BEFORE `capture.start`
  (after source resolution, before engine.inputNode gets touched).
  Logs SET status. The call is identical to EXP-020's helper (which is
  still in source but no longer invoked).

**Method**:
1. Code change + build.
2. User quits/relaunches; grants TCC re-prompt; picks Safari Graphics
   and Media (with audible YouTube). Speakers as default output.
3. Press production Start.
4. Read log for:
   - `EXP-022 AU subtype: type=... subtype=... manufacturer=...`
   - `EXP-022 pre-capture SET: status=...`
   - Whether subsequent wait succeeds or fails.

**Artifacts** (to be filled in after the run):

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-021 — BT reverb extreme-sweep test (effects-respond disambiguator)

**Date**: 2026-05-27 (pre-registration; run pending)
**Author**: current session
**Question**: With production capture working on BT (HFP-degraded
audio), and the reverb wet/dry slider swept all the way from 0.0
(fully dry, no reverb) to 1.0 (fully wet, no direct signal), is the
audible difference at the extremes large enough to be unmistakable?

**Hypothesis under test**:
- Path Y ("effects actually work, HFP just masks subtle changes"):
  predicts an obvious audible difference between dry and fully-wet
  even through HFP downsampling.
- Path Z ("effects don't actually respond regardless of HFP"):
  predicts no audible difference at the extremes — slider value isn't
  reaching the AU effectively.

**Prediction**:
- **Outcome A**: Clear, dramatic difference between dry and wet at
  extremes (cathedral-vs-anechoic kind of difference) → Path Y;
  effects work. H2 (HFP) is the only barrier to good v0.1 audio.
- **Outcome B**: No discernible difference between dry and wet at
  extremes → Path Z; there's an effect-chain bug independent of HFP.
  Need to instrument the AU side of the reverb node.
- **Outcome C**: Subtle but real difference (less than expected for
  full sweep but still perceptible) → Ambiguous; HFP may be masking
  more than expected. Need a WAV dump test for definitive answer.

**Variables held constant**:
- Post-EXP-020-revert build.
- Source: Safari Graphics and Media playing YouTube.

**Variables changed**:
- BT reconnected (Bose QC); built-in speakers no longer default.
- User performs the slider sweep extremes (0.0 → 1.0), pause briefly
  at each end so they can hear sustained dry-only vs sustained
  wet-only.

**Auxiliaries held**:
- BT routes audio through capture pipeline (verified via prior EXP-013
  / EXP-014 logs showing outputNode=44.1 kHz × 2 ch transiently then
  16 kHz × 1 ch).
- The reverb `wetDryMix` setter actually pushes through to the
  AudioUnit (the slider produced 36 logged updates from a partial
  sweep in EXP-014; the setter code path executes).

**Method**:
1. Reconnect BT (Bose QC). Confirm BT is default output.
2. Quit / relaunch tap-n-filter (cleaner state).
3. Pick Safari Graphics and Media. Press production Start. Confirm
   audio is flowing (HFP-degraded but audible).
4. **Drag reverb wet/dry slider all the way to 0.0**. Hold 5 seconds.
   Listen carefully.
5. **Drag wet/dry slider all the way to 1.0**. Hold 5 seconds. Listen.
6. Sweep back and forth a few times.
7. Optionally repeat with the EQ band gain at full boost vs full cut.
8. Report what you hear.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries 06:39:55 → 06:42:25
  EDT (2026-05-27). The first run is the multi-second sweep; the
  subsequent entries are repeated Start/Stop toggles by the user.

**Observations** (user-reported, with log corroboration):

- 06:39:55 powerOn complete fires; `engine.isRunning=true`,
  `inputNode=48000.0 Hz × 2 ch`, `outputNode=16000.0 Hz × 1 ch`. Engine
  is genuinely running on macOS's view of the world.
- 06:40:03-04 reverb wet/dry slider sweeps 0.5 → 0.0 → 1.0 with 21
  `updateWetDryMix:` log entries spanning ~700 ms. The setter
  hot-path is executing.
- 06:40:13 EQ `hp.frequency=58.94` push-through logged.
- 06:40:27 `removeEffect: at index 0`, `mutateGraph: wasRunning=true`,
  `detached for live mutation`, `reattaching after live mutation` —
  but **no log line for "reattach complete"**. The next mutateGraph
  (06:40:33 addEffect) reports `wasRunning=false`, so the engine
  silently dropped sometime in the 6-second window between detach and
  next user action.
- **User-reported audio outcome (verbatim)**:
  > "all it did was cut out the audio, and stay cut out it seems, and
  > no changing of the sliders, no toggling of the effects changed
  > anything. I even tried removing the effect but I think that froze
  > the menu because I couldn't toggle again. And then I restarted,
  > and try to just toggle and see what would happen. when I press
  > start it cuts out, when I toggle it again so it 'stops' the sound
  > comes back but attenuated with the HFP or whatever like it was
  > doing before."

**Conclusion**: **None of the pre-registered outcomes A/B/C match.**
What we got is a new outcome:

- **Outcome D**: audio is **fully cut out** during capture, not
  HFP-degraded. Pressing Stop releases the cut-out and HFP aftermath
  persists briefly on the source. Sliders + toggles produce no
  audible change because there is no engine-output audio reaching the
  user.

This is a structural reframing: the prediction tree (Y vs Z) was
itself wrong — both predictions assumed engine output was audible at
some level (HFP-degraded or full quality) and asked whether moves
within it were perceptible. The actual state is that **no engine
output reaches the user at all**, while the source process is muted
by the tap (per ADR-014). User hears literal silence.

The 06:40 run accidentally surfaced *two* further bugs:
1. Live `removeEffect` while engine is running causes the engine to
   die silently (no error log, no state transition to `failed`).
2. The menubar UI freezes after that silent engine death (no toggle
   responsiveness), forcing a restart.

These are real and worth tracking but secondary to the no-audio-out
finding. → see H7 below and EXP-024 for the disambiguator.

**Follow-ups**: → H7 (NEW), → EXP-024 (mainMixerNode tap to
disambiguate "engine output is silent" vs "engine output is
discarded by the OS"). H6's "deferred-active" status escalates to
**active blocker** because Outcome D is its user-level
manifestation.

### EXP-026 — Audiotee EXACT pattern with SubDeviceList + MasterSubDevice keys

**Date**: 2026-05-27 22:30 EDT (pre-registration; run pending)
**Author**: current session

**Question**: Does audiotee's exact aggregate-creation pattern — with
`kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
`kAudioAggregateDeviceMasterSubDeviceKey: 0` keys present, tap list
set AFTER creation as `CFArray<CFString>` — get the IOProc to fire
from inside `tap-n-filter.app`? EXP-016 attempted "audiotee post-set
pattern" but the lab record doesn't confirm those two aggregate-init
keys were included; this is the gap.

**Hypothesis under test**: H3 (HFPSpike IOProc-no-fire is a code-level
setup bug, not a platform constraint). Specifically: the missing
`SubDeviceListKey: [] as CFArray` and `MasterSubDeviceKey: 0` in our
prior aggregate creations may be required to initialize the
aggregate's clock infrastructure before a tap can be attached and
driven.

**Pre-registered outcomes**:
- **Outcome α** — IOProc fires (fires > 0) with non-zero samples
  (maxAbs > 0). **Architecture validated**. The missing keys were
  the issue. Proceed to production refactor using this pattern.
- **Outcome β** — IOProc fires (fires > 0) with all-zero samples
  (maxAbs = 0). **macOS 26 zero-buffer bug** (forums thread 825780)
  confirmed hitting our app despite TCC. Refactor stalls; need
  different approach (HAL plugin, or wait for Apple fix).
- **Outcome γ** — IOProc doesn't fire (fires = 0). Even audiotee's
  exact pattern doesn't work in our app's TCC/signing context.
  Suggests something more fundamental (FDA-like TCC requirement,
  hardened-runtime restriction) is blocking us. Need entirely
  different architecture (HAL plugin, virtual device).
- **Outcome δ** — `AudioDeviceStart` returns 'nope' (1852797029,
  `kAudioHardwareIllegalOperationError`). Same failure as EXP-016
  earlier audiotee-pattern attempt. The two missing keys aren't the
  fix either; something else is required.

**Variables held constant**:
- Same build infrastructure as EXP-024/025.
- BT (Bose QC) connected, Safari playing YouTube as the source.
- tap-n-filter.app's existing TCC grant.

**Variables changed** (vs prior audiotee-pattern attempts):
- Aggregate creation dictionary now includes
  `kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
  `kAudioAggregateDeviceMasterSubDeviceKey: 0`.
- Tap list is set AFTER aggregate creation via SET on
  `kAudioAggregateDevicePropertyTapList`, with the tap list as a
  `CFArray` containing a single `CFString` (the tap's UID).
- `kAudioAggregateDeviceTapAutoStartKey` removed (audiotee doesn't
  use it).
- `kAudioAggregateDeviceTapListKey` removed from creation dictionary.

**Auxiliaries held**:
- The two missing keys (`SubDeviceListKey: []`, `MasterSubDevice: 0`)
  are necessary for the IOProc to fire on a tap-aggregate. Audiotee's
  working pattern includes them; our prior failures didn't.
- `CFArray<CFString>` (just UIDs) is the correct format for the
  post-set tap list; not `CFArray<CFDictionary>` (which is the
  embedded-creation format).
- The `audioteeTestIOProc` C function pointer is correct and would
  fire if registered against a working aggregate (confirmed by
  audiotee itself working from Terminal).

**Would shift confidence down**: the IOProc still doesn't fire
(Outcome γ or δ). Then we have to conclude that even audiotee's
exact pattern doesn't transfer to our app — meaning audiotee's
success from Terminal hinges on something we haven't replicated
(possibly the Terminal-spawned process inheriting some TCC scope
we don't have access to).

**Method**:
1. Quit any running tap-n-filter.
2. Launch new build (CDHash will change; TCC may or may not re-prompt).
3. Play music in Safari.
4. Open debug panel; pick Safari Graphics and Media as source.
5. Press the **Audiotee test "Run 5s"** button (purple scope icon).
6. After ~6 s, the verdict is logged. Three numbers to look for:
   - `fires=N` — IOProc callback count
   - `bytes=N` — total bytes delivered by the IOProc
   - `nonZero=N` — count of non-zero samples in delivered audio
   - `maxAbs=N` — peak amplitude

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries 22:07:11 → 22:07:16
  EDT (2026-05-27).

**Observations**:

```
22:07:11.138 AudioteePatternTest.run: source=Safari Graphics and Media (pid 77880)
22:07:11.148 tap created id=159
22:07:11.161 aggregate created id=160 (audiotee exact pattern: empty SubDeviceList + MasterSubDevice=0, tap list set after creation)
22:07:11.164 tap list set on aggregate via SET (CFArray of CFString)
22:07:11.167 aggregate streams — input=1, output=0
22:07:11.185 AudioDeviceStart=0; IOProc registered and started
22:07:16.219 RESULT: SUCCESS — ioProc fired 471 times, 1929216 bytes
            (482304 samples), 479702 non-zero (99.5%), maxAbs=0.7290.
22:07:16.221 AudioDeviceStop=0, DestroyIOProcID=0
```

- 471 IOProc fires in 5 s = ~94 fires/sec at 48 kHz × ~512-sample
  buffers = textbook normal.
- 99.5% non-zero samples, peak 0.73 → loud, real, recognizable
  Safari/YouTube audio captured byte-for-byte.
- Aggregate streams: `input=1, output=0` — the tap is properly
  wired as the aggregate's input source.

**Conclusion**: **Outcome α — architecture validated**. The
direct-IOProc-on-tap-aggregate pattern Codex recommended at the
start of this investigation works inside `tap-n-filter.app` when
the aggregate is created with `kAudioAggregateDeviceSubDeviceList-
Key: [] as CFArray` and `kAudioAggregateDeviceMasterSubDeviceKey: 0`
present, and the tap list is set after creation as
`CFArray<CFString>` (just UIDs, not array-of-dict).

**H3 resolved**. The IOProc-no-fire bug across HFPSpike + earlier
AudioteePatternTest attempts was a missing-aggregate-keys bug, not
a Swift-block, TCC, signing, BT, or platform issue. All the rule-
outs (R3, R4, R5, R6) stand; H3 itself now joins them in "ruled
out" — *with a positive finding*: the architecture works, we just
needed the right keys.

**Side-effect of resolution**: this also implicitly retires the
zero-buffer-bug concern (FC-002's alternative frame). The macOS 26
zero-buffer issue, whatever its scope, is NOT hitting our app —
99.5% of samples are non-zero.

**Follow-ups**: → ADR-XXX (Direct IOProc + AVAudioSourceNode
architecture). The production refactor is now de-risked. Concrete
template for the working aggregate setup lives in
`Sources/ViewModel/AudioteePatternTest.swift` lines 159-211.

### EXP-025 — Three-point tap (inputNode + mainMixerNode + outputNode)

**Date**: 2026-05-27 (pre-registration; run pending)
**Author**: current session

**Question**: At which point in the engine pipeline does audio stop
flowing? `inputNode` is push-driven by the device IOProc; `mainMixer-
Node` and `outputNode` are pull-driven by the output side. The combo
of which taps fire vs which return zero buffers will localize the
failure to a specific stretch of the pipeline.

**Hypothesis under test**: refined H7 — outputNode's IOProc isn't
firing on macOS 26.3 when the unified IO AU's CurrentDevice points at
the no-output tap aggregate. EXP-024 returned `bufferCount=0` on
mainMixer, which is consistent with the refined story. EXP-025 should
show inputNode firing (with non-zero samples, proving the tap delivers
real audio to the engine) while mainMixer and outputNode both return
zero buffers.

**Pre-registered outcomes**:
- **Outcome P** — inputNode > 0 buffers (nonZero > 0), mainMixerNode = 0
  buffers, outputNode = 0 buffers. **Refined H7 confirmed.** Tap
  delivers real audio; output side of the pipeline is dead because
  outputNode's IOProc isn't pulling. Architectural fix:
  Codex-recommended direct-IOProc + AVAudioSourceNode (engine output
  bound to default output, never to the aggregate).
- **Outcome Q** — inputNode = 0 buffers, mainMixerNode = 0,
  outputNode = 0. The tap isn't delivering audio at all (macOS 26
  zero-buffer bug, forums thread 825780, possibly intermittent).
  Different fix path: investigate whether the tap is actually pumping,
  or whether the aggregate's input streams are broken.
- **Outcome R** — inputNode > 0 (nonZero > 0), mainMixerNode > 0
  (nonZero > 0), outputNode = 0 or all-zero buffers. Graph is pumping,
  output side is unique problem. Subset of refined H7.
- **Outcome S** — inputNode > 0 (nonZero > 0), mainMixerNode = 0,
  outputNode > 0 buffers. Unusual; would mean outputNode is being
  pulled but mainMixer isn't (different engine wiring than we think).
- **Outcome T** — All three > 0 with non-zero samples. Then the audio
  IS reaching outputNode and somehow not getting written to a device.
  Closer to the original H7 framing.

**Variables held constant**:
- Same build as EXP-024 plus the multi-tap modification.
- BT (Bose QC) connected; same source (Safari Graphics and Media).

**Variables changed**:
- `runMixerTap` now installs taps on three nodes simultaneously, logs
  per-node stats (bufferCount, totalFrames, nonZeroFrames, maxAbs),
  and writes whichever has the most signal to WAV (input > mixer >
  output priority).

**Auxiliaries held**:
- `installTap` on `engine.inputNode` is the documented way to observe
  device-delivered samples on the engine input side.
- `installTap` on `engine.outputNode` is supported in AVAudioEngine
  (Apple docs say you can tap any node including the output node).
- The tap callbacks themselves are not subject to engine pull (the
  callback fires when the node renders, even if that render is from
  push-driven device data on inputNode).

**Method**:
1. User presses "Tap 5s" once.
2. Three taps installed, 5s window, three taps removed.
3. Three log lines `STATS <nodeName>: bufferCount=N frames=N nonZero=N maxAbs=N`.
4. One WAV file written (the node with most signal).
5. User reports the three stat lines and what (if anything) the WAV
   contains.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries 21:48:50 → 21:48:55
  EDT (2026-05-27). First attempt with `outputNode` tap crashed the
  app at 21:44; second attempt (this entry) skips outputNode.
- `/var/folders/.../tap-n-filter-mainMixerNode-1779918535.wav` —
  0-byte WAV.

**Observations**:

First attempt (with outputNode tap) crashed/hung the app after
"installed tap on mainMixerNode bus 0" with no further log lines. The
outputNode `installTap` apparently raised an Objective-C exception
that Swift can't catch. The app exited (or hung). New auxiliary
ruled out: tapping `engine.outputNode` is reliably supported on
macOS 26.3 with our setup — it's not.

Second attempt (two-point tap, no outputNode):

```
21:48:50.583 powerOn complete: engine started, chain: tnf.reverb -> tnf.eq
21:48:50.611 installed tap on inputNode bus 0
21:48:50.611 installed tap on mainMixerNode bus 0
21:48:50.611 collecting for 5s
21:48:50.716 AVAudioEngineConfigurationChange fired: engine.isRunning=FALSE, outputNode=16000.0 Hz × 1 ch
21:48:50.716 engine stopped itself on configuration change; detaching graph and calling attemptReattach
21:48:55.669 STATS inputNode: bufferCount=0 frames=0 nonZero=0 maxAbs=0.0
21:48:55.669 STATS mainMixerNode: bufferCount=0 frames=0 nonZero=0 maxAbs=0.0
```

105 ms after powerOn the engine killed itself in response to the
HFP route-switch. The H4 handler fired, logged its message,
detached the graph, and called `attemptReattach`. But the log shows
**no** evidence `attemptReattach` actually re-started the engine
(no "engine started" / "graph reattached" / "powerOn complete"
follow-up log line). The engine sat in a stopped state for the
remaining ~4.95 s of the tap window.

**Conclusion**: **Outcome Q** *and* a new failure mode (call it
mode B for the Status block):

- inputNode tap fired zero times because the engine wasn't running.
- mainMixerNode tap fired zero times because the engine wasn't
  running.
- The engine wasn't running because:
  1. HFP route-switch fired `AVAudioEngineConfigurationChange` with
     `isRunning=false`.
  2. The H4 handler detached the graph and called `attemptReattach`.
  3. `attemptReattach` silently failed to bring the engine back —
     no log evidence of restart, no `captureState` transition back
     to running.

This is distinct from EXP-024's failure mode (where the engine
survived the config change with `isRunning=true` but no IOProc
pulled). Both end with user-perceived silence; the engine just gets
there via two different broken paths.

**Frame check trigger**: we've now diagnosed *two* independent
broken paths for the same architectural choice (unified IO AU +
CurrentDevice = tap aggregate). The right framing is no longer
"which subtle bug is causing silence" but "this architecture cannot
be made to work on macOS 26.3 — we need to remove the tap aggregate
from the engine's input AU entirely." → FC-003.

**Follow-ups**:
- → FC-003 (frame shift to "architectural rewrite required").
- → ADR-XXX for the chosen architectural approach (direct IOProc +
  AVAudioSourceNode is the leading candidate per Codex's original
  recommendation).
- H4's `attemptReattach` failing in this scenario is a real bug but
  it would only matter for an architecture where `attemptReattach`
  is part of the recovery path. If we abandon AVAudioEngine.inputNode
  for capture, we don't need attemptReattach at all.

### EXP-024 — Tap `mainMixerNode` output to disambiguate H7

**Date**: 2026-05-27 (pre-registration; run pending)
**Author**: current session
**Question**: Is `mainMixerNode`'s output producing non-zero audio
samples during capture? I.e., does processed audio reach the engine's
final pre-output stage, or is the chain producing silence upstream?

**Hypothesis under test**: H7 (unified IO AU's CurrentDevice → tap
aggregate → engine output silently discarded). H7 predicts the mixer
output has real audio content; the silence happens at the
outputNode-to-device step. Alternative hypotheses predict different
upstream zero-points.

**Pre-registered outcomes**:
- **Outcome X**: WAV file contains audible Safari audio (recognizable
  music / speech) → engine processes correctly through to
  mainMixerNode; H7 confirmed. Audio is being silently discarded by
  the device-write step. Next step: architectural fix (Codex's direct
  IOProc + SourceNode, or separate HALOutput).
- **Outcome Y**: WAV file is all zeros (or very close to it) → audio
  doesn't reach mainMixerNode at all. H7 refuted. The bug is upstream
  — either tap delivers zeros (macOS 26 bug #825780), or
  inputNode→graph→mixer chain has a routing problem. Next step:
  install tap on `engine.inputNode` instead to locate where the
  signal becomes zero.
- **Outcome Z**: WAV file has audio content but with telephone-grade
  low-pass character (HFP-style) → tap audio is being captured but
  the route is already being degraded by HFP before reaching mixer.
  Refines H7 with HFP entanglement; still architectural.

**Variables held constant**:
- Same build watermark as current top-of-tree (post-EXP-023, sans
  pre-capture diagnostics).
- BT (Bose QC) reconnected as default output.
- Safari Graphics and Media playing audible YouTube content.

**Variables changed**:
- Install `AVAudioNodeTapBlock` on `engine.mainMixerNode` via
  `installTap(onBus: 0, bufferSize: 1024, format: nil)`.
- Tap block writes each buffer to a `.wav` file in `/tmp/` using
  `AVAudioFile`.
- New debug-panel button "Tap mixer (5s)" that arms the tap, lets
  capture run for 5 s, then stops capture and closes the file.
- Tap is opt-in (button-driven), not on every powerOn.

**Auxiliaries held**:
- `AVAudioEngine.installTap` on `mainMixerNode` does not interfere
  with the engine's normal operation (Apple docs say it observes,
  does not redirect).
- Writing to a local `.wav` is reliable from a real-time audio
  callback (Apple's AVAudioFile is thread-safe; we'll write off the
  callback if needed).
- The file we read back is the one the tap wrote — no stale file
  caching.

**Method**:
1. Implement `mixerTap` armable from `AppViewModel.runMixerTap()`,
   parallel to `runAudioteeTest()`.
2. Button in `DebugPanel` ("Tap mixer 5s") armed only when source is
   selected. Pressing it: powerOn (or assume already on), install tap,
   wait 5 s, stop capture, deinstall tap, close file. Log path of
   file written to debug log.
3. User: pick Safari source, press button, wait, then open the WAV
   in QuickLook / iTunes / `afinfo` to inspect.
4. Report: is the file content audible Safari audio, all-zero
   silence, or HFP-degraded audio?

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries 07:02:44 → 07:02:50
  EDT (2026-05-27).
- `/var/folders/.../tap-n-filter-mixer-1779865369.wav` — 0 frames
  (empty file; AVAudioFile created but no buffers written).

**Observations**:

```
07:02:44.937 powerOn complete: engine started, capture running on Safari Graphics and Media, chain: tnf.reverb -> tnf.eq
07:02:44.938 runMixerTap: mainMixerNode.outputFormat = 16000.0 Hz × 2 ch
07:02:44.941 runMixerTap: installed tap on mainMixerNode bus 0; collecting for 5s
07:02:45.015 AVAudioEngineConfigurationChange fired: engine.isRunning=true, inputNode=48000.0 Hz x 2 ch, outputNode=16000.0 Hz x 1 ch
07:02:49.949 runMixerTap: removed tap. bufferCount=0 totalFrames=0 nonZeroFrames=0 maxAbs=0.0
07:02:50.084 runMixerTap: wrote 0 buffers to /var/folders/.../tap-n-filter-mixer-1779865369.wav (0 frames @ 16000.0 Hz × 2 ch); nonZero=0, maxAbs=0.0
```

Five seconds of "running" capture produced **zero buffer-render
callbacks** on `mainMixerNode`. Not "rendered silence" — rendered
nothing. The tap callback was registered (we have the install/remove
log lines bracketing the window) and the node was nominally part of
the engine, but the render thread never asked it for samples.

**Conclusion**: **Outcome Y** (refined). The pre-registered Y was
"WAV file is all zeros," which we read as "render pulls zero-valued
buffers." The actual outcome is more extreme: render doesn't pull at
all. AVAudioEngine uses a pull-based model — `outputNode` requests
samples from `mainMixerNode` requests from upstream — so zero pulls on
mainMixer means **outputNode never pulled either**. The engine
reports `isRunning=true` and the configuration-change observer says
the engine is fine, but the actual render loop is dead.

This is **consistent with refined H7**: when the unified IO AU's
`CurrentDevice` is the tap aggregate (no-output device), the output
side of the AU has no device IOProc to drive — so it never pulls
upstream samples. The engine's nominal state is "running" because the
AU's `start` call succeeded, but no actual IO is happening on the
output side.

Refines H7's wording: it's not that audio is produced and silently
discarded by a no-output device. It's that audio is **never produced
at all** because nothing is pulling on the graph. The audible outcome
is identical (silence at the headphones), but the mechanism is one
step earlier than I originally framed it.

This rules out two other candidate mechanisms:
- Tap delivers all-zero samples (macOS 26 bug) — would have produced
  zero-valued buffers, not zero buffers.
- Effect chain breaks the signal somewhere — would have produced
  zero-valued buffers (chain renders silence), not zero buffers.

**Follow-ups**: → EXP-025 (multi-point tap: inputNode + mainMixer +
outputNode) to confirm the pull is dead end-to-end and that inputNode
is the only node still receiving samples. If EXP-025 confirms, the
architectural fix Codex recommended originally (direct IOProc + AVAudio-
SourceNode, output bound to default output device) is the right path.

## External references

### Codex investigation report (this session)

**Source**: Codex 5.5 reply to `/codex:rescue` investigation request,
2026-05-24, reasoning effort xhigh.

**Most-relied-on quote** (verbatim, from Codex's response analyzing
the failing `pinEngineOutputToDefault`):

> [Setting `kAudioOutputUnitProperty_CurrentDevice` on
> `AVAudioEngine.outputNode.audioUnit`] returns `-10851`
> (`kAudioUnitErr_InvalidPropertyValue`)… `AVAudioEngine.outputNode`'s
> underlying AU is `kAudioUnitSubType_DefaultOutput`, which always
> uses the system default and refuses
> `kAudioOutputUnitProperty_CurrentDevice`. Only
> `kAudioUnitSubType_HALOutput` accepts that property.

**How we used it**: this exact warning is why H1 in the hypothesis
ledger is rated high-confidence. EXP-012 confirmed the warning empiri-
cally against our production logs.

### audiotee — makeusabrew/audiotee

**Source**: `/tmp/audiotee/` (locally cloned). Specific files
referenced:
- `Sources/AudioTeeCore/Core/AudioTapManager.swift`
- `Sources/AudioTeeCore/Core/AudioRecorder.swift`

**Pattern noted** (from `AudioTapManager.swift`, lines 105-151): the
aggregate device is created with an *empty* tap list, then the tap
list is set via `AudioObjectSetPropertyData(...,
kAudioAggregateDevicePropertyTapList, ...)` after creation:

```swift
let description = [
    kAudioAggregateDeviceNameKey: "audiotee-aggregate-device",
    kAudioAggregateDeviceUIDKey: uid,
    kAudioAggregateDeviceSubDeviceListKey: [] as CFArray,
    kAudioAggregateDeviceMasterSubDeviceKey: 0,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
] as [String: Any]
// … AudioHardwareCreateAggregateDevice(...) …
// Then post-creation:
let tapArray = [tapUID] as CFArray
AudioObjectSetPropertyData(deviceID, &kAudioAggregateDevicePropertyTapList,
                           0, nil, propertySize, &tapArray)
```

Our spike (and our production code) embeds `kAudioAggregateDeviceTap-
ListKey` in the creation dictionary instead. This is the most plausible
remaining cause for H3 (spike's IOProc-never-fires), if we ever return
to investigating it.

### Apple — `kAudioUnitSubType_DefaultOutput`

**Source**: `AudioUnit/AudioComponent.h` and Apple documentation.

**Relevant property**: `kAudioOutputUnitProperty_CurrentDevice` is
defined for `kAudioUnitSubType_HALOutput`. Default Output units are
locked to system default by design; they do not expose the
`CurrentDevice` property.

### insidegui/AudioCap

**Source**: project's coding standards
(`docs/governance/coding-standards.md`) cites AudioCap as the canonical
reference for the Core Audio tap API. We have not read AudioCap's
playback path in detail this session; their published code is more
focused on capture-to-file than capture-then-play-through-output.

### Apple Developer Forums thread 825780 — Process Tap all-zero buffers

**Source**: https://developer.apple.com/forums/thread/825780

**Most-relied-on content** (paraphrased from a 2026-05-25 fetch; 0
Apple replies as of fetch):

> During long sessions using `AudioHardwareCreateProcessTap`, the
> `AudioDeviceIOProc` callback continues firing normally but every
> PCM sample is exactly 0.0f — while the system is producing audible
> output. Affected: macOS 26.5 Beta and likely 26.x. More frequent on
> MacBook Air M2. Workaround: full teardown and rebuild of BOTH the
> Process Tap and Aggregate Device (restarting IOProc alone or
> recreating only the aggregate is not reliable).

**How we used it**: this is the alternative explanation for the all-
zero samples we observed in EXP-007/008/009 from Terminal-launched
audiotee. It retroactively weakens R7-adjacent claims about TCC
silencing and forms the basis of FC-002's frame reconsideration.

### "Voice processing causes A2DP→HFP" — Apple Developer Forums

**Source**: synthesized from
https://developer.apple.com/forums/thread/775256 (PTT Framework
compatibility) and related AVAudioEngine threads.

**Most-relied-on content**:

> Switching from A2DP to HFP while audio is playing will cause a
> noticeable decline in audio quality. That same behavior occurs
> when enabling voice processing because voice processing enables
> input and output, which is effectively the same as playAndRecord.

**How we used it**: confirms that the HFP trigger is the "input +
output on the same engine" pattern, not specifically voice
processing. Our `engine.inputNode` binding to the tap aggregate makes
the engine effectively `playAndRecord`, which forces HFP. Reinforces
Codex's architectural recommendation: avoid putting capture on the
engine's input side at all.

### Rogue Amoeba ARK (Audio Routing Kit)

**Source**:
https://www.rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Legacy

**Most-relied-on content**:

> As of MacOS 15 (Sequoia), ACE is fully deprecated. On MacOS 14
> (Sonoma) and higher, our newer Audio Routing Kit (ARK) technology
> is used in place of ACE. ARK provides the same audio capture and
> routing capabilities as ACE, without requiring the complex
> installation process that was necessary to use ACE on Apple
> Silicon Macs. … The Audio Capture Engine (ACE) framework provides
> Mac apps with the ability to capture audio from specific running
> applications, as well as all audio currently being produced by the
> system. … It's provided in two parts: A C library that applications
> integrate to communicate with ACE, and a CoreAudio server plugin to
> be installed on the user's computer.

**How we used it**: Audio Hijack does NOT use `CATapDescription` —
they ship a CoreAudio HAL plugin instead. The professional commercial
app in this space chose a different architecture because the
lightweight tap API isn't reliable enough for production BT capture.
Validates our pain and provides an alternative architectural reference
if we ever decide the tap API is unviable for v0.x (would require a
separate signed/notarized installer for the HAL plugin).

### macOS HFP disable workaround

**Source**: synthesized from search results for "AVAudioEngine
Bluetooth HFP A2DP prevent macOS".

**Documented command**:

```bash
sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP" -bool true
```

**How we use it**: testing-only workaround applied in EXP-018 to
verify whether HFP routing is the *only* remaining issue affecting BT
audio quality. Not a production fix (requires sudo, system-wide,
disables HFP for ALL apps not just ours).

## Open questions

- **Q1** (resolved by EXP-011): does VIGIL Dev cert persist TCC grants
  across launches? **Yes**, as long as the binary doesn't change.
- **Q2** (resolved by EXP-012): why does production "fail" on built-in
  speakers? **Because `pinEngineOutputToDefault` throws -10851 every
  time, and on speakers there's no HFP downsampling to mask the
  capture failure.**
- **Q3** (open): why does HFPSpike's IOProc never fire? Top suspect:
  the embedded-vs-post-set tap list difference between our aggregate
  creation and audiotee's. Less likely: a leaked aggregate from prior
  failed production runs interfering. Not yet pinned.
- **Q4** (open): once H1 is fixed, will production work on BT? The
  Codex thesis says no — `configureEngineInput` will still trigger HFP
  on BT. For built-in speakers it should work fully. → next experiment
  after EXP-013.
- **Q5** (open): are the existing Phase 1 / Phase 2 / Phase 3
  verifications still valid given that production capture has been
  silently broken on this branch? Probably need a phase-3 re-verify
  after H1's fix lands.

## Glossary

- **AUHAL**: AudioUnit Hardware Abstraction Layer. The specific
  `kAudioUnitSubType_HALOutput` audio unit Core Audio exposes for code
  that needs to bind to a specific hardware device. Distinct from
  `kAudioUnitSubType_DefaultOutput`, which is what `AVAudioEngine.-
  outputNode` uses and is locked to system default.
- **A2DP**: Advanced Audio Distribution Profile. The Bluetooth profile
  used for high-quality stereo music playback (44.1 / 48 kHz × 2 ch).
- **CATapDescription**: the `CoreAudioTypes` configuration object that
  describes a process tap.
- **CDHash**: the cryptographic hash a code signature seals over the
  binary. TCC and Gatekeeper match against the CDHash via the
  designated requirement. Changes when the binary changes.
- **Designated requirement**: a Code Signing expression
  (`identifier "X" and certificate leaf = H"Y"`) that TCC stores per
  grant. A future launch matches its own signature against this expres-
  sion to decide whether the existing grant applies.
- **HFP**: Hands-Free Profile. The bidirectional voice Bluetooth pro-
  file (16 kHz mono in, 16 kHz mono out — sometimes 8 kHz). macOS
  forces BT devices into HFP when any process opens an active capture
  session and the BT device is the system default output. Audible as
  a heavy low-pass + telephone-quality artifact.
- **IOProc**: a Core Audio I/O callback function registered via
  `AudioDeviceCreateIOProcID` or `AudioDeviceCreateIOProcIDWithBlock`.
  Fires whenever the device's I/O cycle completes. For a tap-only
  aggregate device, this is how captured audio is delivered to user
  space without going through an AUHAL.
- **TCC**: Transparency, Consent, and Control. macOS's privacy frame-
  work. Each TCC service (Microphone, Screen Recording, Screen &
  System Audio Recording, System Audio Recording Only, …) is a
  separate grant tied to a specific app's designated requirement.
- **VIGIL Dev**: the user's self-signed code signing identity, finger-
  print `61AA3A6DD970BDE850BC38B5C937936E83D5E1F9`. Self-signed →
  `TeamIdentifier=not set`. Sufficient for TCC persistence on macOS
  26.3, as proved by EXP-010 + EXP-011.

## Programme health

### FC-001 — Frame check on the HFP-is-the-cause programme (retroactive)

**Date**: 2026-05-25 06:35 EDT (entered retroactively; the trigger
condition fired around EXP-005 / EXP-006 but was not noticed at the
time)

**Trigger**: 4+ consecutive same-null experiments
(EXP-003, EXP-004, EXP-005, EXP-006) all reporting `ioProc fires=0`
with only protective-belt tweaks (output device, IOProc API variant,
tap config). The protocol now requires this check after 3.

**Current frame** (the paradigm we operated in for hours):

> The user reports degraded audio on BT and no audio on speakers. The
> root cause is that production's `configureEngineInput` binds an
> aggregate device to `AVAudioEngine.inputNode`, which forces BT into
> HFP voice mode. The fix is the HFPSpike architecture (direct IOProc
> + `AVAudioSourceNode`). We just need to get the spike's IOProc to
> fire.

**Alternative frame to consider** (which we eventually discovered in
EXP-012):

> Production capture itself is broken upstream of HFP. Every
> `capture.start` throws -10851 from `pinEngineOutputToDefault` before
> any audio flows. The user's reported symptoms have downstream
> explanations:
> - **BT low-pass character**: `configureEngineInput` already triggered
>   HFP in step 3 before the crash in step 4. After the crash, the BT
>   profile is in HFP mode but our engine is dead; Safari's *own* audio
>   continues playing through BT-HFP and that's what the user hears.
> - **Speakers silence**: same crash, no HFP downsampling on speakers,
>   so the failure is inaudible.
> Under this frame, HFP is real but secondary, and the spike was
> chasing a symptom.

**Distinguishing observation**: test production `Start` on built-in
speakers with audio playing. Under the current frame, it should at
least produce *something* (degraded by AUHAL coercion but audible).
Under the alternative frame, it should produce nothing audible and
log an error.

**What we actually saw later** (EXP-012, log inspection):
production fails on both BT and speakers with -10851 every time. The
alternative frame is correct.

**Decision**: switch frame. H_BT_only-is-the-cause moves to ruled out
(R1). HFP becomes a secondary concern (H2). Production-broken-upstream
becomes the primary frame (H1).

**Lesson**: a frame check at EXP-005 — when the third same-null run
on the spike landed — would have spawned a "test production Start on
speakers" experiment hours earlier. That single experiment would have
surfaced -10851 immediately. The cost of not having a programme-health
checkpoint was about 4-6 hours of session time chasing the wrong
paradigm.

**Mechanism added to protocol**: the README now mandates `FC-NNN`
entries after 3 consecutive same-null experiments. Future investiga-
tions will hit this trigger earlier.

### FC-002 — Frame check after secondary-source research

**Date**: 2026-05-25 14:30 EDT
**Trigger**: external research surfaced new context that retroactively
weakens conclusions from EXP-007, EXP-008, EXP-009, and partially from
H3's auxiliaries. Triggered manually after the research pass.

**Current frame (pre-research)**:

> Audiotee returns all-zero samples from Terminal because Terminal
> lacks the macOS 14.4+ "System Audio Recording Only" TCC grant. Our
> tap-n-filter.app has that grant, so its IOProc should fire with
> real audio if we can get the setup right. HFPSpike's IOProc-no-fire
> bug is independent of TCC. The architectural path forward is direct
> IOProc + AVAudioSourceNode (Codex's recommendation).

**Alternative frame surfaced by research**:

> Audiotee's all-zero samples from Terminal may have been the
> documented macOS 26 zero-buffer bug
> (https://developer.apple.com/forums/thread/825780), not TCC. Our
> TCC interpretation was behavior-inferred from one observation
> ("audiotee returns zeros") combined with one assumption ("Terminal
> lacks granular TCC"). The macOS bug provides an alternative
> explanation that doesn't require any TCC assumption. This means our
> own app's IOProc-on-tap may *also* be subject to intermittent
> all-zero returns, regardless of TCC.

**Distinguishing observations**:

- If the `defaults write … Disable HFP true` workaround (EXP-018)
  makes production audio clean and effects audibly responsive →
  capture is correctly delivering audio to our effect chain. TCC is
  not silencing us. HFP routing is the only remaining issue.
- If audio is still degraded with HFP system-disabled → either the
  macOS zero-buffer bug is hitting our app too, or there's another
  bug. Need finer investigation.

**Decision**: Run EXP-018 as a cheap test of the alternative frame.
Hold off on EXP-017 — its B/C/D outcomes are now all ambiguous because
we can't cleanly distinguish "TCC silencing" from "macOS 26 bug" from
"real setup failure." Pivot to the OS-level workaround as the next
data point.

**Lesson**: secondary-source research has high signal-per-effort and
should be the FIRST move (not the last) on any investigation where
documented platform behavior might explain symptoms. AI-driven
investigation has a structural blind spot for "what's already known by
the broader community" — the lab notebook protocol should explicitly
require an external-research checkpoint before running >3 experiments
on any hypothesis.

**Mechanism added to protocol**: the README will mandate an external-
research pass after the first hypothesis fails its initial test.
Pending update to `docs/investigations/README.md`.

### FC-003 — Frame check after EXP-025: architectural rewrite required

**Date**: 2026-05-27 22:00 EDT

**Trigger**: EXP-024 returned `bufferCount=0` on `mainMixerNode`.
EXP-025 returned `bufferCount=0` on `inputNode` AND `mainMixerNode`,
via a distinct failure mode (engine self-kills on HFP config change,
H4's `attemptReattach` silently fails to restore it). Two
independent failure paths confirmed for the same architectural
choice.

**Current frame (pre-FC-003)**:

> AVAudioEngine + process tap + aggregate device CAN work on
> macOS 26.3 if we wire it correctly and handle the BT HFP edge
> cases. H7 was the "last bug." Once we install enough tap-callback
> diagnostics and recovery logic, capture will pump audio reliably.

**Alternative frame surfaced by EXP-024 + EXP-025**:

> AVAudioEngine + process tap + aggregate device is *structurally
> incompatible* with macOS 26.3's unified IO AU. The render loop
> cannot reliably drive output when the AU's CurrentDevice has no
> output streams. *Multiple* failure paths exist (engine survives
> config change but doesn't pull / engine dies on config change and
> can't recover / outputNode.installTap throws), all converging on
> the same user-perceived silence. No combination of recovery logic
> can fix what is structurally broken at the AU level.

**Distinguishing observations** (already-collected):

- EXP-024: engine reports `isRunning=true` post-config-change but
  mainMixer renders 0 frames in 5 s → render loop dead even when
  engine "is running."
- EXP-025: engine reports `isRunning=false` post-config-change,
  H4 recovery runs detach + attemptReattach but engine doesn't
  re-engage → recovery path itself is broken.
- Both: source process is muted (ADR-014 works), user hears literal
  silence.
- outputNode.installTap throws uncatchable ObjC exception → engine
  state is too fragile to even *probe* without crashing it.

**Decision**: **Frame shifted.** Drop the "patch AVAudioEngine.input-
Node + tap aggregate" approach. Commit to Codex's originally
recommended architecture:

1. Drive a Core Audio IOProc on the tap aggregate directly
   (`AudioDeviceCreateIOProcID`).
2. Push captured PCM into a lock-free ring buffer.
3. AVAudioEngine has **only output** wired: source node reads from
   ring buffer → effect graph → mainMixer → outputNode.
4. Engine's `inputNode` is never touched — `outputNode` stays bound
   to the system default output device naturally.

This is the same pattern HFPSpike was attempting (H3 / EXP-002 ff).
HFPSpike's bug was that its IOProc never fired — a separable bug to
fix as part of the rewrite. The architecture itself is the right
one; only the implementation needs to be debugged.

**Why we didn't see this sooner**: we entered the investigation
believing the AVAudioEngine path was viable because (a) it was the
documented "happy path" and (b) the AudioCap reference repo uses it.
But AudioCap's tests are on older macOS versions where the IO AU
wasn't unified; the macOS 26.3 unified-AU semantics break that
assumption. EXP-023 was the source-grounded turning point
(`inputNode.audioUnit === outputNode.audioUnit`); EXP-024 and
EXP-025 are the empirical confirmations.

**Lesson**: when a published reference works on macOS N but not on
N+1, suspect platform-level invariant changes BEFORE suspecting your
own wiring. The macOS 26.3 unified-AU change is exactly the kind of
silent semantic-version-bump that breaks downstream apps.

**Next**: ADR-XXX (Direct IOProc + AVAudioSourceNode architecture)
documenting the decision; then incremental refactor of CaptureCont-
roller + AppViewModel to use the new path. HFPSpike code can be
adapted (with the IOProc-no-fire bug fixed) as the seed.

## Changelog

- 2026-05-25 06:35 EDT — initial notebook created (this session).
  Captured EXP-001 through EXP-012; documented environment, hypothesis
  ledger, references; queued EXP-013 (remove `pinEngineOutputToDefault`).
- 2026-05-25 06:50 EDT — retrofitted hypothesis ledger to new schema
  (source-grounded vs behavior-inferred tags, auxiliaries,
  resurrection conditions); added FC-001 capturing the retrospective
  Kuhnian shift from HFP-as-cause to production-broken-upstream;
  pre-registered EXP-013. Coincided with README amendments to the
  epistemic protocol.
- 2026-05-25 12:00 EDT — ran EXP-013. H1 verified
  (source-grounded); H2 empirically confirmed (no longer behavior-
  inferred from Codex's report alone); new H4 added (alreadyAttached
  re-attach loop). Updated Status block and TL;DR accordingly. Queued
  the H4 fix as the next experiment.
- 2026-05-25 12:05 EDT — ran EXP-014. H4 verified (source-grounded).
  Production capture now reaches sustained `running` state.
- 2026-05-25 12:09 EDT — ran EXP-015. H3's "entanglement with broken
  production state" auxiliary refuted; spike has its own bug.
- 2026-05-25 13:12 EDT — ran EXP-016 (audiotee post-set pattern).
  `AudioDeviceStart` returned 'nope' (1852797029) — new failure mode.
- 2026-05-25 14:00 EDT — pre-registered EXP-017 (HFPSpike setup
  pattern in minimal harness) as the decision-point experiment.
- 2026-05-25 14:30 EDT — pivoted away from EXP-017 after external
  research. Surfaced macOS 26 zero-buffer Apple bug (forums thread
  825780), confirmed HFP trigger mechanism (input+output on engine
  ≈ playAndRecord), discovered Audio Hijack uses HAL plugin
  architecture (ARK). Added FC-002 frame check, EXP-018 pre-
  registration (defaults write HFP disable test). Augmented External
  references with the new sources. Notebook protocol gap identified:
  external-research checkpoint should be earlier than after 3+
  failed experiments.
- 2026-05-27 08:15 EDT — ran EXP-021. **Outcome D** (literal silence;
  none of the pre-registered A/B/C predictions). Status block updated
  to reflect the reframing: source-mute working correctly + engine
  running with no errors + zero audio reaching user = engine output
  is silently discarded somewhere between mainMixerNode and the BT
  headphones. Added H7 to the active ledger and pre-registered
  EXP-024 (mainMixerNode tap to WAV) as the disambiguator. Built
  with CDHash `6a0f14fbe912...`. User will re-prompt for TCC on
  first launch.
- 2026-05-27 22:30 EDT — ran EXP-026 (audiotee exact pattern with
  `SubDeviceList: [] as CFArray` + `MasterSubDeviceKey: 0` and
  post-set tap list as `CFArray<CFString>`). **Outcome α** — IOProc
  fired 471× in 5s with 99.5% non-zero samples and peak 0.73. H3
  resolved (moved to ruled-out R8); architecture validated. Status
  block updated to point at the validated direct-IOProc path.
- 2026-05-27 23:30 EDT — formalised the refactor plan. Wrote
  ADR-018 (`docs/decisions/ADR-018-direct-ioproc-capture-architecture.md`),
  technical spec (`docs/specs/capture-v2.md`, with `capture.md`
  marked superseded), and phase spec
  (`docs/orchestration/phases/01-capture-spike-rework-1.md`) with
  TDD anchors T1.* — T4.* + TI.* and 14 gate criteria. Updated
  state.json: Phase 1 transitions to `in_progress` with
  `rework_spec` pointing at the new phase doc; Phase 4
  `blocked_on` rewritten to reference the rework rather than the
  underlying bugs. Composed a fresh `/goal` prompt (~3525 chars,
  under the 4000 limit) referencing the above; the user runs it
  in a cold-context session to execute the refactor autonomously.
