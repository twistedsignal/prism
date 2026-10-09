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

# Fingerprint everything Rojo builds into the plugin except these generated files.
# A release whose fingerprint matches the running plugin only changes the backend,
# so the updater can skip the Studio restart.
sha256=(sha256sum)
command -v sha256sum >/dev/null 2>&1 || sha256=(shasum -a 256)
plugin_hash="$(
	cd "$PROJECT_ROOT"
	# Hash each file with its path, so renames count too.
	paths=()
	for path in src Packages default.project.json; do
		[[ -e "$path" ]] && paths+=("$path")
	done
	find "${paths[@]}" -type f ! -path src/Version.luau ! -path src/PluginHash.luau -print0 |
		LC_ALL=C sort -z | xargs -0 "${sha256[@]}" -- | "${sha256[@]}" | cut -c1-64
)"
printf 'return "%s"\n' "$plugin_hash" > "$PROJECT_ROOT/src/PluginHash.luau"
printf '%s\n' "$plugin_hash" > "$PROJECT_ROOT/backend/PLUGIN_HASH"
echo "Generated plugin fingerprint ${plugin_hash:0:12}"
