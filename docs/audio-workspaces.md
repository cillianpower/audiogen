# Audio workspaces: Generate, Extract, Transform

Implementation notes, 7 October 2026. SAM and AFTER are integrated as separate processing workspaces. Other proposed analysis/separation tools remain outside this scope.

## Navigation

Use three task tabs in the main window: **Generate**, **Extract**, **Transform**. The existing generation composer and engine picker belong to Generate. Extract uses SAM-Audio; Transform uses AFTER. Backend names appear in the workspace subtitle and runtime Settings.

Each workspace retains its inputs, settings, selected output and history when switching tabs. Switching tabs leaves running jobs intact. Settings continues to manage runtime/model installation and downloads independently.

## Extract — SAM-Audio

1. Drop or choose source audio, or send a library item into Extract.
2. Show the source waveform and a short field labelled **Sound to extract**. Example: “metallic percussion”.
3. Optionally mark examples on the waveform: **Sound is here** and **Sound is absent here**. These mark evidence for the target's identity; they do not define a crop or restrict output to those time spans.
4. Run **Extract**.
5. Audition **Original**, **Extracted sound**, and **Remaining audio** at a shared playhead. Export either result or both, with drag-to-DAW support.

Basic controls: source, sound description and optional anchors. Model selection, sampling quality and seed live in an optional advanced section. Do not offer unvalidated instrument presets that imply fixed-stem quality guarantees.

The [MLX adapter](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/sts/models/sam_audio/README.md) supports positive/negative temporal anchors only for standard separation, not its chunked long-file methods. Initial validation should use short clips. The eventual UI must explain the long-file limitation and provide an explicit choice of an anchored excerpt or unanchored long-file processing, preserving timeline offsets in exported results.

## Transform — AFTER

1. Drop or choose **Source audio**: the performance/structure to transform.
2. Drop or choose **Timbre reference**: the sound character to transfer.
3. Show clearly labelled inputs with separate audition controls.
4. Run **Transform**.
5. Compare original and transformed audio, save variations, and drag the result into a DAW.

Start with offline audio-to-audio processing. Expose a control such as **Follow source structure** only after mapping and validating the upstream structure-guidance parameter. Avoid presenting a generic “strength” control that suggests independent blend behavior the model does not provide. Add MIDI input once its own model/runtime path is validated.

[AFTER](https://github.com/acids-ircam/AFTER) documents separate timbre and structure conditioning, Apple Silicon MPS support, pretrained models and Max for Live deployment. Validate a specific checkpoint's usable reference domain, duration behavior and timing before deciding the final controls. Real-time plugin hosting is a separate feature.

## Application structure

Create separate extraction and transformation stores and request types. Reuse audio import, waveform, audition, filename handling, runtime downloads and owned-process cancellation.

The current `GenerationEngine` returns one audio file and the queue assumes `GenerationRequest`. SAM needs a job result with two named outputs. AFTER needs distinct structure and timbre inputs. Introduce a common processing job envelope with a task kind and named output artifacts; retain the existing generation payload and migrate persisted records compatibly. Do not make SAM and AFTER generation-engine presets.

Use a shared processing scheduler to prevent simultaneous heavy inference jobs exhausting unified memory. Model downloads remain independent. Jobs carry immutable input copies and settings; outputs record their parent job, model revision and original input paths. Keep SAM's two outputs together in history and export them at matching timeline positions.

## Implementation status

- SAM small has been validated on Apple Silicon with a real musical input and temporal-anchor path. It produced finite mono 24-bit target/residual outputs at 48 kHz with matching duration.
- AFTER instruments has been validated with a separate timbre reference and the exported TorchScript API. It produced a finite mono 24-bit output at 44.1 kHz with matching duration. MPS is preferred and CPU fallback is retained for unsupported exported operations.
- Shared processing persistence, named outputs, cancellation, workspace switching, and the heavy-job scheduler are implemented.
- The opt-in live test still covers all installed SAM/AFTER models and cancellation; run it before a release build.

Acceptance: inputs survive workspace switches; changing workspace cannot cancel jobs; processing never alters original audio; each result can be auditioned/exported independently; Settings presents accurate installed/download state; no processing control is enabled without its working runtime and required model.
