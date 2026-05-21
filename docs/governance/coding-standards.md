# Coding Standards

This document describes the code-level conventions the orchestrator follows. The conventions are pragmatic and Swift-flavored; they aren't exhaustive style rules.

## Language and platform

- Swift 5.10+ syntax (the version shipping with Xcode 16+).
- macOS 14.4 deployment target. No back-deployment.
- SwiftUI for UI; AppKit only when SwiftUI's capabilities fall short (e.g., for certain `NSSavePanel` interactions from `MenuBarExtra`).
- Combine for reactive state where needed; otherwise `@Published` plus `ObservableObject`.
- Swift Concurrency (`async`/`await`, `Task`) for lifecycle and setup work.

## File and module organization

- Each top-level module under `Sources/<Module>/` is documented in `docs/specs/architecture.md`.
- One primary type per file, named after the type (`Graph.swift`, `EffectNode.swift`).
- Helper types and extensions in the same file as the type they extend, unless the file grows beyond ~400 lines, at which point split.
- Tests under `Tests/<Module>Tests/` mirror the structure of `Sources/<Module>/`.

## Naming

- Types: `UpperCamelCase`. Concrete types over generic ones where the call site is clearer (e.g., `EQNode` rather than `Effect<EQConfig>`).
- Methods and properties: `lowerCamelCase`.
- Constants at file or type scope: `lowerCamelCase` (Swift convention; not `UPPER_SNAKE_CASE`).
- Acronyms: capitalize the first letter only for new code (`EqNode` not `EQNode`). The codebase already uses `EQNode` and `UIController` for legibility; consistency within the file matters more than dogma.
- Booleans: positive phrasing (`isRunning`, not `notIdle`). State enums for non-binary conditions (`CaptureState` instead of `isCapturing`).

## Documentation comments

- Public surfaces (types, methods, properties marked `public` or `open`) have triple-slash doc comments.
- Internal types may have doc comments where the type's purpose isn't obvious from the name.
- Comments explain *why*, not *what*. The code already says what. Comments fill in motivation, gotchas, references to external docs or specs.

Example:

```swift
/// Creates a Core Audio process tap for the given pid.
///
/// The tap is created with a stereo mixdown, matching the V1 stereo-only model
/// in docs/specs/capture.md. The tap is private (not visible to other apps)
/// and non-exclusive (the source app's audio is not redirected — it still goes
/// to the default output as well as into our tap).
///
/// - Parameter pid: The process identifier to tap.
/// - Returns: The AudioObjectID of the created tap.
/// - Throws: `CaptureError.tapCreationFailed` if the OS returns an error.
private func createTap(for pid: pid_t) throws -> AudioObjectID { ... }
```

## Error handling

- Errors are typed (`enum SomeError: Error`) rather than `NSError` or generic `Error` throws.
- Errors carry enough context to debug: include the offending input, the underlying OSStatus, etc.
- Top-level error handling (in the view model) maps domain errors to user-friendly messages. Lower-level code throws the typed errors and lets the boundary decide presentation.
- `fatalError` is reserved for genuinely unrecoverable programmer-error situations. User-facing failure modes never `fatalError`.

## Concurrency

- Long-running setup (capture start, engine configuration) is `async`.
- The audio thread runs the engine's render loop; the orchestrator does not call into render-thread code from elsewhere.
- View model is `@MainActor`.
- Combine publishers cross thread boundaries via `.receive(on: DispatchQueue.main)` when observed by UI.

## Force-unwrapping

- Avoid `!` outside of:
  - Test code where the failure indicates a test bug.
  - Static well-known values (`URL(string: "https://example.com")!`).
  - Cases where the compiler should be able to prove safety but can't (rare; document with a comment).

- Prefer `guard let` with a typed throw or default return over force-unwrapping.

## Tests

- Test names are descriptive sentences: `func test_capture_recovers_after_source_quit()`.
- Use XCTest. Async tests use `async throws` directly; `XCTAssertEqual` rather than `expect()` matchers.
- Integration tests gated by environment variable `RUN_INTEGRATION_TESTS=1` to keep regular CI fast.
- Snapshot tests pinned to a specific macOS runner version in CI.
- A failing test is never disabled to make CI green. Either fix it or document why it's expected-failing with a TODO and an issue link.

## Commits

- Conventional commits style: `<type>(<scope>): <subject>`.
  - Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `state`, `audit`.
  - `state(<phase>): <new status> (<reason>)` for `state.json` updates.
- First line ≤ 72 characters.
- Body wrapped at 80 characters.
- Body explains *why* if the diff alone doesn't make it obvious.
- Issue and PR references in the footer: `Refs: #123`.

## Pull requests

- One phase per PR. Phases are not split or combined.
- PR description includes: scope summary, what changed, what was *not* changed, link to the phase spec, link to any new ADRs.
- PR body uses the template at `.github/PULL_REQUEST_TEMPLATE.md`.

## Source attribution and licensing

- Anything copied or closely adapted from another open-source project includes attribution in a code comment with the source repo URL and license type.
- AudioCap is referenced extensively in the capture layer; comments cite the relevant file in AudioCap when patterns are borrowed.
- License headers are not required on every Swift file (the repo-wide LICENSE is sufficient).

## Things to avoid

- **Global mutable state.** No globals outside of `EffectNodeRegistry.shared` and similar deliberately-shared singletons, all documented.
- **String-keyed dictionaries for type-safe data.** Use enums or structs.
- **Excessive abstraction.** A protocol with one implementation is usually a class. Protocols are introduced when there are multiple implementations or when a seam is needed for testing.
- **Premature optimization.** Profile first. The audio thread is the only place where micro-optimization is reasonable in V1.
- **Comment debt.** When code changes, comments are updated. Stale comments are worse than no comments.

## Formatting

- Use `swift-format` with the project's `.swift-format` config. Format on save.
- Indent with 4 spaces (Swift convention).
- Maximum line width 110 characters (slightly above the Swift convention of 100, because diff width matters less than readability on Logan's screen setup).
- Trailing commas where the language allows (lists, arrays).

## Imports

- Standard library imports at the top, then frameworks, then internal modules, then local types.
- One import per line.
- Don't import what you don't use.

## Dependencies

- Swift Package Manager. No CocoaPods, no Carthage.
- Each new dependency triggers an ADR justifying its inclusion.
- Preference: Apple frameworks > Swift Package Index packages with active maintenance > less-maintained packages > writing it ourselves. The orchestrator does not add dependencies for things easily implemented in 50 lines.
