# Apple Silicon music engines — 7 October 2026

The candidates below have documented Apple Silicon implementations. Performance numbers are upstream reports, not Audiogen measurements. All three now have selectable managed runtime integrations in Audiogen. Runtime installation and model download are separate Settings operations; generation remains serial.

| Candidate | Runtime and useful capabilities | Integration assessment |
| --- | --- | --- |
| Stable Audio 3 | Official pure MLX runtime; small music, small sound effects and medium music models. Text generation, audio-to-audio, inpainting, negative CFG prompts and LoRA loading. | Integrated: small music, small SFX and medium, including reference/repaint and LoRA controls. |
| MusicGen | Community MLX port. Small, medium and large models; transformer inference uses MLX, text encoding uses PyTorch, and stereo decoding also uses PyTorch. | Integrated: small/medium/large, mono and stereo. The upstream port describes itself as an early release. |
| YuE2-3B | Community MLX implementation with quantization, text/lyrics generation, score conditioning, transcription and covers. | Integrated: direct generation with optional lyrics and a duration upper bound. Score and transcription UI remain future work. |

## Stable Audio 3

[Official MLX runtime](https://github.com/Stability-AI/stable-audio-3/blob/main/optimized/mlx/README.md) documents a Python/MLX CLI with explicit output paths and a benchmark script. Its upstream M4 Pro / 48 GB table reports 30-second generation in 1.53 seconds for small music and 5.06 seconds for medium, with peak memory of 1.94 GB and 3.89 GB respectively. These are promising short-clip claims to reproduce locally before setting Audiogen memory gates. The runtime supports model-matched LoRAs.

The integration pins the source and converted weight snapshot, packages an isolated Python runtime with locked dependencies, exposes music/SFX/medium presets, and wraps the CLI in the serial queue. Small Music has passed real generation and repaint checks below. Medium, SFX and custom LoRAs still need individual render validation. Audiogen does not run the upstream unpinned bootstrap script.

## MusicGen

[MLX port](https://github.com/andrade0/musicgen-mlx) reports small-model generation of eight seconds in 6.3 seconds on M4 Max, versus around 24 seconds for stereo large. Its current implementation is a mixed MLX/PyTorch runtime and should be assessed as such. [Meta's model-weight license](https://github.com/facebookresearch/audiocraft/blob/main/LICENSE_weights) is CC BY-NC 4.0; the port's code license does not replace that model-weight license. This matters when positioning generated assets for commercial production.

## YuE2

[MLX runtime](https://github.com/vanch007/mlx-Yue) documents Python 3.12, native MLX inference, BF16/eight-bit weights and a frozen dependency lockfile. Its reported device tests include M3 Max / 128 GB and M5 Air / 32 GB. It uses a sampled 16 GiB process budget; that is not a demonstrated 16 GB Mac minimum. Transcription/covers also need ffmpeg. Compare instrumental adherence, speed and memory on our hardware before choosing it over a simpler sound-design engine.

## Existing engine model loading

ACE-Step's pinned v0.1.8 source contains standard and XL model implementations and `/v1/lora/load`, `/v1/lora/unload`, `/v1/lora/scale` endpoints. Audiogen now imports complete local `acestep-v15-turbo`, `acestep-v15-sft`, `acestep-v15-xl-turbo` and `acestep-v15-xl-sft` checkpoint folders into its managed model directory. The original checkpoint stays in place; existing managed checkpoints are never replaced. Imports check folder contents but do not have the checksum guarantees of bundled model downloads. Startup stays offline and confirms the selected model in the server inventory. SFT defaults to 50 steps; Turbo defaults to eight. XL has a conservative 32 GB memory gate, awaiting local peak-memory measurements.

LoRA path and strength are captured in each ACE-Step request. Before each ACE-Step job, Audiogen unloads the previous adapter, loads that job's adapter if present, and sets its strength. This also means adapter state on a shared server changes globally: a dedicated worker is preferable for adapter comparisons. Removing an adapter in the inspector affects subsequent jobs; it does not rewrite queued requests. Matching the adapter's training checkpoint remains the user's responsibility. Real SFT/XL and custom-adapter renders have not been validated by this change's unit tests.

MiniMax already offers Efficient, Balanced and Quality GGUF combinations. The [pinned runtime](https://github.com/ServeurpersoCom/minimaxmusic.cpp/tree/3eef71343e069866278fd9be8217af2cf72c6532) has no exposed LoRA-loading contract in its current server implementation, so Audiogen does not offer a misleading LoRA control for it.

## Pinned integrations

| Runtime | Source revision | Worker environment |
| --- | --- | --- |
| Stable Audio 3 | `3a82c807b69cf4b7c5c05270011a5d5e47abac18` | MLX 0.32.2, packaged dependency lock |
| MusicGen MLX | `3c2451568b56297cd8443c4e2a7d09093ee89f96` | MLX 0.32.2 + PyTorch, packaged dependency lock |
| YuE2 MLX | `9253ed133343406947bde7b67d43c7a63fb39d99` | MLX 0.32.2 + mlx-lm 0.31.3, packaged dependency lock |

`Sources/Audiogen/Resources/PythonRuntimes/catalog.json` pins model snapshots and SHA-256 values; `python312.json` pins the standalone interpreter. Sources and dependency environments are isolated per runtime. Stable Audio's weight resolver and MusicGen's shared component loaders are redirected to Audiogen's verified local model directories, so generation cannot fall back to unpinned Hub downloads. YuE2 uses the verified local conversion plus pinned VAE; its acoustic stage also requires BF16 AR weights even when the semantic AR stage is eight-bit.

Stable Audio Small Music completed a real 10-second / 44.1 kHz / 24-bit render in isolated test storage. The repaint check found that upstream codec reconstruction changes samples outside the mask, so Audiogen composites the generated interval into the original audio and crossfades within the interval edges. The final repaint check preserved every sample outside seconds 2–4 and preserved total duration.

MusicGen Small completed a real 10-second / 32 kHz / 24-bit mono render using its isolated locked environment and local verified weights. Larger and stereo presets still need individual render validation.

YuE2 eight-bit completed a real 9.999-second / 48 kHz / 24-bit stereo render with a 10-second upper bound and two acoustic steps. Its render took 8.5 seconds after pipeline verification. This smoke test reached the token limit; it does not establish full-song quality or natural-ending behavior. Its source-tree integration reports the declared `lyra` version when installed-distribution metadata is absent.

The final combined runtime check passed real generation and cancellation of an owned worker for all three engines. Sample WAVs are in `build/Validation/0.3-runtimes/`. The normal suite passed 38 checks, with three heavyweight tests skipped unless explicitly enabled.
