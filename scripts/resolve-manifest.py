#!/usr/bin/env python3
"""Maintainer tool: resolve fixed upstream assets; never run by the application."""
import hashlib, json, urllib.request
from pathlib import Path
root = Path(__file__).resolve().parents[1]
revision = '19671f406d603126926c1b7e2adc169acbcade22'
repo = 'ACE-Step/Ace-Step1.5'
def fetch(url):
    with urllib.request.urlopen(url) as response: return response.read()
tree = json.loads(fetch(f'https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true&expand=false'))
models = []
for item in tree:
    path = item['path']
    if item['type'] != 'file' or not (path.startswith(('Qwen3-Embedding-0.6B/', 'acestep-v15-turbo/', 'vae/', 'acestep-5Hz-lm-1.7B/')) or path == 'config.json'): continue
    url = f'https://huggingface.co/{repo}/resolve/{revision}/{path}'
    sha = item.get('lfs', {}).get('oid') or hashlib.sha256(fetch(url)).hexdigest()
    models.append(dict(name=path, url=url, sha256=sha, bytes=item['size']))
manifest = dict(engine='ace-step', version='v0.1.8', platform='macos-arm64', sourceRevision='dce621408bee8c31b4fcf4811682eb9359e1bc94', modelRevision=revision,
 runtime=dict(name='uv-aarch64-apple-darwin.tar.gz', url='https://github.com/astral-sh/uv/releases/download/0.12.23/uv-aarch64-apple-darwin.tar.gz', sha256='50487ae565ccd96e499056b4674d438f4c53170202617b4c759defe0c6a1b544', bytes=17044217),
 python=dict(name='python.tar.gz', url='https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.11.17%2B20261003-aarch64-apple-darwin-install_only_stripped.tar.gz', sha256='0c9fbd0b2ddfbb6877493a650259bf379ee71a91b17f0f5f06dd2dcd52fbcade', bytes=26974674),
 repository=dict(name='ace-step.tar.gz', url='https://codeload.github.com/ace-step/ACE-Step-1.5/tar.gz/refs/tags/v0.1.8', sha256='a736d0819a720f50cc0b1d6fc970ed25b7bea35fc0b504decb329d4aa0d9e220', bytes=8419099), repositoryDirectory='ACE-Step-1.5-0.1.8', models=models,
 presets=[dict(id='acestep-v15-turbo', name='Fast', minimumMemoryGB=16, steps=8)])
(root/'Sources/Audiogen/Resources/ace-step.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(f'Resolved {len(models)} files, {sum(x["bytes"] for x in models)/1e9:.1f} GB')
