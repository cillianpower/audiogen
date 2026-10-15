#!/bin/zsh
# Maintainer/CI build only. End users receive this runtime inside Audiogen.
set -euo pipefail
cd "${0:A:h}/.."
REVISION=3eef71343e069866278fd9be8217af2cf72c6532
GGML_REVISION=40e16e4a814f7fe851a0c486fb9e8c722e957830
SOURCE="$PWD/.build/minimax-source"
OUTPUT="$PWD/Sources/Audiogen/Resources/MiniMaxRuntime"
if [[ ! -d "$SOURCE/.git" ]]; then
    mkdir -p "$SOURCE"
    git -C "$SOURCE" init
    git -C "$SOURCE" remote add origin https://github.com/ServeurpersoCom/minimaxmusic.cpp
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null || true)" != "$REVISION" ]]; then
    git -C "$SOURCE" fetch --depth 1 origin "$REVISION"
    git -C "$SOURCE" checkout --detach "$REVISION"
fi
git -C "$SOURCE" submodule update --init --depth 1
[[ "$(git -C "$SOURCE/ggml" rev-parse HEAD)" == "$GGML_REVISION" ]]
cmake -S "$SOURCE" -B .build/minimax-build \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple \
    -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=OFF
cmake --build .build/minimax-build --target mm-server -j 8
mkdir -p "$OUTPUT"
cp .build/minimax-build/mm-server "$OUTPUT/mm-server"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$OUTPUT/mm-server"
else
    codesign --force --sign - "$OUTPUT/mm-server"
fi
cp "$SOURCE/LICENSE" "$OUTPUT/LICENSE-runtime"
cp "$SOURCE/ggml/LICENSE" "$OUTPUT/LICENSE-ggml"
curl -fsSL https://huggingface.co/Serveurperso/MiniMax-Music3-GGUF/raw/d4f7a6402a4ca10c8b3ca2f648c8a46c103558bc/LICENSE -o "$OUTPUT/LICENSE-model"
python3 - <<'PY'
import hashlib, json
from pathlib import Path
root = Path('Sources/Audiogen/Resources/MiniMaxRuntime')
manifest = json.load(open('Sources/Audiogen/Resources/minimax.json'))
root.joinpath('runtime.json').write_text(json.dumps(dict(
    sourceRevision=manifest['sourceRevision'], ggmlRevision=manifest['ggmlRevision'],
    sha256=hashlib.sha256(root.joinpath('mm-server').read_bytes()).hexdigest()), indent=2)+'\n')
PY
# Reject accidental links to Homebrew or build-machine paths.
otool -L "$OUTPUT/mm-server" | tail -n +2 | awk '{print $1}' | while read -r library; do
    [[ "$library" == /System/* || "$library" == /usr/lib/* ]] || { print -u2 "Unbundled dependency: $library"; exit 1; }
done
