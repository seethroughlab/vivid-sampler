# Chromatic Sampler (`sampler`)

## Overview

A pitched sample playback instrument that maps samples across the keyboard with pitch interpolation. Loads multi-sample packs (e.g., lap steel, cello, organ) where each sample covers a range of notes, and playback pitch is adjusted based on the distance from the sample's root note. Supports multi-articulation packs with group selection.

## Parameters

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `file` | FilePath | — | — | Path to a sample pack JSON file |
| `attack` | float | 0.0 | 0.0–2.0 | ADSR attack override (0 = use JSON value) |
| `decay` | float | 0.0 | 0.0–2.0 | ADSR decay override (0 = use JSON value) |
| `sustain` | float | 0.0 | 0.0–1.0 | ADSR sustain override (0 = use JSON value) |
| `release` | float | 0.0 | 0.0–10.0 | ADSR release override (0 = use JSON value) |
| `volume` | float | 1.0 | 0.0–2.0 | Master output volume |
| `voices` | int | 8 | 1–16 | Maximum polyphony |
| `group` | int | 0 | 0–31 | Active sample group index (for multi-articulation packs) |

## Ports

### Inputs (spread)
- `notes` — MIDI note numbers (from MidiInput operator)
- `velocities` — MIDI velocities (0.0–1.0)
- `gates` — gate signals (>0.5 = on)

### Outputs (audio)
- `left` — left channel audio
- `right` — right channel audio

## Sample Pack JSON Format

### Single-group (e.g., one articulation)

```json
{
  "name": "open",
  "source_format": "DecentSampler",
  "samples": [
    {
      "path": "samples/open/B3.wav",
      "root_note": 59,
      "lo_note": 59,
      "hi_note": 65,
      "lo_vel": 0,
      "hi_vel": 127,
      "volume_db": 0.8,
      "pan": 0.0,
      "tune_cents": 0,
      "loop_enabled": false,
      "loop_start": 0,
      "loop_end": 0,
      "loop_crossfade": 0
    }
  ],
  "envelope": {
    "attack": 0.0, "decay": 0.0, "sustain": 1.0, "release": 0.3
  }
}
```

### Multi-group (e.g., multiple articulations with keyswitch)

```json
{
  "name": "Lapsteel Combined",
  "groups": [
    {
      "name": "Open",
      "keyswitch": 24,
      "envelope": { "attack": 0.0, "decay": 0.0, "sustain": 1.0, "release": 0.3 },
      "samples": [
        { "path": "samples/open/B3.wav", "root_note": 59, "lo_note": 59, "hi_note": 65 }
      ]
    },
    {
      "name": "Slide Down",
      "keyswitch": 25,
      "envelope": { ... },
      "samples": [ ... ]
    }
  ]
}
```

The `group` parameter selects which group is active. Groups can also be switched via keyswitch notes defined in the JSON.

## Pitch Interpolation

When a played note differs from a sample's `root_note`, the playback rate is adjusted:

```
semitone_diff = played_note - root_note + (tune_cents / 100.0)
playback_rate = 2^(semitone_diff / 12.0)
```

Sample rate mismatch is also corrected:

```
effective_rate = playback_rate * (sample_sr / runtime_sr)
```

Sub-sample positioning uses linear interpolation between adjacent samples for smooth playback:

```
idx = floor(playback_pos)
frac = playback_pos - idx
output = data[idx] * (1 - frac) + data[idx + 1] * frac
playback_pos += effective_rate
```

## Region Lookup

For a given note and velocity, the sampler scans regions in the active group to find one where:
- `lo_note <= note <= hi_note`
- `lo_vel <= velocity <= hi_vel`

The first matching region is used. If no region matches, the note is silent.

## Loop Behavior

When `loop_enabled` is true for a sample region:
- Playback loops between `loop_start` and `loop_end` frame positions
- `loop_crossfade` defines the crossfade length (in frames) for smooth loop transitions
- The loop sustains while the gate is held; on gate-off, the ADSR release phase begins

When `loop_enabled` is false:
- Sample plays to its end, then the voice enters ADSR release
- If the gate is released before the sample ends, ADSR release begins immediately

## Voice Allocation

- Up to `voices` simultaneous notes (default 8)
- When all voices are in use, the oldest voice is stolen
- Each voice tracks: note, velocity, playback position, playback rate, ADSR state, region pointer

## Velocity Response

Velocity scales the voice amplitude: `voice_amplitude = velocity * region_volume_linear`. The `volume_db` from the JSON region is converted to linear gain.

## ADSR Envelope

Each voice has an independent ADSR envelope using `vivid::adsr` from `operator_api/adsr.h`:
- Default values come from the JSON `envelope` section (per-group or top-level)
- Non-zero operator parameters override the JSON values
- Envelope modulates voice amplitude

## Thread Safety

Same pattern as the SP-404 operator:
- `main_thread_update()` handles file loading and `SampleBank*` atomic swap
- `process_audio()` reads the atomic pointer, never blocks
- Deferred deletion of old bank on next main thread update

## Dependencies

- `vivid::adsr` from `operator_api/adsr.h` — envelope generation
- `miniaudio` — WAV file decoding
- `yyjson` — JSON parsing
- Shared infrastructure: `sample_bank.h`, `voice.h`

## Example Use Cases

- **Lap steel** — `lapsteel-articulations/lapsteel-combined.json`: 3 articulations (open, slide-up, slide-down), switch via `group` param
- **Organ** — `Orgel Unterhaus/`: 10 stops mapped across C3–F7, looping samples
- **Cello** — `Geotape - Liam Phan/`: chromatic cello/tape samples
