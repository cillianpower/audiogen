# Audiogen: technical notes

Build details, engine contracts, pinned versions and validation notes. For what the app is and how to use it, see the [README](../README.md).

Swift 6, SwiftUI, AppKit, AVFoundation. Apple Silicon only.

## Run

Open `build/Audiogen.app` after building:

```sh
scripts/build-app.sh
```

For development, run `scripts/build-minimax-runtime.sh` first (requires CMake and Xcode on the build machine), then open `Package.swift` in Xcode. The packaging script creates an arm64 app and applies an ad-hoc signature by default. Set `SIGNING_IDENTITY` to a Developer ID identity for a distributable signature. Notarization and a release distribution pipeline are still required before shipping to other Macs.

Open **Settings → Runtimes** to install runtimes and download models. The main window has Generate, Extract (SAM-Audio), and Transform (AFTER) workspaces. Downloads run independently of the generation and processing queues; models from different engines download concurrently, and downloads within one engine serialize to preserve shared files.

For ACE-Step, the app downloads a verified installer binary and self-contained Python, unpacks a pinned ACE-Step source release, installs its locked dependencies, downloads checksum-verified model files, and starts the official REST server on `127.0.0.1:8001`. Python, developer tools and Homebrew are not prerequisites for using the packaged app.

## Implemented in 0.4

Later additions (takes, short Stable Audio/MusicGen durations, search and stars, export options, Send To, drop-to-import, region drag-out, stereo Extract/Transform, undo, Standard/Glass appearance) are described in the README.


- Native sidebar, waveform player, bottom prompt composer and collapsible inspector.
- ACE-Step, MiniMax Music 3, Stable Audio 3, MusicGen MLX and YuE2 MLX engine selection, with separate runtime/model installations and capability-driven controls.
- MiniMax Music 3 text generation, bundled arm64 Metal worker, verified resumable model downloads, Efficient / Balanced / Quality presets with physical-memory checks for generation, and 44.1 kHz / 24-bit WAV output.
- ACE-Step installation, retained completed downloads and resumable interrupted transfers, health checks, restart, uninstall and logs.
- Text generation, duration, concrete random or explicit seeds, instrumental/no-vocals/no-percussion conditioning, Avoid field and advanced step count.
- Serial asynchronous queue; independent metadata for queued, finished, failed and cancelled results. **Both engines** queues the selected engine first and the other second using the same prompt and seed, stopping app-owned workers between engines. Both engines must be installed.
- ACE-Step Model inspector: import local Turbo, SFT, XL Turbo and XL SFT checkpoints; select a checkpoint, choose a matching LoRA and adjust its strength. Model/adapter settings are saved with each job. MiniMax retains its Efficient / Balanced / Quality model presets.
- Rename opens a focused name editor, renames its WAV in Finder, updates saved source/reference paths and avoids filename collisions. The prompt uses a native TextKit editor with a transparent background over the composer's Liquid Glass, preserving selection on updates and resize.
- Prompt history with Up at the beginning / Down at the end of the editor, preserving ordinary multiline navigation.
- Native playback, volume, seeking, region selection and region looping; streamed peak analysis cached between launches.
- Reference WAV/AIFF/FLAC/MP3/M4A import, preserving an original copy and converting to WAV with AVFoundation when needed.
- Repaint uploads source audio and sends the exact selected interval with an explicit mask.
- Sidebar file dragging and waveform Option-drag using existing file URLs for audio applications.
- Library JSON records keyed by immutable UUID, plain WAV files, configurable output directory and recoverable seeds/settings.
- SAM-Audio Extract workspace with sound descriptions, optional positive/negative temporal examples, target/residual outputs, matched-playhead audition, drag-to-DAW, and named-output history.
- AFTER Transform workspace with separate source and timbre-reference audio, model-family selection, structure guidance, MPS/CPU processing, matched-duration output, and independent history/export.
- Shared heavy-audio scheduler across Generate, Extract, and Transform; runtime/model downloads remain independent.

**Shortcuts:** ⌘Return Generate, Space Play/Pause outside text editing, ⌘R Variation, ⌘L Loop, ⌘I Inspector, ⌘O Import Audio, ⇧⌘O Reference, ⌘E Export, ⌘Z Undo removal, Delete Remove selected library entry outside text editing, arrow keys move the playhead in a focused waveform.

Removing a library entry deletes its metadata; its WAV remains on disk to preserve clips already dragged into an audio application. No generated or imported original file is overwritten.

## Engine contract and installation

`GenerationEngine` separates application state from networking. `MiniMaxEngine` uses the upstream `/synth` → `/job` API and binary-safe multipart result decoding; it stores the backend replay JSON including audio codes. Both model stages receive the same explicit seed. Requests route all five GGUF components explicitly, so another downloaded preset cannot silently change results. Cancellation uses the upstream per-job endpoint. Composer engine/model selections are independent of worker configuration and saved with each queued job. Switching the composer does not stop an active render. The serial generation queue stops other app-owned workers before loading a job's engine. Models download without replacing an active runtime; uninstall is disabled only for engines with active downloads or queued/running jobs.

MiniMax runtime commit `3eef71343e069866278fd9be8217af2cf72c6532`, GGML commit `40e16e4a814f7fe851a0c486fb9e8c722e957830`, and model snapshot `d4f7a6402a4ca10c8b3ca2f648c8a46c103558bc` are pinned. The maintainer build statically links the runtime and embeds Metal kernels; its binary hash and licenses ship inside the app. Users need no compiler. Each model download has a fixed SHA-256 in `Resources/minimax.json`.

MiniMax presets: Efficient (8.76 GB download, 16 GB Mac minimum), Balanced (10.16 GB, 24 GB minimum), Quality (12.82 GB, 32 GB minimum). Shared model files are reused. These memory gates include conservative headroom; they are not measured peak-memory claims. MiniMax currently exposes text generation only. Instrumental/no-vocals conditioning uses backend caption constraints plus `[instrumental]` structural conditioning because the upstream API requires a nonempty lyrics field. Avoid/no-percussion become backend caption conditioning, not a dedicated negative-CFG field. No lyrics editor is added.

`ACEEngine` implements the upstream asynchronous `/release_task` → `/query_result` → `/v1/audio` workflow. Both documented and OpenAI-style model inventories are supported. Reference/source audio uses streamed multipart uploads because the pinned server rejects absolute client paths by default. `/health` and `/v1/models` must confirm the selected loaded model before generation is enabled. A compatible server is reused and never terminated by this app. An app-owned process is stopped on application termination.

The bundled `Resources/ace-step.json` pins:

- ACE-Step tag `v0.1.8`, source commit `dce621408bee8c31b4fcf4811682eb9359e1bc94`.
- uv `0.12.23`, verified archive checksum.
- Self-contained CPython `3.11.17`, build `20261003`, verified archive checksum.
- Model snapshot `19671f406d603126926c1b7e2adc169acbcade22`, SHA-256 for every file.
- Fast preset: Turbo, 8 steps, conservative 16 GB physical unified-memory minimum.

Model download is approximately **10.1 GB**, plus several GB for dependencies. The LM files must exist because upstream's main-model preflight requires them, but LM inference is disabled in this initial sound-design workflow. Turbo has no direct negative CFG prompt, so Avoid and quick toggles become caption conditioning internally; the visible user prompt is preserved. These constraints cannot guarantee exclusion of a sound.

The installer runs `uv sync --frozen` against the pinned lockfile with a verified Python interpreter and disables automatic Python downloads. It does not run upstream bootstrap/update scripts. Runtime model loading is offline; the app is responsible for model downloads. The pinned upstream may synchronize model Python files from its own packaged source during initialization.

Model and runtime files are kept under:

```text
~/Library/Application Support/Audiogen/
    Engines/ACE-Step/{runtime,repository,models}
    Engines/MiniMax/{runtime,models,downloads}
    Generations/       # UUID-keyed JSON metadata
    References/        # immutable copied originals / backend WAVs
    Waveforms/         # cached peaks
    Config/
~/Library/Logs/Audiogen/
~/Music/Audiogen/Library/yyyy-MM-dd/*.wav
```

Existing installations continue using their original engine, library and log directories so the rename does not break saved audio paths or Python environments. New installations use the Audiogen paths above.

Generated WAV files are converted to 24-bit PCM at the backend's actual sample rate; there is no artificial upsampling. All HTTP inference traffic uses the fixed loopback origin. There are no accounts, telemetry or cloud inference. The only notifications are local ones when queued work finishes while the app is in the background.

ACE-Step currently has no job cancellation endpoint. Cancelling a running job terminates an app-owned worker; subsequent queued jobs start a fresh worker. With a shared server, cancellation discards the result locally and explains that the external render may continue.

Installation of a new version requires a maintainer-validated manifest; the app never follows `main` or automatically replaces inference versions. `scripts/resolve-manifest.py` is a maintainer tool for resolving pinned model hashes, not an application installation step.

## Validation

```sh
scripts/build-minimax-runtime.sh
swift test
AUDIOGEN_TEST_MINIMAX=1 swift test --filter MiniMaxTests/testLiveInstallAndGenerate
scripts/check-engine.sh /path/to/existing/ACE-Step/checkpoints
```

Validated on macOS 27.0.1 / Apple Silicon with 48 GB unified memory: automated checks passed, followed by a real managed-engine installation, 48 kHz / 24-bit WAV render, reference upload, selected-region repaint and process shutdown. Native UI checks confirmed prompt editing, inspector, playback, region selection and loop shortcuts. Sample results are in `build/Validation/`.

MiniMax also completed a real Efficient-preset Metal render (10 seconds requested, 2 DiT steps for the smoke test), verified stereo 44.1 kHz / 24-bit output, cancellation and worker shutdown. The sample is `build/Validation/minimax-smoke.wav`. The live test downloads and verifies models into `.build/minimax-smoke`; it does not compile inference code during installation.

The normal tests cover API wrappers and JSON-string results, loopback-only result validation, readiness checks, conditioning and repaint payloads, manifest integrity, SHA-256 verification, persistence/recovery, preservation of dragged audio, reference conversion, 24-bit output without upsampling, and waveform caching at the original sample rate.

The opt-in engine check installs a real managed runtime into `.build/engine-smoke`, verifies existing model copies or downloads missing files, starts ACE-Step, renders a short WAV, repaints a region and stops its worker. Existing checkpoints are cloned into test storage, never modified. It needs network access, disk space and an Apple Silicon Mac with sufficient memory.

Continuation, multi-output batches within one engine and collections remain deferred. A clean-machine installer test, Developer ID/notarization, and real Ableton/Logic drag tests are release gates.

## Upstream references

- [MiniMax C++ runtime and API](https://github.com/ServeurpersoCom/minimaxmusic.cpp/tree/3eef71343e069866278fd9be8217af2cf72c6532)
- [MiniMax GGUF model snapshot](https://huggingface.co/Serveurperso/MiniMax-Music3-GGUF/tree/d4f7a6402a4ca10c8b3ca2f648c8a46c103558bc)
- [ACE-Step official source](https://github.com/ace-step/ACE-Step-1.5/tree/v0.1.8)
- [Official REST API](https://ace-step.github.io/ACE-Step-1.5/en/API)
- [Official Apple Silicon API launcher](https://github.com/ace-step/ACE-Step-1.5/blob/v0.1.8/start_api_server_macos.sh)

## Additional engine investigation

[Apple Silicon runtime assessment](engine-research.md) covers the integrated Stable Audio 3, MusicGen and YuE2 MLX workers, their pinned sources and practical limits.

For ACE-Step checkpoint imports, download the complete folder using its upstream model name, then use **Settings → Runtimes → ACE-Step options (⋯) → Import Local Checkpoint…**. The shared encoder/VAE still require the standard ACE-Step installation. Choose the model after import. SFT uses 50 steps by default, Turbo eight; XL requires at least 32 GB unified memory. Custom model/LoRA inference needs validation on your selected weights; Settings also offers checksum-verified downloads for the bundled checkpoint variants.

## Runtime library

**Settings → Runtimes** shows a single scrollable list of five engines with installation summaries. Expand Models to manage downloads; the engine options menu contains file management and local checkpoint imports. **General** contains the library folder and diagnostics. Settings works independently of the prompt composer. Install a runtime on its own or Download a model (which also prepares its runtime). Each model row shows download size, memory required for generation, transfer rate, current file, verification phase, and Pause/Resume. Inactivity timeouts report interrupted transfers rather than leaving an indefinite spinner; expired resume data is retried from the pinned URL. Complete files and valid resume data are retained. Runtime dependency installation writes a named log available from **General → Diagnostics**.

Stable Audio 3 offers Small Music, Small Sound Effects and Medium Music, plus reference conditioning, repainting, explicit negative prompts and model-matched LoRAs. MusicGen offers Small/Medium/Large in mono and stereo; generation and decoding use the upstream MLX/PyTorch paths. Its model weights use CC BY-NC 4.0. YuE2 offers eight-bit and BF16 autoregressive models with a shared BF16 acoustic stage and decoder. Optional lyrics appear in its inspector. Its duration control is an upper bound: it may end naturally sooner or reach the bound with a truncated output.

The new Python workers use independently managed CPython 3.12.15 and checksum-verified uv, immutable source archives, packaged `uv.lock` files, and checksum-verified model snapshots. No Python or compiler is needed from the user. Inference is offline and never silently downloads or installs anything. Each render launches an isolated worker process; cancellation stops it. The worker log and request/replay metadata are kept with the engine/library. Transcription and score-editing UI are not included in the initial YuE2 integration.

Opt-in runtime installation and render checks:

```sh
scripts/check-runtimes.sh               # all three new runtimes
scripts/check-runtimes.sh stableAudio   # one runtime: stableAudio, musicGen, yue
```

These checks use `.build/python-smoke`, preserve the user's engine installation, and need disk space and network access for the selected models. Normal tests cover the catalog, download serialization/independence and cancellation, composer selection during downloads, rename transactions and rollback, and prompt selection across updates/resize.
