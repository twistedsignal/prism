#!/usr/bin/env bash
# Prism installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/twistedsignal/prism/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/twistedsignal/prism/main/install.sh | bash -s -- --uninstall
#
# Environment overrides:
#   PRISM_VERSION   install this version instead of the latest release (e.g. 1.0.0)
#   PRISM_SOURCE    install from a local checkout (uses backend/ and build/Prism.rbxm) instead of downloading
#   PRISM_BLENDER   path to the Blender executable
#   PRISM_PLUGINS_DIR  Studio Plugins folder to install into

set -euo pipefail

main() {
	local repo="twistedsignal/prism"
	local credentials_url="https://create.roblox.com/dashboard/credentials?activeTab=ApiKeysTab"
	local raven_version="0.3.0"
	local raven_tarball="https://github.com/twistedsignal/raven/archive/refs/tags/v$raven_version.tar.gz"
	local port=47821

	if [[ -t 1 ]]; then
		bold=$'\e[1m' cyan=$'\e[36m' green=$'\e[32m' red=$'\e[31m' yellow=$'\e[33m' dim=$'\e[2m' reset=$'\e[0m'
	else
		bold="" cyan="" green="" red="" yellow="" dim="" reset=""
	fi

	step() { printf '\n%s%s%s\n' "$cyan" "$*" "$reset"; }
	ok() { printf '%s%s%s\n' "$green" "$*" "$reset"; }
	warn() { printf '%s%s%s\n' "$yellow" "$*" "$reset"; }
	fail() {
		printf '\n%s%s%s\n' "$red" "$*" "$reset" >&2
		exit 1
	}

	# Prompts read from the terminal because stdin is this script when piped from curl.
	tty_available() { [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }
	ask() {
		local prompt="$1" reply=""
		if ! tty_available; then
			fail "This installer needs an interactive terminal."
		fi
		printf '%s' "$prompt" >/dev/tty
		IFS= read -r reply </dev/tty || fail "Cancelled."
		printf '%s' "$reply"
	}
	ask_secret() {
		local prompt="$1" reply=""
		printf '%s' "$prompt" >/dev/tty
		IFS= read -rs reply </dev/tty || fail "Cancelled."
		printf '\n' >/dev/tty
		printf '%s' "$reply"
	}

	local uninstall=false
	for argument in "$@"; do
		case "$argument" in
			--uninstall) uninstall=true ;;
			-h | --help)
				echo "Usage: install.sh [--uninstall]"
				return 0
				;;
			*) fail "Unknown option: $argument" ;;
		esac
	done

	local os
	case "$(uname -s)" in
		Linux) os=linux ;;
		Darwin) os=macos ;;
		*) fail "Unsupported system $(uname -s). On Windows, use install.ps1." ;;
	esac

	local install_dir cache_dir config_dir
	if [[ "$os" == macos ]]; then
		install_dir="$HOME/Library/Application Support/Prism"
		cache_dir="$HOME/Library/Caches/Prism"
		config_dir="${PRISM_CONFIG_DIR:-$HOME/Library/Application Support/Prism}"
	else
		install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/prism"
		cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/prism"
		config_dir="${PRISM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/prism}"
	fi

	# ------------------------------------------------------------
	# Studio plugin folders
	# ------------------------------------------------------------

	plugin_dirs() {
		if [[ -n "${PRISM_PLUGINS_DIR:-}" ]]; then
			printf '%s\n' "$PRISM_PLUGINS_DIR"
			return
		fi
		if [[ "$os" == macos ]]; then
			printf '%s\n' "$HOME/Documents/Roblox/Plugins"
			return
		fi
		local roblox
		for roblox in \
			"$HOME"/.var/app/org.vinegarhq.Vinegar/data/vinegar/prefixes/*/drive_c/users/*/AppData/Local/Roblox \
			"${XDG_DATA_HOME:-$HOME/.local/share}"/vinegar/prefixes/*/drive_c/users/*/AppData/Local/Roblox; do
			[[ -d "$roblox" ]] && printf '%s\n' "$roblox/Plugins"
		done
	}

	# ------------------------------------------------------------
	# Uninstall
	# ------------------------------------------------------------

	if [[ "$uninstall" == true ]]; then
		printf '%sPrism Uninstall...%s\n' "$bold" "$reset"
		# Remove the startup entry directly so this works without Blender or a network.
		step "Removing startup script..."
		if [[ "$os" == macos ]]; then
			local label
			for label in dev.ivadsiuls.prism com.ivadsiuls.prism; do
				launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$label.plist" >/dev/null 2>&1 || true
				rm -f "$HOME/Library/LaunchAgents/$label.plist"
			done
		elif command -v systemctl >/dev/null 2>&1; then
			systemctl --user disable --now prism.service >/dev/null 2>&1 || true
			rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/prism.service"
			systemctl --user daemon-reload >/dev/null 2>&1 || true
		fi
		local cli_path="$HOME/.local/bin/prism"
		if [[ -f "$cli_path" ]] && grep -q 'Prism managed CLI launcher' "$cli_path"; then
			rm -f "$cli_path"
		fi
		step "Removing backend..."
		rm -rf "$install_dir/backend" "$install_dir/.backend-previous" "$cache_dir"
		step "Removing local Roblox plugin..."
		local dir
		while IFS= read -r dir; do
			[[ -n "$dir" ]] && rm -f "$dir/Prism.rbxm"
		done < <(plugin_dirs)
		echo
		ok "Prism has been uninstalled. Raven, your settings and presets were left in place."
		return 0
	fi

	# ------------------------------------------------------------
	# Version
	# ------------------------------------------------------------

	local version="${PRISM_VERSION:-}"
	if [[ -z "$version" && -n "${PRISM_SOURCE:-}" ]]; then
		version="$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$PRISM_SOURCE/wally.toml" | head -n 1)"
	fi
	if [[ -z "$version" ]]; then
		version="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null |
			sed -nE 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/p' | head -n 1)" || true
		[[ -n "$version" ]] || fail "Could not find the latest Prism release. Check your internet connection."
	fi
	version="${version#v}"

	printf '%sPrism v%s Installation...%s\n' "$bold" "$version" "$reset"

	# ------------------------------------------------------------
	# Blender
	# ------------------------------------------------------------

	local -a blender=()
	find_blender() {
		local candidate
		if [[ -n "${PRISM_BLENDER:-}" ]]; then
			blender=("$PRISM_BLENDER")
			return 0
		fi
		if candidate="$(command -v blender 2>/dev/null)"; then
			blender=("$candidate")
			return 0
		fi
		for candidate in "/Applications/Blender.app/Contents/MacOS/Blender" "$HOME/Applications/Blender.app/Contents/MacOS/Blender"; do
			if [[ -x "$candidate" ]]; then
				blender=("$candidate")
				return 0
			fi
		done
		if command -v flatpak >/dev/null 2>&1 && flatpak info org.blender.Blender >/dev/null 2>&1; then
			blender=(flatpak run --filesystem=home org.blender.Blender)
			return 0
		fi
		return 1
	}

	if ! find_blender; then
		printf '\n%sYou do not have Blender installed! Please install it.%s\n' "$red" "$reset"
		echo "Download it from https://www.blender.org/download/ and run this installer again."
		exit 1
	fi

	local blender_version major minor
	blender_version="$("${blender[@]}" --version 2>/dev/null | sed -nE 's/^Blender ([0-9]+)\.([0-9]+).*/\1.\2/p' | head -n 1)"
	major="${blender_version%%.*}"
	minor="${blender_version#*.}"
	if [[ -z "$blender_version" ]]; then
		fail "Could not run Blender (${blender[*]}). Set PRISM_BLENDER to its path and try again."
	fi
	if ((major < 4 || (major == 4 && minor < 2))); then
		fail "Prism needs Blender 4.2 or newer; found $blender_version. Please update Blender."
	fi
	echo
	ok "Blender is installed, continuing..."

	# Runs Python with stdin, using python3 if available and Blender's bundled Python otherwise.
	have_python() {
		command -v python3 >/dev/null 2>&1 || return 1
		# macOS ships a python3 stub that pops up an installer without the command line tools.
		[[ "$os" != macos ]] || xcode-select -p >/dev/null 2>&1
	}
	run_python() {
		local code="$1"
		if have_python; then
			python3 -c "$code"
		else
			"${blender[@]}" --background --factory-startup --python-expr "$code" 2>/dev/null |
				sed -n 's/^PRISM://p'
		fi
	}

	# ------------------------------------------------------------
	# Raven
	# ------------------------------------------------------------

	local node_major
	if ! command -v node >/dev/null 2>&1; then
		fail "Raven needs Node.js 20 or newer. Install it from https://nodejs.org and run this installer again."
	fi
	node_major="$(node --version | sed -nE 's/^v([0-9]+).*/\1/p')"
	if [[ -z "$node_major" ]] || ((node_major < 20)); then
		fail "Raven needs Node.js 20 or newer; found $(node --version). Update it from https://nodejs.org."
	fi

	local raven=""
	raven="$(command -v raven 2>/dev/null || true)"
	if [[ -z "$raven" && -x "$HOME/.local/bin/raven" ]]; then
		raven="$HOME/.local/bin/raven"
	fi
	if [[ -z "$raven" ]] || ! "$raven" asset download --help 2>/dev/null | grep -- "--output" >/dev/null; then
		echo
		printf '%sInstalling Raven v%s asset download support...%s\n' "$yellow" "$raven_version" "$reset"
		if ! npm install -g "$raven_tarball" >/dev/null 2>&1; then
			# System Node installs often need root for -g; fall back to a user prefix.
			npm install -g --prefix "$HOME/.local" "$raven_tarball" >/dev/null ||
				fail "Could not install Raven with npm."
		fi
		raven="$(command -v raven 2>/dev/null || true)"
		if [[ -x "$HOME/.local/bin/raven" ]] && "$HOME/.local/bin/raven" asset download --help 2>/dev/null | grep -- "--output" >/dev/null; then
			raven="$HOME/.local/bin/raven"
		fi
		[[ -n "$raven" ]] || fail "Raven was installed but couldn't be found. Make sure npm's global bin folder is on your PATH."
		"$raven" asset download --help 2>/dev/null | grep -- "--output" >/dev/null || fail "Raven asset download support is still unavailable. Check your npm installation."
		echo
		ok "Raven has been installed."
	fi

	# ------------------------------------------------------------
	# API key
	# ------------------------------------------------------------

	local raven_dir="${RAVEN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/raven}"
	local credentials="$raven_dir/credentials.json"

	# Parses an introspection response on stdin into "ok<TAB>name<TAB>ownerId" or "error<TAB>reason".
	local parse_code='
import json, sys
def out(*parts):
    print(("PRISM:" if "bpy" in sys.modules else "") + "\t".join(parts))
try:
    info = json.loads(sys.stdin.read())
except ValueError:
    info = None
if not isinstance(info, dict):
    out("error", "Roblox sent a response Prism could not read. Try again.")
elif info.get("enabled") is False:
    out("error", "That key is disabled. Enable it on the Creator Dashboard.")
elif info.get("expired"):
    out("error", "That key has expired. Create a new one.")
else:
    granted = set()
    for scope in info.get("scopes") or []:
        if isinstance(scope, str):
            api, _, operation = scope.partition(":")
            granted.add((api.lower(), operation.lower()))
        elif isinstance(scope, dict):
            for operation in scope.get("operations") or []:
                granted.add((str(scope.get("name", "")).lower(), str(operation).lower()))
    if not all(({("asset", operation), ("assets", operation)} & granted) for operation in ("read", "write")):
        out("error", "That key needs Assets Read and Write access. Edit the key and add them.")
    elif ("legacy-asset", "manage") not in granted:
        out("error", "That key needs Legacy Assets Manage access. Edit the existing key and add it.")
    else:
        out("ok", str(info.get("name") or ""), str(info.get("authorizedUserId") or ""))
'

	# Checks the key on stdin with Roblox. The key only travels through pipes, never argv.
	validate_key() {
		local key response status
		key="$(cat)"
		if [[ -z "$key" ]]; then
			printf 'error\tThe key is empty.\n'
			return
		fi
		if [[ ! "$key" =~ ^[A-Za-z0-9+/=._-]+$ ]]; then
			printf 'error\tThat key is invalid. Make sure you copied the whole key.\n'
			return
		fi
		response="$(printf '{"apiKey":"%s"}' "$key" | curl -sS -X POST -w '\n%{http_code}' \
			-H "Content-Type: application/json" --data @- \
			"https://apis.roblox.com/api-keys/v1/introspect" 2>/dev/null)" || {
			printf 'error\tCould not reach Roblox. Check your internet connection.\n'
			return
		}
		status="${response##*$'\n'}"
		case "$status" in
			200) printf '%s' "${response%$'\n'*}" | run_python "$parse_code" ;;
			400 | 401 | 403) printf 'error\tThat key is invalid. Make sure you copied the whole key.\n' ;;
			*) printf 'error\tRoblox returned HTTP %s. Try again in a moment.\n' "$status" ;;
		esac
	}

	local save_code='
import json, os, sys
from datetime import datetime, timezone
path, name, owner = sys.argv[1:4] if len(sys.argv) >= 4 else (os.environ["PRISM_CREDENTIALS"], os.environ["PRISM_KEY_NAME"], os.environ["PRISM_OWNER"])
key = sys.stdin.read().strip()
try:
    with open(path, encoding="utf-8") as handle:
        existing = json.load(handle)
except Exception:
    existing = {}
features = existing.get("features") if isinstance(existing.get("features"), list) else []
for feature in ("asset", "asset-download"):
    if feature not in features:
        features.append(feature)
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
data = {"apiKey": key, "name": name or None, "ownerId": owner or None, "features": features,
        "savedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")}
# Older Raven logins without a feature list enable all commands.
if existing.get("apiKey") and not isinstance(existing.get("features"), list):
    data.pop("features", None)
data = {k: v for k, v in data.items() if v is not None}
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
os.chmod(path, 0o600)
'

	local read_key_code='
import json, sys
try:
    key = json.load(open(sys.stdin.read().strip(), encoding="utf-8")).get("apiKey", "")
except Exception:
    key = ""
print(("PRISM:" if "bpy" in sys.modules else "") + key)
'

	local api_key="" key_name="" owner_id="" result=""
	if [[ -f "$credentials" ]]; then
		local existing_key
		existing_key="$(printf '%s' "$credentials" | run_python "$read_key_code")"
		if [[ -n "$existing_key" ]]; then
			result="$(printf '%s' "$existing_key" | validate_key)"
			if [[ "${result%%$'\t'*}" == ok ]]; then
				IFS=$'\t' read -r _ key_name owner_id <<<"$result"
				echo
				local answer
				answer="$(ask "Use existing Raven key${key_name:+ ($key_name)}? [Y/n] ")"
				if [[ ! "$answer" =~ ^[Nn] ]]; then
					api_key="$existing_key"
				fi
			else
				printf "%s\n" "${result#*$'\t'}"
			fi
		fi
	fi

	if [[ -z "$api_key" ]]; then
		echo
		ask "Press enter to open $credentials_url " >/dev/null
		if [[ "$os" == macos ]]; then
			open "$credentials_url" >/dev/null 2>&1 || true
		else
			xdg-open "$credentials_url" >/dev/null 2>&1 || true
		fi
		echo
		echo "Create an API key with the following permissions:"
		echo
		printf '  %sMake sure the dashboard is on your personal account, not a group.%s\n' "$bold" "$reset"
		echo "  1. Click Create API Key and give it a name, like Prism."
		echo "  2. Under Access Permissions, add the API System ${bold}Assets${reset}."
		echo "  3. Give it ${bold}Read${reset} and ${bold}Write${reset}."
		echo "  4. Add Legacy Assets with Manage access."
		echo "  5. Save the key, then copy it. Existing users can edit their current key."
		printf '  %sA personal key can upload to any group you have access to.%s\n' "$dim" "$reset"
		echo
		ask "Press enter when done." >/dev/null
		while true; do
			echo
			api_key="$(ask_secret "Enter your API key: ")"
			echo
			echo "Validating..."
			result="$(printf '%s' "$api_key" | validate_key)"
			if [[ "${result%%$'\t'*}" == ok ]]; then
				IFS=$'\t' read -r _ key_name owner_id <<<"$result"
				break
			fi
			printf '%s%s%s\n' "$red" "${result#*$'\t'}" "$reset"
		done
	fi
	if have_python; then
		printf '%s' "$api_key" | python3 -c "$save_code" "$credentials" "$key_name" "$owner_id"
	else
		printf '%s' "$api_key" | PRISM_CREDENTIALS="$credentials" PRISM_KEY_NAME="$key_name" PRISM_OWNER="$owner_id" \
			"${blender[@]}" --background --factory-startup --python-expr "$save_code" >/dev/null 2>&1
	fi
	api_key=""
	echo
	ok "Valid API key to upload images!"

	# ------------------------------------------------------------
	# Backend
	# ------------------------------------------------------------

	step "Installing backend..."
	mkdir -p "$install_dir"
	local staging
	staging="$(mktemp -d)"
	# shellcheck disable=SC2064 # expand now: staging is local to main.
	trap "rm -rf '$staging'" EXIT
	if [[ -n "${PRISM_SOURCE:-}" ]]; then
		cp -R "$PRISM_SOURCE/backend" "$staging/backend"
		cp "$PRISM_SOURCE/build/Prism.rbxm" "$staging/Prism.rbxm" ||
			fail "Build the plugin first: scripts/build.bash"
	else
		local base="https://github.com/$repo/releases/download/v$version"
		curl -fsSL "$base/prism-backend.tar.gz" -o "$staging/backend.tar.gz" ||
			fail "Could not download the Prism backend."
		tar -xzf "$staging/backend.tar.gz" -C "$staging"
		curl -fsSL "$base/Prism.rbxm" -o "$staging/Prism.rbxm" ||
			fail "Could not download the Prism plugin."
	fi
	find "$staging/backend" -name __pycache__ -prune -exec rm -rf {} +
	printf '%s\n' "$version" >"$staging/backend/VERSION"
	rm -rf "$install_dir/backend"
	mv "$staging/backend" "$install_dir/backend"

	# ------------------------------------------------------------
	# Startup
	# ------------------------------------------------------------

	step "Installing startup script..."
	local -a install_args=(install --raven "$raven")
	if [[ -n "$owner_id" ]]; then
		install_args+=(--creator "user:$owner_id")
	fi
	if [[ "${blender[0]}" != flatpak ]]; then
		install_args+=(--blender "${blender[0]}")
	fi
	local startup_log="$staging/startup.log"
	if ! "${blender[@]}" --background --factory-startup --python "$install_dir/backend/main.py" -- "${install_args[@]}" >"$startup_log" 2>&1; then
		# Show why it failed (no systemd user session, launchctl errors, ...).
		grep -Ev '^(Blender |Read prefs|$)' "$startup_log" | tail -n 15 >&2 || true
		if [[ "$os" == linux ]] && ! systemctl --user show-environment >/dev/null 2>&1; then
			fail "Prism starts at login through a systemd user service, but no systemd user session is available."
		fi
		fail "Could not install the startup script. Run the installer again or check your Blender install."
	fi

	# A previous install may have changed the port in Settings.
	local configured_port
	configured_port="$(printf '%s' "$config_dir/config.json" | run_python '
import json, sys
try:
    port = json.load(open(sys.stdin.read().strip(), encoding="utf-8")).get("port")
except Exception:
    port = None
print(("PRISM:" if "bpy" in sys.modules else "") + (str(port) if isinstance(port, int) else ""))
')"
	if [[ "$configured_port" =~ ^[0-9]+$ ]] && ((configured_port >= 1024 && configured_port <= 65535)); then
		port="$configured_port"
	fi

	local started=false
	for _ in $(seq 1 30); do
		if curl -fsS -H "X-Prism: 1" "http://127.0.0.1:$port/status" >/dev/null 2>&1; then
			started=true
			break
		fi
		sleep 0.5
	done
	if [[ "$started" == false ]]; then
		if [[ "$os" == macos ]]; then
			warn "The backend didn't respond yet. Check ~/Library/Logs/Prism.log."
		else
			warn "The backend didn't respond yet. Check: journalctl --user -u prism"
		fi
	fi

	# ------------------------------------------------------------
	# Plugin
	# ------------------------------------------------------------

	step "Installing local Roblox plugin..."
	local -a targets=()
	local dir
	while IFS= read -r dir; do
		[[ -n "$dir" ]] && targets+=("$dir")
	done < <(plugin_dirs)
	if [[ ${#targets[@]} -eq 0 ]]; then
		warn "Couldn't find Roblox Studio (Vinegar)."
		dir="$(ask "Enter your Studio Plugins folder, or press enter to skip: ")"
		[[ -n "$dir" ]] && targets+=("$dir")
	fi
	for dir in "${targets[@]}"; do
		mkdir -p "$dir"
		cp "$staging/Prism.rbxm" "$dir/Prism.rbxm"
		printf '%s  %s%s\n' "$dim" "$dir/Prism.rbxm" "$reset"
	done
	if [[ ${#targets[@]} -eq 0 ]]; then
		warn "Skipped. Download Prism.rbxm from the release page and put it in your Plugins folder."
	fi

	echo
	printf '%s%sPrism v%s has been installed!%s\n' "$green" "$bold" "$version" "$reset"
	echo "Restart Roblox Studio and open Prism from the Plugins tab."
}

main "$@"
