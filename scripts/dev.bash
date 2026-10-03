#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

rojo="$(find_tool rojo)"
plugins_dir="$(find_plugins_dir)"

"$PROJECT_ROOT/scripts/clean.bash"
"$PROJECT_ROOT/scripts/write-version.bash"

echo "Building into $plugins_dir/Prism-dev.rbxm (watching for changes)"
cd "$PROJECT_ROOT"
"$rojo" build -o "$plugins_dir/Prism-dev.rbxm" --watch default.project.json
