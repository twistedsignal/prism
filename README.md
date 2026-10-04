<div align="center">
  <img src="assets/icon.png" width="96" />
  <h1>Prism</h1>
  <p>Render Roblox Studio models into icons with Blender, right from a Studio plugin.</p>
</div>

#### Please ⭐ the repo if you like it!!

Select models in Studio, adjust the camera and effects, then save PNGs or upload them to Roblox. Blender handles the final preview and render.

## Install

You need [Blender](https://www.blender.org/download/) 4.2 or newer and [Node.js](https://nodejs.org) 20 or newer. The installer adds the Studio plugin, backend and [Raven](https://github.com/twistedsignal/raven), then helps you set up a Roblox API key for assets and uploads.

On macOS or Linux, including Vinegar:

```sh
curl -fsSL https://raw.githubusercontent.com/twistedsignal/prism/main/install.sh | bash
```

On Windows, run this in PowerShell:

```powershell
irm https://raw.githubusercontent.com/twistedsignal/prism/main/install.ps1 | iex
```

## Use Prism

1. Select models, tools, accessories or parts in Studio. Click a card in Prism to work on one of them.
2. Adjust the camera and settings. Drag the preview to orbit, scroll to zoom, or drag over text in the Blender preview to move it. Studio text follows your mouse, then the Blender render replaces it. Choose **This model** or **All** to set the editing scope.
3. Click **Render** to save PNGs to your output folder. Click **Upload** to send them to Roblox as Decals. Prism shows the image IDs you can use in `ImageLabel.Image`.

To pick models by path instead, open the **Select** tab and type a glob such as `ReplicatedStorage/Content/**/Model`. Use `/` between names, `*` and `?` inside a name, `**` for any depth, `[abc]` for character sets and `{Sword,Shield}` for alternatives. Matching ignores case, and `\` escapes a literal `/` or `*` in a name. Suggestions follow your typing like a code editor: press Tab or → to accept, or ↑ ↓ to choose another. Filter matches to Models, Parts, Folders or anything Prism can render, then click **Select** to replace the Studio selection or **Add** to extend it. Nested matches collapse into their outermost match, and a trailing `**` matches what is inside a folder, not the folder itself.

The plugin has outlines, shadows, glow, color and depth effects, and text. Presets are saved locally. Prism also remembers a model's settings when you deselect and reselect it.

Slow renders show the current render step, completed/total steps, and elapsed time in the preview after three seconds. Agent jobs expose the same progress, and waiting CLI commands print updates to stderr every three seconds. These are completed render steps, not estimated Blender samples.

## Agent automation

Prism installs a `prism` CLI for agents with terminal access. The Studio plugin runs its agent service in edit mode even when the panel is closed. Commands do not change your selection, panel settings, presets or saved preferences.

```sh
prism status --json
prism sessions --json
prism models --query Crate --json
prism presets --json
prism schema --json
prism render --path Workspace.Items.Crate --preset Inventory --size 1024 --emoji-provider apple --output ./icons/crate.png --json
prism upload --path Workspace.Items.Crate --creator user:123 --output ./icons/crate-upload.png --json
```

Use `--session ID` when several Studio windows are connected, and `--target ID` with an ID returned by `models`. For names containing dots, pass exact segments with `--path-json '["Workspace","Name.with.dots"]'`. Duplicate names in a path are rejected; discovered target IDs resolve the ambiguity. IDs last for that Studio service session.

Settings start with Prism defaults, then the requested preset, then `--settings '{"cameraRotation":45,"text":"Hello 😀"}'` or `--settings-file settings.json`. `--size`, `--aa`, `--emoji-provider`, `--creator` and `--output` apply only to the job. Omitted quality, emoji provider, creator and output directory use your preferences. Files are never overwritten; omitted output filenames are generated uniquely.

For batches, run `prism batch batch.json --json` with a manifest such as:

```json
{
  "defaults": {"preset": "Inventory", "size": 1024, "emojiProvider": "google"},
  "items": [
    {"path": ["Workspace", "Crate"], "output": "./icons/crate.png"},
    {"path": ["Workspace", "Sword"], "output": "./icons/sword.png", "upload": true, "creator": "user:123"}
  ]
}
```

Relative output paths resolve from the CLI's working directory. Per-item options override manifest defaults. Each target is cloned when its serialization starts; subsequent edits affect later jobs. Successful items are kept when others fail. Upload results include the saved PNG path, Decal asset ID and image ID when Roblox exposes it. Raven uses your existing credentials.

All results are JSON, and progress goes to stderr. Exit codes are 0 for success, 1 for failure or partial failure, and 2 for a wait timeout. The default wait is 300 seconds, configurable with `--timeout`. A timeout leaves the job running. Inspect it with `prism job JOB_ID --wait --json`; do not automatically repeat an upload. Job history is held in memory, bounded to 256 jobs and one hour for completed jobs. A backend restart clears it.

Agents can read `prism agent instructions` and `prism agent describe`. To install the bundled skill explicitly, run `prism agent install-skill --directory ~/.codex/skills` or point it at your agent's skills directory. Existing different skills are not replaced automatically.

On Linux/macOS the launcher is `~/.local/bin/prism`; on Windows it is `%LOCALAPPDATA%\Prism\bin\prism.cmd`. If `prism` is absent from PATH, invoke that path directly or add its directory to PATH and reopen your terminal. `prism status` reports the launcher path and readiness. `--port` overrides the configured port for one command.

Upgrades preserve settings and presets. The new backend installs or refreshes the launcher at startup, including when it was downloaded by an older updater. Restart Studio after upgrading to load the agent service, and allow Prism's localhost HTTP access when requested. Re-running the installer also installs the CLI. Agent requests use the versioned `/agent/v1` API; the existing panel API remains available. Uninstalling removes only Prism-owned CLI launchers.

## Updates and removal

Prism prompts you when a new release is available. After an update, restart Roblox Studio to load the new plugin. You can also use **Settings → Check for updates** or run the installer again.

To uninstall on macOS or Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/twistedsignal/prism/main/install.sh | bash -s -- --uninstall
```

To uninstall on Windows:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/twistedsignal/prism/main/install.ps1))) -Uninstall
```

Uninstalling removes the plugin, backend and cache. It keeps your settings, presets and Raven installation.

## Common problems

- If Prism says **HTTP access blocked**, allow it to reach `127.0.0.1` under **Plugins → Manage Plugins**.
- If an asset cannot be downloaded, Prism shows a warning and uses a box or plain color. Check the API key permissions, then select the model again.
- Studio plugins cannot read union geometry, so Prism draws unions as boxes.

## How it works

```
Studio plugin ──HTTP 127.0.0.1:47821──▶ backend (runs inside Blender)
  reads content or sends asset IDs        downloads assets, builds OBJ, renders
  live preview (EditableImage)  ◀───────  RGBA pixels
                                          saves PNGs, uploads through raven
```

The HTTP backend runs in plain Python, using Blender's bundled interpreter when installed. It starts Blender only when scene preparation or rendering needs it, keeps the worker warm while you work, and shuts it down after 60 seconds without a scene or render job. The next job starts a fresh worker automatically. Settings, uploads and update checks keep working while Blender is stopped.

It only listens on `127.0.0.1` and rejects browser requests. It starts at login through a systemd user service on Linux, a LaunchAgent on macOS, or a Task Scheduler task on Windows.

| File | Location |
|---|---|
| Settings and presets | `~/.config/prism` · `~/Library/Application Support/Prism` · `%APPDATA%\Prism` |
| Backend | `~/.local/share/prism` · `~/Library/Application Support/Prism` · `%LOCALAPPDATA%\Prism` |
| Cache | `~/.cache/prism` · `~/Library/Caches/Prism` · `%LOCALAPPDATA%\Prism\cache` |
| Logs | `journalctl --user -u prism` · `~/Library/Logs/Prism.log` · `%LOCALAPPDATA%\Prism\prism.log` |

### Rendering details

Your Raven API key needs **Assets > Read and Write** and **Legacy Assets > Manage** (`legacy-asset:manage`); the installer checks both. If the key is missing permissions, rendering uses placeholders with a warning. After fixing permissions, select the model again to retry recovery.

Completed renders use a 16 MiB memory cache in the Blender worker, shared by previews, exports and uploads. Changing a model, camera, render settings, output size or antialiasing selects a different cache entry. Blender keeps the two most recently rendered models loaded; older models are imported again from prepared scenes on disk when needed. Worker shutdown releases these caches and imported models.

Auto-3D is enabled by default in the plugin's Settings tab. It hides the 3D/Blender picker, shows the Studio viewport immediately when you edit the camera or model settings, and switches to the matching Blender preview when rendering finishes. Turn it off to choose either view manually. The preference is saved per Studio user.

Image effects reuse the rendered image, so every effect edit skips Blender entirely while its base render is cached. Cel shading, X-ray and the depth effects add one extra pass each (unlit color, surface normals or camera depth); text renders in its own small scene. These passes are cached until their memory budget fills. Silhouettes and blurred masks are reused when only colors, opacity or shadow offsets change. Cavity angle changes reuse the color, base and normals passes; turning cavity off reuses the base pass. Intermediate PNGs use no compression. These additional worker caches are bounded to 48 MiB and released when the worker shuts down.

R15 classic clothing uses Roblox's compositing UV maps and preserves the body meshes' original UV islands, including wrists, knees and ankles. Primitive fallback parts sample the sleeve or pant seam at internal joints instead of repeating the shoulder or hip cap.

Selected models refresh automatically when you edit their geometry, colors, materials, textures or clothing, or add and remove descendants. Rapid edits are combined before Prism sends a new scene. Your render settings stay in place.

Text supports full-color emoji, including skin tones, flags and joined sequences. Choose Apple, Google, Facebook or Twitter in **Settings > Emoji provider**. Emoji images download on first use and stay cached for offline rendering. If a provider lacks an emoji, Prism uses an available provider, preferring Google. Roblox's Verified `\u{E000}`, Premium `\u{E001}`, Robux `\u{E002}` and Roblox Plus `\u{E003}` glyphs also work with any text font. Paste the characters or type these Unicode escapes into Text. Robux, Premium and Plus use the text color; emoji and Verified keep their original colors.

Use the search bar below the render presets to filter settings by name, description, key or section. Matching sections and groups expand while you search. Clear the search to restore their previous collapse state. Conditional settings appear when their controls are enabled.

The Lighting section's **Sync Lighting** button copies the place's global lighting into the
current edit scope. It estimates sun or moon direction and strength, ambient light, color shifts,
exposure, specular highlights and cast shadows for each model's pivot, stance and camera.
This is a one-time sync; click again after changing the place lighting or the render view.
Sky reflections, atmosphere, local lights and Roblox post-processing are not reproduced.

Unions render from their serialized geometry, including stored colors when `UsePartColor` is off.
Prism regenerates a temporary unparented Union to recover cloud-backed geometry, then destroys it.
The CSG decoder supports legacy CSGMDLV5 and SolidMesh. Unsupported geometry falls back to a box
with a warning. Roblox can change these undocumented formats between Studio releases.

The backend supports FileMesh v1, v2, v3, v4, and v7. Compressed v7 meshes use Blender's bundled Draco decoder; official Blender builds include it. No extra Python package or export dialog is required. Downloads respect the key's access to each asset.

## Development

Tools are managed with [Rokit](https://github.com/rojo-rbx/rokit):

```sh
rokit install
wally install
scripts/build.bash   # build/Prism.rbxm
scripts/dev.bash     # build into your Studio Plugins folder and rebuild on change
scripts/test.bash    # selene, every Luau and Python test, installer checks
PRISM_TEST_BLENDER=/path/to/blender python3 -m unittest discover -s tests -p 'test_worker.py'
```

The Python tests need `numpy`. CI runs `scripts/test.bash` on every push and pull request, and releases only publish when it passes.

`dev.bash` finds the Plugins folder of a Vinegar flatpak or native prefix, macOS or Windows. Set `PRISM_PLUGINS_DIR` to override it.

Run the backend from the checkout:

```sh
python3 backend/main.py serve --blender /path/to/blender --port 47821
```

Render an OBJ directly, without the server:

```sh
blender --background --factory-startup --python backend/renderer.py -- model.obj out.png --settings settings.json --size 512
```

Render settings are defined once in `backend/schema.py`. The plugin builds its sliders, toggles and color pickers from that schema.

To test the installer against a local checkout, build the plugin first, then run:

```sh
PRISM_SOURCE="$PWD" bash install.sh
```

Releases are published by `.github/workflows/release.yml` when the version in `wally.toml` changes. The release commit's message becomes the release notes shown in the plugin's update prompt.

## License

Prism is released under the [MIT License](LICENSE). The meshes in `backend/clothing/` and `backend/primitives/` come from Roblox Studio and belong to Roblox Corporation.
