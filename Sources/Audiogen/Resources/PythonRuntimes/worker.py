"""Pinned, offline runtime adapters. Inference never installs or downloads files."""
import json
import math
import os
from pathlib import Path
import runpy
import sys
from urllib.parse import unquote, urlparse


def local_path(value):
    if value is None:
        return None
    parsed = urlparse(value)
    return unquote(parsed.path) if parsed.scheme == 'file' else value


def conditioning(request):
    prompt = request['prompt']
    if request.get('instrumental') or request.get('noVocals'):
        prompt += '\nInstrumental only, without singing, speech or vocals.'
    if request.get('noPercussion'):
        prompt += '\nNo drums, percussion or rhythmic beat.'
    if request.get('avoid'):
        prompt += '\nExclude: ' + request['avoid']
    return prompt


def stable_audio(config):
    import numpy as np
    import soundfile as sf
    source = Path(config['sourceRoot'])
    weights = Path(config['modelRoot']) / 'stable'
    sys.path[:0] = [str(source / 'scripts'), str(source)]
    import weights as upstream_weights
    # Upstream loaders retain their file naming but resolve into our managed models.
    def resolve(relative, verbose=True):
        path = weights / Path(relative).name
        if not path.is_file():
            raise FileNotFoundError('Download the selected model in Audiogen Settings: ' + str(path))
        return path
    upstream_weights.ensure_local = resolve
    request = config['request']
    args = ['sa3_mlx.py', '--prompt', conditioning(request), '--dit', request['model'],
            '--decoder', 'same-l' if request['model'] == 'medium' else 'same-s',
            '--seconds', str(request['duration']), '--steps', str(request['steps']),
            '--seed', str(request['seed']), '--out', config['output']]
    negative = request.get('avoid', '')
    if request.get('noVocals') or request.get('instrumental'):
        negative += ', vocals, singing, speech'
    if request.get('noPercussion'):
        negative += ', drums, percussion, beat'
    if negative.strip(', '):
        args += ['--negative-prompt', negative.strip(', '), '--cfg', '3.0']
    input_file = local_path(request.get('source') if request['mode'] == 'Repaint' else request.get('reference'))
    if input_file:
        audio, sr = sf.read(input_file, dtype='float32', always_2d=True)
        if sr != 44100:
            from scipy.signal import resample_poly
            divisor = math.gcd(sr, 44100)
            audio = resample_poly(audio, 44100 // divisor, sr // divisor, axis=0)
        if audio.shape[1] == 1:
            audio = np.repeat(audio, 2, axis=1)
        converted = str(Path(config['output']).with_name('reference-44100.wav'))
        sf.write(converted, audio[:, :2], 44100, subtype='PCM_16')
        args += ['--init-audio', converted]
        if request['mode'] == 'Repaint':
            region = request['region']
            args += ['--inpaint-range', f"{region['start']},{region['end']}"]
        else:
            args += ['--init-noise-level', str(max(0.1, 1 - request.get('referenceStrength', 0.5)))]
    if request.get('lora'):
        args += ['--lora', local_path(request['lora']), '--lora-strength', str(request.get('loraScale', 1))]
    previous = sys.argv
    try:
        sys.argv = args
        runpy.run_path(str(source / 'scripts' / 'sa3_mlx.py'), run_name='__main__')
    finally:
        sys.argv = previous
    if request['mode'] == 'Repaint':
        rendered, rate = sf.read(config['output'], dtype='float32', always_2d=True)
        if rate != 44100:
            raise ValueError('Unexpected Stable Audio sample rate')
        region = request['region']
        first = max(0, round(region['start'] * rate))
        last = min(len(audio), round(region['end'] * rate))
        if not first < last <= len(rendered):
            raise ValueError('The render does not cover the selected repaint interval')
        # The model's codec reconstruction changes unmasked waveform samples.
        # Preserve the original outside the requested region and crossfade only
        # within its edges; generated audio remains in the selected interval.
        preserved = audio[:, :2].copy()
        patch = rendered[first:last, :2].copy()
        fade = min(round(0.005 * rate), len(patch) // 2)
        if fade:
            ramp = np.linspace(0, 1, fade, dtype='float32')[:, None]
            patch[:fade] = preserved[first:first + fade] * (1 - ramp) + patch[:fade] * ramp
            patch[-fade:] = preserved[last - fade:last] * ramp + patch[-fade:] * (1 - ramp)
        preserved[first:last] = patch
        sf.write(config['output'], preserved, rate, subtype='PCM_24')
    return {}


def musicgen(config):
    import mlx.core as mx
    import numpy as np
    import soundfile as sf
    import torch
    from transformers import T5Tokenizer, T5EncoderModel, EncodecModel
    root = Path(config['modelRoot'])
    # Upstream's model checkpoints refer to Hub names for shared components.
    # Redirect those loaders to checksum-verified local files, with offline mode.
    def redirect(cls, folder):
        original = cls.from_pretrained
        def load(_cls, name, *args, **kwargs):
            kwargs['local_files_only'] = True
            return original(str(root / folder), *args, **kwargs)
        cls.from_pretrained = classmethod(load)
    redirect(T5Tokenizer, 't5-base')
    redirect(T5EncoderModel, 't5-base')
    redirect(EncodecModel, 'encodec_32khz')
    sys.path.insert(0, config['sourceRoot'])
    from audiocraft_mlx.models.musicgen import MusicGen
    request = config['request']
    mx.random.seed(request['seed']); torch.manual_seed(request['seed'])
    model = MusicGen.get_pretrained(str(root / request['model']))
    model.set_generation_params(duration=request['duration'])
    audio = model.generate([conditioning(request)], progress=True)
    sf.write(config['output'], np.array(audio[0]).T, model.sample_rate, subtype='PCM_24')
    return {'sample_rate': model.sample_rate, 'channels': model.audio_channels}


def yue(config):
    import numpy as np
    import soundfile as sf
    source = Path(config['sourceRoot'])
    sys.path[:0] = [str(source / 'src'), str(source / 'vendor/yue/src')]
    import lyra
    import lyra.pipeline as pipeline
    from importlib.metadata import PackageNotFoundError
    # Audiogen runs the verified source tree directly. Upstream's replay
    # metadata expects an installed distribution; use its declared source
    # version when that distribution record is absent.
    distribution_version = pipeline.version
    def source_version(name):
        try:
            return distribution_version(name)
        except PackageNotFoundError:
            if name != 'mlx-yue':
                raise
            return lyra.__version__
    pipeline.version = source_version
    from lyra.pipeline import YuE2Pipeline
    from yue2.protocol import GenerationConfig, Sampling
    root = Path(config['modelRoot'])
    request = config['request']
    # YuE produces a natural ending, rather than an exact duration. Bound semantic
    # token generation for a requested clip while preserving its natural output.
    maximum = max(1, min(9000, round(request['duration'] * 25)))
    generation = GenerationConfig(ode_steps=request['steps'], semantic=Sampling(min_tokens=min(200, maximum), max_tokens=maximum))
    pipe = YuE2Pipeline.from_pretrained(str(root / 'yue'), vae=str(root / 'yue-vae'),
        precision=request['model'], local_files_only=True, generation_config=generation,
        progress=True)
    try:
        lyrics = request.get('lyrics') or '[Instrumental]'
        result = pipe(style=conditioning(request), lyrics=lyrics, cot='off', seed=request['seed'])
        sf.write(config['output'], np.asarray(result.audio), result.sample_rate, subtype='PCM_24')
        return {'sample_rate': result.sample_rate, 'timing': result.timing,
                'natural_duration': len(result.audio) / result.sample_rate, 'truncated': result.truncated,
                'effective_config': result.config}
    finally:
        pipe.close()


def main(path):
    config = json.loads(Path(path).read_text())
    if not config['request']['prompt'].strip():
        raise ValueError('Enter a prompt')
    adapters = {'stableAudio': stable_audio, 'musicGen': musicgen, 'yue': yue}
    result = adapters[config['engine']](config)
    replay = {'engine': config['engine'], 'source_revision': config['sourceRevision'],
              'request': config['request'], 'result': result}
    Path(config['metadata']).write_text(json.dumps(replay, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main(sys.argv[1])
