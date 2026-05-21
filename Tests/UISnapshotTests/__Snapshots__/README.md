# UI Snapshot Baselines

PNG files written by `SnapshotHelper` on first run of the snapshot tests. Subsequent runs assert byte-equality against the baselines committed here.

If a deliberate visual change lands, delete the relevant baseline file and re-run the tests — the next run writes the new baseline and passes.

The helper writes `*-actual.png` alongside the baseline when a drift is detected, for human inspection.

See `Tests/UISnapshotTests/SnapshotHelper.swift` for the comparison logic and `docs/governance/coding-standards.md` for the macOS-version-pinning note.
