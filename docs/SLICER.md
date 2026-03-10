# Sample Slicer (`slicer`)

## Overview

Loads a single audio file and chops it into N equal-length slices, each triggerable by MIDI note. Designed for chopping drum breaks, loops, and longer audio into playable segments — a classic MPC/SP-404 workflow.

## Parameters

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `file` | FilePath | — | — | Path to a WAV file (or a JSON with a single sample) |
| `slices` | int | 16 | 2–64 | Number of equal slices to chop the sample into |
| `mode` | enum | one_shot | one_shot / loop / gate | Playback behavior per slice |
| `attack` | float | 0.001 | 0.001–2.0 | ADSR attack time (seconds) |
| `decay` | float | 0.1 | 0.01–2.0 | ADSR decay time |
| `sustain` | float | 1.0 | 0.0–1.0 | ADSR sustain level |
| `release` | float | 0.05 | 0.001–10.0 | ADSR release time |
| `volume` | float | 1.0 | 0.0–2.0 | Master output volume |

## Ports

### Inputs (spread)
- `notes` — MIDI note numbers (from MidiInput operator)
- `velocities` — MIDI velocities (0.0–1.0)
- `gates` — gate signals (>0.5 = on)

### Outputs (audio)
- `left` — left channel audio
- `right` — right channel audio

## Slicing

The loaded audio file is divided into `slices` equal segments:

```
slice_length = total_frames / num_slices
slice_start[i] = i * slice_length
slice_end[i] = (i + 1) * slice_length
```

MIDI note mapping: note 36 = slice 0, note 37 = slice 1, ..., note (36 + N - 1) = slice N - 1.

No pitch interpolation — all slices play at the original recorded pitch. Sample rate mismatch is corrected: `playback_rate = sample_sr / runtime_sr`.

## Playback Modes

- **one_shot** — slice plays from start to end once triggered. Re-triggering the same slice restarts it. Gate-off is ignored.
- **loop** — slice loops continuously between its start and end points while gate is held. On gate-off, enters ADSR release.
- **gate** — slice plays while gate is held, enters ADSR release on gate-off. Does not loop. If the slice reaches its end before gate-off, playback stops.

## Voice Allocation

Up to 16 simultaneous voices. Each slice can have one active voice — re-triggering the same slice cuts the previous voice. Different slices can play simultaneously.

## Processing

Per audio buffer (256 samples at 48kHz):
1. Read spread inputs, detect gate edges
2. On note-on: compute slice index from note, allocate voice, set playback position to slice start
3. On note-off: enter ADSR release (for gate/loop modes)
4. For each active voice:
   - Read samples from the loaded audio at `playback_pos`
   - Advance `playback_pos` by `playback_rate`
   - If `playback_pos >= slice_end`: stop (one_shot/gate) or wrap to `slice_start` (loop)
   - Apply ADSR envelope
5. Sum all voices into stereo output buffers

## Changing Slice Count

When the `slices` parameter changes at runtime, slice boundaries are recalculated immediately. Any currently playing voices are stopped to avoid reading out-of-bounds positions.

## Thread Safety

Same pattern as the other sampler operators:
- `main_thread_update()` handles file loading and atomic pointer swap
- `process_audio()` reads the atomic pointer, never blocks
- Deferred deletion of old data on next main thread update

## Dependencies

- `vivid::adsr` from `operator_api/adsr.h` — envelope generation
- `miniaudio` — WAV file decoding
- Shared infrastructure: `sample_bank.h` (for WAV decoding), `voice.h`

## Example Workflow

1. Load a drum break WAV (e.g., 4-bar loop at 120 BPM)
2. Set `slices` to 16 (one slice per beat subdivision)
3. Connect MidiInput -> slicer
4. Trigger individual slices to rearrange the break
5. Use with `vivid-sequencers/drum_sequencer` to program a pattern from the slices
