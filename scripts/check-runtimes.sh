#!/bin/zsh
# Opt-in managed installations and real renders, using isolated test storage.
set -euo pipefail
cd "${0:A:h}/.."
export AUDIOGEN_RUNTIME_TEST_ROOT="$PWD/.build/python-smoke"
if [[ -n "${1:-}" ]]; then export AUDIOGEN_PYTHON_ENGINE="$1"; fi
swift test --filter PythonEngineTests/testLiveInstallAndGenerate
