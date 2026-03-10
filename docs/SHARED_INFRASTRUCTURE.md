# Shared Infrastructure

Common code shared by all three sampler operators (`sp404`, `sampler`, `slicer`). Lives in `src/common/`.

## Files

| File | Purpose |
|------|---------|
| `sample_bank.h` | Data structures, JSON parsing, WAV decoding |
| `voice.h` | Voice struct, allocation, per-sample rendering |
| `miniaudio_impl.c` | Compiles miniaudio decoder (single translation unit) |

## `sample_bank.h`

### Data Structures

```cpp
struct SampleData {
    std::vector<float> samples_L;   // left channel (or mono)
    std::vector<float> samples_R;   // right channel (empty if mono)
    uint32_t sample_rate;
    bool stereo;
};

struct SampleRegion {
    int root_note;          // MIDI note the sample was recorded at
    int lo_note, hi_note;   // note range this sample covers
    int lo_vel, hi_vel;     // velocity range (0–127)
    float volume_db;        // per-region volume adjustment
    float pan;              // stereo pan (-1.0 to 1.0)
    int tune_cents;         // fine tuning in cents
    bool loop_enabled;
    uint32_t loop_start;    // loop start frame
    uint32_t loop_end;      // loop end frame
    uint32_t loop_crossfade;// crossfade length in frames
    std::shared_ptr<SampleData> data;  // decoded audio (shared across regions)
};

struct SampleGroup {
    std::string name;
    int keyswitch;          // MIDI note that activates this group (-1 = none)
    float attack, decay, sustain, release;
    std::vector<SampleRegion> regions;
};

struct SampleBank {
    std::string name;
    std::vector<SampleGroup> groups;
    float attack, decay, sustain, release;  // top-level envelope defaults
};
```

### Why `shared_ptr<SampleData>`

Multiple `SampleRegion` entries in different groups might reference the same WAV file (e.g., the same sample used in two velocity layers). `shared_ptr` allows safe sharing and automatic cleanup when all referencing regions are destroyed.

### Functions

#### `SampleBank* load_sample_bank(const std::string& json_path)`

1. Read JSON file from disk
2. Parse with yyjson
3. Detect format: top-level `"samples"` array (single-group) vs `"groups"` array (multi-group)
4. For each sample entry, resolve `"path"` relative to the JSON file's directory
5. Decode each WAV via `decode_wav()`
6. Deduplicate: if two regions reference the same WAV path, share the `SampleData`
7. Return heap-allocated `SampleBank*` (caller takes ownership)

#### `std::shared_ptr<SampleData> decode_wav(const std::string& abs_path)`

Thin wrapper around miniaudio's decoder:

```cpp
ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 0, 0);
// 0 channels = preserve original channel count
ma_decoder decoder;
ma_decoder_init_file(path.c_str(), &config, &decoder);
// Read all frames into SampleData
// Set stereo = (decoder.outputChannels >= 2)
// Set sample_rate = decoder.outputSampleRate
ma_decoder_uninit(&decoder);
```

#### `const SampleRegion* find_region(const SampleGroup& group, int note, int velocity)`

Linear scan through regions, returns first match where `lo_note <= note <= hi_note` and `lo_vel <= velocity <= hi_vel`. Returns `nullptr` if no match.

## `voice.h`

### Voice Structure

```cpp
struct Voice {
    bool active = false;
    int note = -1;
    float velocity = 1.0f;
    double playback_pos = 0.0;
    double playback_rate = 1.0;     // pitch ratio (1.0 = original pitch)
    vivid::adsr::State envelope;
    const SampleRegion* region = nullptr;
    bool one_shot = false;
    uint64_t start_frame = 0;       // for voice-stealing (oldest first)
};
```

### Voice Helpers

#### `void voice_note_on(Voice& v, int note, float velocity, const SampleRegion* region, double playback_rate, uint64_t frame, bool one_shot)`

Initialize a voice for playback:
- Set note, velocity, region, playback_rate
- Reset playback_pos to 0 (or to `loop_start` if looping)
- Call `vivid::adsr::gate_on(v.envelope)`
- Set `v.active = true`, `v.start_frame = frame`

#### `void voice_note_off(Voice& v)`

- If `one_shot`, do nothing (let it play out)
- Otherwise call `vivid::adsr::gate_off(v.envelope)`

#### `void voice_render_frame(Voice& v, float& out_L, float& out_R, float dt, float attack, float decay, float sustain, float release)`

Render one sample frame from a voice:

1. Read sample data at `playback_pos` using linear interpolation:
   ```
   idx = floor(playback_pos)
   frac = playback_pos - idx
   sample = data[idx] * (1 - frac) + data[idx + 1] * frac
   ```
2. Apply volume: `sample *= velocity * db_to_linear(region->volume_db)`
3. Apply pan: simple constant-power or linear pan
4. Advance ADSR: `vivid::adsr::advance(v.envelope, dt, attack, decay, sustain, release)`
5. Apply envelope: `sample *= v.envelope.env_value`
6. Advance playback position: `playback_pos += playback_rate`
7. Handle end-of-sample / loop boundaries
8. If ADSR reaches IDLE, set `v.active = false`

Output `out_L` and `out_R` are added to (not overwritten), allowing the caller to sum multiple voices.

#### `int find_free_voice(Voice* voices, int count)`

Returns the index of an inactive voice, or -1 if all are active.

#### `int steal_oldest_voice(Voice* voices, int count)`

Returns the index of the voice with the smallest `start_frame`.

### Gate Edge Detection

Shared logic used by all three operators:

```cpp
struct GateTracker {
    static constexpr int kMaxSlots = 16;
    float prev_gates[kMaxSlots] = {};
    uint32_t prev_len = 0;

    // Returns: +1 = rising edge (note on), -1 = falling edge (note off), 0 = no change
    int detect(int slot, float current_gate);

    // Call at end of frame to update state
    void update(const float* gate_data, uint32_t len);
};
```

## `miniaudio_impl.c`

Single-file compilation unit for miniaudio:

```c
#define MA_NO_DEVICE_IO      // we only need the decoder, not playback
#define MA_NO_THREADING       // no background threads needed
#define MA_NO_ENCODING        // no WAV/MP3 encoding needed
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
```

This compiles as a static library that all three operator modules link against, avoiding the ~300KB implementation being duplicated in each `.dylib`.

## Thread Safety Pattern

All three operators follow the same pattern (established by `movie_audio_out.cpp`):

```cpp
// Member variables
std::atomic<SampleBank*> bank_{nullptr};
SampleBank* deferred_delete_ = nullptr;
std::string last_path_;

// Main thread — called each frame
void main_thread_update(double time) override {
    // 1. Deferred delete (old bank is safe to free now)
    delete deferred_delete_;
    deferred_delete_ = nullptr;

    // 2. Check if file path changed
    const char* path = /* from file_param_values */;
    if (path == last_path_) return;
    last_path_ = path;

    // 3. Load new bank
    SampleBank* new_bank = load_sample_bank(path);

    // 4. Atomic swap
    SampleBank* old = bank_.exchange(new_bank, std::memory_order_acq_rel);

    // 5. Defer deletion of old bank
    deferred_delete_ = old;
}

// Audio thread — called per buffer
void process_audio(const VividAudioContext* ctx) override {
    SampleBank* bank = bank_.load(std::memory_order_acquire);
    if (!bank) { /* output silence */ return; }
    // ... render voices using bank ...
}
```

The key guarantee: after the atomic swap, the next `main_thread_update()` call happens after at least one audio buffer has been processed with the new pointer, so the old pointer is safe to delete.

## Build Integration

### CMakeLists.txt

```cmake
# Compile miniaudio decoder as static lib
add_library(miniaudio_impl STATIC src/common/miniaudio_impl.c)
target_include_directories(miniaudio_impl PRIVATE ${VIVID_SRC_DIR}/deps/miniaudio)
target_compile_definitions(miniaudio_impl PRIVATE
    MA_NO_DEVICE_IO MA_NO_THREADING MA_NO_ENCODING)

# Each operator links against it
set(VIVID_SAMPLER_OPS sp404 sampler slicer)
foreach(name IN LISTS VIVID_SAMPLER_OPS)
  add_library(${name} MODULE src/${name}.cpp)
  target_include_directories(${name} PRIVATE
    ${VIVID_SRC_DIR}/src
    ${VIVID_SRC_DIR}/deps/miniaudio
    ${VIVID_SRC_DIR}/deps/yyjson
    ${CMAKE_CURRENT_SOURCE_DIR}/src/common)
  target_link_libraries(${name} PRIVATE miniaudio_impl)
  target_compile_features(${name} PRIVATE cxx_std_17)
  set_target_properties(${name} PROPERTIES
    PREFIX "" SUFFIX "${VIVID_PLUGIN_SUFFIX}"
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
endforeach()
```

## Dependency Map

```
operator_api/operator.h    ─── AudioOperatorBase, Param, VIVID_REGISTER
operator_api/adsr.h        ─── vivid::adsr::{State, advance, gate_on, gate_off}
deps/miniaudio/miniaudio.h ─── ma_decoder (WAV decoding)
deps/yyjson/yyjson.h       ─── JSON parsing

src/common/sample_bank.h   ─── SampleBank, SampleRegion, load_sample_bank(), decode_wav()
src/common/voice.h         ─── Voice, GateTracker, voice_note_on/off, voice_render_frame
src/common/miniaudio_impl.c─── miniaudio compiled implementation

src/sp404.cpp   ──┐
src/sampler.cpp ──┼── all include sample_bank.h + voice.h, link miniaudio_impl
src/slicer.cpp  ──┘
```
