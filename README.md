# Audiogen

Audiogen is a Mac app for making raw sounds with audio models that run locally. It is designed around a workflow meant primarily for sampling. You describe a sound, listen to a few versions, keep the one you like and drag it into a DAW or Finder. 

Audiogen is not a song generator like Suno, and it isn't trying to become one. Some of the models it runs can produce full songs, vocals included, and it won't stop you trying. But the app is built around making short, rough clips that you finish yourself: cut them, layer them and put effects on them in your DAW. 

If you want a finished track from a single prompt, other tools are better suited to that, and you'll likely find Audiogen awkward for it.

## Usage

### Main Window

The main window has three workspaces, switched from the top of the window.

**Generate** is where most of the work happens. The sidebar is your library: everything you've generated or imported, searchable, with stars and a filter by engine. The middle shows the selected sound with its waveform. The prompt box sits at the bottom, with duration, number of takes, and the Generate button. The inspector on the right (⌘I) has the model, seed, conditioning toggles such as "No vocals" and "No percussion", reference strength, and LoRA settings where the model supports them.

**Extract** uses SAM-Audio. Drop in a recording, describe what you want out of it, and you get "Extracted sound" and "Remaining audio". For clips under 30 seconds you can also mark a few regions where the sound is or isn't present, which helps it work out what you mean.

**Transform** uses AFTER. It takes two inputs: the source (what gets played) and a timbre reference of up to 30 seconds (what it should sound like). AFTER has separate models for instruments, drums, orchestral sounds and speech. Pick the one closest to your reference.

Any result can be sent between workspaces from its **Send To** menu, so you can extract a sound and then transform it, or use an extracted sound as a reference in Generate.

### Models

Audiogen doesn't come with models. You download them in **Settings › Runtimes**, and each one installs its own isolated runtime the first time. Nothing else needs to be installed: no Python, Homebrew or developer tools.

| Engine | Good for | Download | Memory |
| --- | --- | --- | --- |
| Stable Audio 3 | Sound effects, short musical clips, variations on a reference, repainting a region | 1.9 GB (Small Music or Small Sound Effects), 6.9 GB (Medium Music) | 8 GB, 16 GB for Medium |
| MusicGen | Instrumental loops and phrases, mono or stereo | 2–7.7 GB depending on size | 8–24 GB |
| ACE-Step 1.5 | Longer musical material, references, repainting, LoRAs | 10.1 GB for Turbo, 20 GB for the XL models | 16 GB, 32 GB for XL |
| MiniMax Music 3 | Longer musical material from text | 8.8 GB (Efficient) to 12.8 GB (Quality) | 16–32 GB |
| YuE2 | Songs with optional lyrics. Included, but not what the app is built around | 10.5 GB | 24 GB |
| SAM-Audio | Extract | 3.3 GB (Small), 5.9 GB (Base) | 16 GB, 24 GB for Base |
| AFTER | Transform | About 0.25 GB per model | 8 GB |

Each engine's runtime adds a few more gigabytes on top of its models. "Memory" means the unified memory of your Mac. Audiogen won't start a model on a Mac with less than its listed amount.

If you're not sure where to start, try Stable Audio 3 Small Sound Effects or Small Music. They're small downloads and fast, they can make clips as short as a second, and they support references and repainting.

A few quirks worth knowing:

- ACE-Step and MiniMax need at least 10 seconds per generation. Stable Audio and MusicGen go down to 1 second.
- YuE2 treats the duration as a maximum and may stop earlier.
- Extract and Transform output mono by default. Turn on **Keep stereo** to process each channel separately, which takes about twice as long.
- Conditioning like "No percussion" nudges the model rather than guaranteeing anything. You'll still get the occasional drum.

### Import & Export

**Out.** Drag any row in the sidebar, the **Drag Audio** label above the waveform, or Option-drag the waveform itself. If part of the waveform is selected, you drag just that selection as its own WAV. Selections are written to a `Clips` folder next to the original and never deleted, because DAWs like Ableton reference files where they are rather than copying them. **Export…** (⌘E) gives you options: peak or loudness normalisation (−1 dBFS or −14 LUFS), 44.1 or 48 kHz, and trimming silence with short fades.

**In.** Drop audio onto the sidebar or the waveform area, or onto the Audiogen icon in the Dock, or use **File › Import Audio…** (⌘O). It's added to your library as an imported item. WAV files are copied as they are, so 32-bit float bounces keep their headroom; AIFF, FLAC, MP3 and M4A are converted to 24-bit WAV. Dropping a file on the prompt box instead uses it as reference audio for the next generation, if the selected engine takes one (Stable Audio and ACE-Step do). Otherwise it's imported like any other drop.

### Shortcuts

| | |
| --- | --- |
| ⌘Return | Generate |
| ⌘R | New variation of the selected sound |
| Space | Play / pause |
| ← → | Move the playhead (Option for finer steps, Shift to select, ⌘ to jump to either end) |
| ⌘L | Loop the selection |
| ⌘E | Export |
| ⌘O | Import audio |
| ⇧⌘O | Choose reference audio |
| ⌘I | Show or hide the inspector |
| Delete, then ⌘Z | Remove from the library, and undo it |



## Installation

Download the latest `Audiogen-<version>-arm64.zip` from the [Releases](https://github.com/cillianpower/audiogen/releases) page, unzip it and move Audiogen to your Applications folder. It's signed and notarised by Apple, so it opens like any other app.

Audiogen doesn't come with models. Open **Settings › Runtimes** and download the ones you want; Stable Audio 3 Small is a good first one.


## Licences

The models are made by other people and come with their own licences, which apply to what you make with them. MusicGen's weights are CC BY-NC 4.0, which rules out commercial use. MiniMax Music 3 uses its own community licence, which is bundled with the app. Read the licence for each model you download before using the results in something you sell. Audiogen itself is MIT-Licensed.


## Requirements and building

You need an Apple Silicon Mac running macOS 27 or later, and enough free disk space for the models you want (see the table above).

To build it yourself you need Xcode and CMake:

```sh
scripts/build-app.sh
open build/Audiogen.app
```

The build script compiles the bundled MiniMax runtime, then the app, and signs it ad hoc for your own Mac. `scripts/release.sh` makes a Developer ID signed, notarised build for distribution; it needs a Developer ID certificate and an Apple account signed into Xcode.

## Status

This is version 0.4 and still rough in places. Things that are known and not yet done:

- ACE-Step can't cancel a render on a server it didn't start; the result is just discarded.
- Only some model sizes have been checked with real renders. Others are installed and checksum-verified, but not yet tested by ear.

## More detail

[docs/technical.md](docs/technical.md) covers how the engines are wired up, the pinned versions, installation, tests and validation. [docs/engine-research.md](docs/engine-research.md) and [docs/audio-workspaces.md](docs/audio-workspaces.md) are the original design notes for the engines and the Extract and Transform workspaces.
