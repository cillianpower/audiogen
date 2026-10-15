#!/bin/zsh
# Opt-in maintainer check. Downloads the managed runtime, and missing models.
# Optional first argument: an existing ACE-Step checkpoints directory.
set -euo pipefail
cd "${0:A:h}/.."
ROOT="$PWD/.build/engine-smoke"
mkdir -p "$ROOT/Engines/ACE-Step/models" "$ROOT/Engines/ACE-Step/runtime/downloads"
if [[ -n "${1:-}" ]]; then
  python3 - "$1" "$ROOT/Engines/ACE-Step/models" <<'PY'
import json, pathlib, subprocess, sys
source, destination = map(pathlib.Path, sys.argv[1:])
manifest = json.load(open('Sources/Audiogen/Resources/ace-step.json'))
for item in manifest['models']:
    src, dest = source/item['name'], destination/item['name']
    if src.is_file() and not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/bin/cp', '-c', str(src), str(dest)], check=True)
PY
fi
AUDIOGEN_INTEGRATION_ROOT="$ROOT" swift test --filter LiveEngineTests
