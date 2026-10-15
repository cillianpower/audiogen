# Audiogen handover — SAM/AFTER workspaces

Updated 7 October 2026. The current task is to finish and verify the Extract and Transform workspaces.

## Implemented

- `Generate`, `Extract`, and `Transform` workspaces are routed from `ContentView`.
- SAM-Audio is integrated through `processing_worker.py` and returns named `Extracted sound` and `Remaining audio` WAVs.
- AFTER is integrated through the publisher's TorchScript checkpoints and returns `Transformed audio`.
- Settings has runtime/model cards for SAM-Audio and AFTER; model downloads are independent of inference.
- `AudioWorkScheduler` serializes heavy generation and processing jobs while preserving independent downloads.
- Processing history persists immutable source/reference paths, named outputs, metadata, cancellation, and recovery state.
- Finder renaming and native prompt editing work from the earlier task.

## Verified locally

- `swift build --scratch-path .build/unit` passes after the processing manifest exists.
- Real SAM small-model run completed on Apple Silicon: 10-second input, MLX backend, 48 kHz mono, two finite 24-bit outputs, about 15 seconds, peak memory reported as 5.48 GB.
- Real AFTER instruments checkpoint run completed with a separate timbre reference and produced a transformed output. The first run exposed the TorchScript API (`forward_stream`); the worker now uses the exported API.
- AFTER logs showed MPS execution succeeded after retrying through the model's exported path; CPU fallback remains available for unsupported MPS operations.

## Immediate next steps

1. Run `swift test --scratch-path .build/unit` again now that `Sources/Audiogen/Resources/PythonRuntimes/processing.json` exists. The previous run failed only because the manifest was generated after that build.
2. Inspect `Tests/AudiogenTests/ProcessingTests.swift`; its scheduler test should be kept focused on FIFO/cancellation and its live test is opt-in via `AUDIOGEN_PROCESSING_TEST_ROOT`.
3. Run the opt-in SAM and AFTER processing test against `.build/processing-smoke/Engines` if time permits. Confirm output duration, finite samples, 24-bit WAV, cancellation, and cleanup.
4. Run `scripts/build-app.sh`, then verify the packaged bundle contains `PythonRuntimes/processing.json`, `processing_worker.py`, SAM/AFTER locks, and the runtime source archives.
5. Update `README.md` and `docs/audio-workspaces.md`: the latter still says SAM/AFTER are “not yet integrated” and README still labels the release as 0.3.
6. Fix any UI compile/runtime issues found by a release build or a quick Extract/Transform window launch.

## Known limitations / risks

- All four AFTER audio checkpoints (`instr`, `drums`, `orchestral`, `speech`) are now downloaded and verified in `processing.json`.
- The AFTER worker uses the exported `forward_stream` methods and `generate_timbre`; verify that output duration remains exact for all four model families.
- `GenerationStore` uses `try! ProcessingCatalog.bundled()` during initialization. This is acceptable only when the packaged processing manifest is guaranteed to ship; tests and development builds need the manifest present.
- `restartEngine()` now takes the shared scheduler lease, but should be exercised against a queued processing job.
- The processing result panel keeps a shared playhead when switching Original/extracted/remaining/transformed output; verify this visually.

## Useful commands

```sh
swift test --scratch-path .build/unit
swift build --scratch-path .build/unit
scripts/build-app.sh
```

Real SAM/AFTER smoke artifacts are under `.build/processing-smoke/Validation`; runtime setup and download logs are under `.build/processing-research`.
