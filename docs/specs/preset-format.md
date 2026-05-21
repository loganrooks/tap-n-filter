# Preset Format (`.tnf`)

tap-n-filter presets are plain-text JSON files with the `.tnf` extension. They are designed to be read, edited, and shared as files.

## Format

A `.tnf` file is a UTF-8 encoded JSON document conforming to the `GraphPreset` schema.

```json
{
  "formatVersion": 1,
  "name": "distant-engines",
  "outputGain": 1.0,
  "nodes": [
    {
      "typeIdentifier": "tnf.eq",
      "id": "2EF8A6F0-1234-5678-9ABC-DEF012345678",
      "displayName": "EQ",
      "bypass": false,
      "wetDryMix": 1.0,
      "parameters": {
        "hp.frequency": 80.0,
        "hp.Q": 0.707,
        "lp.frequency": 800.0,
        "lp.Q": 1.2
      },
      "extras": {}
    },
    {
      "typeIdentifier": "tnf.reverb",
      "id": "8B3C7D90-FEDC-BA98-7654-321098765432",
      "displayName": "Reverb",
      "bypass": false,
      "wetDryMix": 0.7,
      "parameters": {},
      "extras": {
        "preset": "largeHall"
      }
    }
  ]
}
```

## Field reference

### Top-level

| Field | Type | Required | Description |
|---|---|---|---|
| `formatVersion` | int | yes | Format version. Current: `1`. |
| `name` | string | yes | User-visible preset name. |
| `outputGain` | float | yes | Post-graph gain. Range 0.0–2.0, default 1.0. |
| `nodes` | array of `EffectState` | yes | Effect chain, ordered from input to output. |

### `EffectState`

| Field | Type | Required | Description |
|---|---|---|---|
| `typeIdentifier` | string | yes | Effect type. `tnf.eq`, `tnf.reverb`, etc. |
| `id` | string (UUID) | yes | Instance identifier. New UUID generated on save. |
| `displayName` | string | yes | User-visible name (may equal the type's default). |
| `bypass` | bool | yes | Whether the effect is bypassed. |
| `wetDryMix` | float | yes | Wet/dry mix, 0.0–1.0. |
| `parameters` | object (string → float) | yes | Parameter values keyed by parameter identifier. |
| `extras` | object | yes | Type-specific state that doesn't fit `parameters`. |

## Versioning

`formatVersion` is an integer that increments when the schema changes incompatibly. Loaders for version N must be able to load presets of version N or earlier (with migrations as needed).

V1 ships with version 1. Migrations from version 0 are not needed (no prior version exists).

When the format version is bumped:
- Older presets are migrated on load via a `PresetMigrator`.
- An ADR documents the change and the migration logic.
- Tests verify migration produces equivalent graphs.

## Compatibility across effect versions

A preset may reference effects that don't exist (older preset, newer build) or that have new/removed parameters. The loader:

1. **Unknown `typeIdentifier`** — the loader logs a warning and skips the node. The user sees a warning banner: "Preset contained 1 unknown effect that was skipped."
2. **Unknown parameter identifier** — silently ignored (forward compat).
3. **Missing required parameter** — the effect uses its default value, logs a warning.
4. **Parameter out of range** — clamped to range, logs a warning.

The loader never throws on a recoverable mismatch. It returns the best-effort graph and a list of warnings. The UI surfaces warnings as a non-blocking notice.

## Bundled presets

Four presets ship inside the app bundle at `Resources/Presets/`:

- `distant-engines.tnf` — the original ambient-engines preset. Heavy lowpass at 800Hz, large hall reverb at 70% wet.
- `submerged.tnf` — lowpass at 500Hz, plate reverb, slight modulation if implemented.
- `next-room.tnf` — gentle lowpass at 2.5kHz, small room reverb at 30% wet.
- `dry.tnf` — passthrough with a small gain trim. Useful as a baseline.

These are loaded by reference when the user selects from the "Factory Presets" menu. The actual file is read from the bundle on demand; the app does not copy them to a user-writable location.

## User presets

Users save and load presets via the File menu's "Save As..." and "Load..." options. These present standard macOS save/open panels filtered to `.tnf`. The app does not maintain a list of "your presets" — presets are just files at user-chosen locations.

A future version may add an in-app preset library that watches a configured directory.

## Sharing

`.tnf` files are plain text. They can be:

- Pasted into a gist or Discord message.
- Embedded inline in a forum post (using fenced JSON blocks).
- Versioned in git alongside a project.
- Edited in any text editor (Vim, VS Code, Obsidian).

The format is intentionally human-readable. Field names are descriptive, parameter identifiers use a `<band>.<param>` convention where helpful, and the structure is shallow.

## Validation

The app validates presets on load. Validation errors:

- Invalid JSON → loader throws, UI shows "Preset file is not valid JSON."
- Missing required top-level fields → loader throws, UI shows "Preset is missing required fields."
- `formatVersion` greater than supported → loader throws, UI shows "This preset was made with a newer version of tap-n-filter."

Validation passes through to the loader, which then handles per-node mismatches as described above.

## Schema reference

A JSON Schema document for `.tnf` files is published at `docs/specs/tnf-schema.json` (TODO: generate during Phase 2 from the Swift types). The schema is referenced from each bundled preset via `$schema`, enabling editor support in tools like VS Code.
