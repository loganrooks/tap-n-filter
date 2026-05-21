// Capture module entry. The real types live alongside this file:
//   - CaptureSource.swift            value type identifying a tappable process
//   - CaptureState.swift             lifecycle state enum
//   - CaptureError.swift             typed errors
//   - CaptureControllerProtocol.swift public surface
//   - CoreAudioInterface.swift       HAL seam + RealCoreAudioInterface
//   - CaptureController.swift        the state machine
//
// See `docs/specs/capture.md` for the design, and
// `docs/decisions/ADR-001-capture-api.md` for the API decision.
