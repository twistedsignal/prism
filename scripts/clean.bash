#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

rm -f "$PROJECT_ROOT/build/Prism.rbxm" "$PROJECT_ROOT/src/Version.luau" "$PROJECT_ROOT/sourcemap.json"
