#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

version="$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$PROJECT_ROOT/wally.toml" | head -n 1)"
if [[ -z "$version" ]]; then
	echo 'wally.toml must contain a semver package version like version = "1.0.0".' >&2
	exit 1
fi

printf 'return "%s"\n' "$version" > "$PROJECT_ROOT/src/Version.luau"
echo "Generated src/Version.luau for Prism v$version"
