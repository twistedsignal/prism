# shellcheck shell=bash
# shared helpers for the build scripts; source this file, don't run it.

# shellcheck disable=SC2034 # used by the scripts that source this file.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_tool() {
	local name="$1"
	if command -v "$name" >/dev/null 2>&1; then
		command -v "$name"
	elif [[ -x "$HOME/.rokit/bin/$name" ]]; then
		echo "$HOME/.rokit/bin/$name"
	else
		echo "$name was not found in PATH or the Rokit bin directory." >&2
		exit 1
	fi
}

find_plugins_dir() {
	if [[ -n "${PRISM_PLUGINS_DIR:-}" ]]; then
		echo "$PRISM_PLUGINS_DIR"
		return
	fi
	local user="${USER:-$(id -un)}"
	local candidates=(
		"$HOME/.var/app/org.vinegarhq.Vinegar/data/vinegar/prefixes/studio/drive_c/users/$user/AppData/Local/Roblox/Plugins"
		"${XDG_DATA_HOME:-$HOME/.local/share}/vinegar/prefixes/studio/drive_c/users/$user/AppData/Local/Roblox/Plugins"
		"$HOME/Documents/Roblox/Plugins"
	)
	if [[ -n "${LOCALAPPDATA:-}" ]]; then
		candidates+=("$LOCALAPPDATA/Roblox/Plugins")
	fi
	for candidate in "${candidates[@]}"; do
		if [[ -d "$candidate" ]]; then
			echo "$candidate"
			return
		fi
	done
	echo "Could not find a Studio Plugins folder. Set PRISM_PLUGINS_DIR." >&2
	exit 1
}
